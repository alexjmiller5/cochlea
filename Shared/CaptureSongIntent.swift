import AppIntents
import Foundation

#if WIDGET_EXTENSION
typealias CaptureSongIntentKind = LiveActivityIntent
#elseif os(iOS)
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
        return .result(value: try await captureValue())
    }

    @MainActor
    private func captureValue() async throws -> String {
        #if WIDGET_EXTENSION
        throw CaptureLaunchError.requiresAppProcess
        #else
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
            return "Capture canceled"
        }
        // Keep the run alive until the Dynamic Island has shown the result.
        await controller.recordingActivity?.waitUntilDismissed()
        if let title = record.title, let artist = record.artist { return "\(title) by \(artist)" }
        return "Capture saved"
        #endif
    }
}

#if os(iOS)
@available(iOS 18, *)
extension CaptureSongIntent: AudioRecordingIntent {}
#endif

#if WIDGET_EXTENSION
private enum CaptureLaunchError: LocalizedError {
    case requiresAppProcess
    var errorDescription: String? { "Open Cochlea and try again." }
}
#endif
