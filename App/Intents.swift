import AppIntents
import UniformTypeIdentifiers

#if os(iOS)
typealias CaptureSongIntentKind = LiveActivityIntent & ForegroundContinuableIntent
#else
typealias CaptureSongIntentKind = AppIntent
#endif

struct CaptureSongIntent: CaptureSongIntentKind {
    static var title: LocalizedStringResource = "Capture song"
    static var description = IntentDescription("Identify music as you listen, or save an offline capture for automatic identification on your next online use.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var requiresLiveActivity = false
        #if os(iOS)
        if #available(iOS 18, *) { requiresLiveActivity = true }
        else { try await requestToContinueInForeground() }
        #endif
        let controller = try Runtime.controller.get()
        let record: CaptureRecord
        do {
            record = try await controller.capture(requiresLiveActivity: requiresLiveActivity)
        } catch is CancellationError {
            return .result(value: "Capture canceled")
        }
        // Keep the run alive until the Dynamic Island has shown the result.
        await controller.recordingActivity?.waitUntilDismissed()
        if let title = record.title, let artist = record.artist { return .result(value: "\(title) by \(artist)") }
        return .result(value: "Capture saved")
    }
}

#if os(iOS)
@available(iOS 18, *)
extension CaptureSongIntent: AudioRecordingIntent {}
#endif

struct ImportAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "Save audio capture"
    static var description = IntentDescription("Save a recorded audio clip and automatically identify pending captures when online. Accepts clips up to 30 seconds.")
    static var openAppWhenRun = false

    @Parameter(title: "Audio")
    var audio: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Save \(\.$audio) as a song capture") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let controller = try Runtime.controller.get()
        if let url = audio.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try await controller.importAudio(url)
        } else {
            let data = audio.data
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw CaptureError.invalidAudio }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            _ = try await controller.importAudio(url)
        }
        return .result(value: "Capture saved")
    }
}

struct CaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureSongIntent(),
                    phrases: ["Capture a song with \(.applicationName)", "Identify music with \(.applicationName)"],
                    shortTitle: "Capture song", systemImageName: "waveform")
    }
}
