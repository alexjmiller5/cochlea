import AppIntents
import UniformTypeIdentifiers

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
