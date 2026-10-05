#if os(iOS)
import ActivityKit
import ShazamKit
import XCTest
@testable import Cochlea

@MainActor
final class RecordingActivityTests: XCTestCase {
    func testLiveActivityShowsTheRecognizedSongThenDismissesAfterTheHold() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { nil }, sessionConfiguration: .ephemeral)
        var events: [String] = []
        let activity = RecordingActivity(resultDuration: .milliseconds(300)) { _, state in
            XCTAssertEqual(state.deadline.timeIntervalSince(state.startedAt), 15, accuracy: 0.01)
            XCTAssertNil(state.outcome, "Recording starts without a result")
            events.append("activity")
            return RecordingActivity.Handle(update: { events.append("show \($0)") }, end: { events.append("end") })
        }
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            XCTAssertEqual(events, ["activity"])
            events.append("record")
            return CapturedAudio(signature: SHSignatureGenerator().signature(),
                                 metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        }, recognize: { _ in nil }, recordingActivity: activity)
        _ = try await controller.capture(requiresLiveActivity: true)
        XCTAssertEqual(events, ["activity", "record",
                                "show \(RecordingAttributes.Outcome.recognized(title: "Example Song", artist: "Example Artist"))"],
                       "The result replaces the recording state and stays visible for the hold")
        let shown = Date()
        await activity.waitUntilDismissed()
        XCTAssertEqual(events.last, "end")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shown), 0.25, "The result must stay up for the hold")
        XCTAssertEqual(try store.records().first?.state, .matched)
        service.session.finishTasksAndInvalidate()
    }

    func testLiveActivityShowsNoMatchOnlineAndSavedOffline() async throws {
        for (online, expected) in [(true, RecordingAttributes.Outcome.noMatch), (false, .savedForLater)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try CaptureStore(directory: directory)
            let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
                connection: { nil }, sessionConfiguration: .ephemeral)
            var shown: [RecordingAttributes.Outcome] = []
            let activity = RecordingActivity(resultDuration: .milliseconds(10)) { _, _ in
                RecordingActivity.Handle(update: { shown.append($0) }, end: {})
            }
            let controller = CaptureController(store: store, delivery: service, recordAudio: {
                CapturedAudio(signature: SHSignatureGenerator().signature())
            }, recognize: { _ in nil }, recordingActivity: activity)
            controller.isOnline = online
            _ = try await controller.capture(requiresLiveActivity: true)
            await activity.waitUntilDismissed()
            XCTAssertEqual(shown, [expected])
            service.session.finishTasksAndInvalidate()
        }
    }

    func testRequiredLiveActivityFailurePreventsRecordingButForegroundCaptureStillWorks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { nil }, sessionConfiguration: .ephemeral)
        var recordings = 0
        let activity = RecordingActivity { _, _ in throw RecordingActivityError.unavailable }
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            recordings += 1
            return CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in nil }, recordingActivity: activity)
        controller.isOnline = false
        do { _ = try await controller.capture(requiresLiveActivity: true); XCTFail("Background recording requires its indicator") }
        catch { XCTAssertTrue(error is RecordingActivityError) }
        XCTAssertEqual(recordings, 0)
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(try store.records().isEmpty)
        _ = try await controller.capture()
        XCTAssertEqual(recordings, 1)
        XCTAssertEqual(try store.records().count, 1)
        service.session.finishTasksAndInvalidate()
    }

    func testStaleActivityCancelCannotStopCurrentRecordingAndCancelEndsActivity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { nil }, sessionConfiguration: .ephemeral)
        let started = expectation(description: "recording started")
        var activeID: UUID?
        var ended = false
        var shown = false
        let activity = RecordingActivity { attributes, _ in
            activeID = attributes.recordingID
            return RecordingActivity.Handle(update: { _ in shown = true }, end: { ended = true })
        }
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            started.fulfill()
            try await Task.sleep(for: .seconds(5))
            return CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in nil }, recordingActivity: activity)
        let capture = Task { @MainActor in _ = try await controller.capture(requiresLiveActivity: true) }
        await fulfillment(of: [started], timeout: 10)
        controller.cancelCapture(id: UUID())
        XCTAssertTrue(controller.isRecording)
        XCTAssertFalse(ended)
        controller.cancelCapture(id: try XCTUnwrap(activeID))
        do { try await capture.value; XCTFail("The current activity must cancel recording") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(ended)
        XCTAssertFalse(shown, "A canceled capture ends without a result")
        XCTAssertTrue(try store.records().isEmpty)
        service.session.finishTasksAndInvalidate()
    }

    func testShortcutSupportsRecordingWithoutForegroundOnCurrentOS() throws {
        guard #available(iOS 18, *) else { throw XCTSkip("iOS 17 uses the foreground fallback") }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "extract", withExtension: "actionsdata", subdirectory: "Metadata.appintents"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let actions = try XCTUnwrap(metadata["actions"] as? [String: [String: Any]])
        let capture = try XCTUnwrap(actions["CaptureSongIntent"])
        XCTAssertEqual(capture["openAppWhenRun"] as? Bool, false)
        let protocols = try XCTUnwrap(capture["systemProtocols"] as? [String])
        XCTAssertTrue(protocols.contains("com.apple.link.systemProtocol.AudioRecording"))
        XCTAssertTrue(protocols.contains("com.apple.link.systemProtocol.SessionStarting"))
    }

    func testNewCaptureRetiresStaleNativeActivityAndEndDismissesCurrentOne() async throws {
        let previousID = UUID()
        let previous = RecordingActivity()
        try await previous.start(id: previousID)
        let old = Activity<RecordingAttributes>.activities.first { $0.attributes.recordingID == previousID }
        XCTAssertNotNil(old)
        let id = UUID()
        let activity = RecordingActivity()
        try await activity.start(id: id)
        XCTAssertFalse(old?.activityState == .active)
        let native = Activity<RecordingAttributes>.activities.first { $0.attributes.recordingID == id }
        XCTAssertNotNil(native)
        await activity.end()
        XCTAssertFalse(native?.activityState == .active)
        await previous.end()
    }
}
#endif
