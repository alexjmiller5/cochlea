#if os(iOS)
import ActivityKit
#endif
import Foundation

enum RecordingActivityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Allow Live Activities in this app's system settings to record from Shortcuts, or start a capture in the app."
    }
}

@MainActor
final class RecordingActivity {
    struct Handle {
        let update: @MainActor (RecordingAttributes.Outcome) async -> Void
        let end: @MainActor () async -> Void
    }
    typealias Request = @MainActor (RecordingAttributes, RecordingAttributes.ContentState) async throws -> Handle

    private let request: Request
    private let resultDuration: Duration
    private var handle: Handle?
    private var dismissal: Task<Void, Never>?

    init(resultDuration: Duration = .seconds(5), request: Request? = nil) {
        self.resultDuration = resultDuration
        self.request = request ?? Self.requestActivity
    }

    func start(id: UUID) async throws {
        let now = Date()
        handle = try await request(RecordingAttributes(recordingID: id),
            .init(startedAt: now, deadline: now.addingTimeInterval(15)))
    }

    /// Ends immediately: cancellation, failures, or a recording that was never saved.
    func end() async {
        let handle = handle
        self.handle = nil
        await handle?.end()
    }

    /// Replaces the recording state with the capture's result and dismisses it after
    /// the hold, so the Dynamic Island confirms what happened instead of vanishing.
    func finish(showing outcome: RecordingAttributes.Outcome) async {
        guard let handle else { return }
        self.handle = nil
        await handle.update(outcome)
        let hold = resultDuration
        dismissal = Task { @MainActor in
            try? await Task.sleep(for: hold)
            await handle.end()
        }
    }

    /// A Shortcut run awaits this so the process stays alive until the result is dismissed.
    func waitUntilDismissed() async {
        await dismissal?.value
    }

    private static func requestActivity(attributes: RecordingAttributes,
                                        state: RecordingAttributes.ContentState) async throws -> Handle {
        #if !os(iOS)
        throw RecordingActivityError.unavailable
        #else
        // A force quit can leave an indicator behind. A fresh user invocation
        // starts a new capture and retires indicators from the previous process.
        for activity in Activity<RecordingAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw RecordingActivityError.unavailable }
        let activity: Activity<RecordingAttributes>
        do {
            activity = try Activity.request(attributes: attributes,
                content: ActivityContent(state: state, staleDate: state.deadline), pushType: nil)
        } catch {
            throw RecordingActivityError.unavailable
        }
        return Handle(update: { outcome in
            var result = state
            result.outcome = outcome
            // A short stale date keeps a suspended process from leaving the result up for hours.
            await activity.update(ActivityContent(state: result, staleDate: Date().addingTimeInterval(30)))
        }, end: { await activity.end(nil, dismissalPolicy: .immediate) })
        #endif
    }
}
