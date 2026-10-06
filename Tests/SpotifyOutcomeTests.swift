import UserNotifications
import XCTest
@testable import Cochlea

@MainActor
final class SpotifyOutcomeTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testDefinitiveFailureAlertsOnceWithoutReplacingRecognitionAcrossRelaunch() async throws {
        var requests: [UNNotificationRequest] = []
        let notifications = notifier { requests.append($0) }
        do {
            let (store, record) = try fixture()
            await notifications.reconcile(store: store)
            try finish(store, record, outcome: "not_added")
            await notifications.reconcile(store: store)
            await notifications.reconcile(store: store)
            XCTAssertEqual(record.state, .matched)
            XCTAssertNotNil(record.nextAttemptAt)
        }
        await notifications.reconcile(store: try CaptureStore(directory: directory))
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized", "Couldn't add to Spotify"])
        XCTAssertEqual(Set(requests.map(\.identifier)).count, 2, "The failure must not replace recognition")
        XCTAssertTrue(requests.last?.content.body.contains("Example Song by Example Artist") == true)
        XCTAssertTrue(requests.last?.content.body.contains("Cochlea") == true, "Explain where to check the saved capture")
    }

    func testOnlyMatchingAuthenticatedDefinitiveReceiptCanAlert() async throws {
        let (store, record) = try fixture()
        var requests: [UNNotificationRequest] = []
        let notifications = notifier { requests.append($0) }
        await notifications.reconcile(store: store)
        let bodies = [
            "{}", "invalid", "{\"ok\":false}",
            "{\"ok\":false,\"spotify_outcome\":\"not_added\"}",
            "{\"ok\":false,\"capture_id\":\"invalid\",\"spotify_outcome\":\"not_added\"}",
            "{\"ok\":false,\"capture_id\":\"\(UUID())\",\"spotify_outcome\":\"not_added\"}",
            "{\"ok\":false,\"capture_id\":\"\(record.id)\",\"spotify_outcome\":17}",
            "{\"ok\":true,\"capture_id\":\"\(record.id)\",\"spotify_outcome\":\"not_added\"}"
        ]
        for status in [200, 401, 409, 503] {
            for body in bodies {
                try store.deliveryFinished(record, status: status, data: Data(body.utf8))
                await notifications.reconcile(store: store)
            }
        }
        for status in [0, 302, 401, 403] {
            try finish(store, record, outcome: "not_added", status: status)
            await notifications.reconcile(store: store)
        }
        for outcome in ["unknown", "future_value", "added"] {
            try finish(store, record, outcome: outcome)
            await notifications.reconcile(store: store)
        }
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized"])
        XCTAssertEqual(record.state, .matched)
    }

    func testMalformedAdditiveOutcomeDoesNotBreakExistingSuccessAcknowledgement() async throws {
        let store = try CaptureStore(directory: directory)
        for value: Any in [17, ["unexpected": "object"], ["not_added"], NSNull()] {
            let record = CaptureRecord()
            store.context.insert(record)
            try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "capture_id": record.id.uuidString,
                "isrc": "XX0000000001", "spotify_outcome": value])
            try store.deliveryFinished(record, status: 200, data: data)
            XCTAssertEqual(record.state, .delivered, "The additive field must preserve the established success contract")
        }
    }

    func testAddedReceiptStaysSilentDuringMaintenanceRetriesAndAcrossRelaunch() async throws {
        var requests: [UNNotificationRequest] = []
        let notifications = notifier { requests.append($0) }
        do {
            let (store, record) = try fixture()
            try finish(store, record, outcome: "added")
            XCTAssertEqual(record.state, .matched, "An unfinished maintenance receipt must still retry")
            XCTAssertNotNil(record.nextAttemptAt)
            await notifications.reconcile(store: store)
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first)
        // Even a contradictory later failure cannot erase confirmed Spotify success.
        try finish(reopened, record, outcome: "not_added")
        await notifications.reconcile(store: reopened)
        try finish(reopened, record, outcome: "added", status: 200, ok: true)
        await notifications.reconcile(store: reopened)
        XCTAssertEqual(record.state, .delivered)
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized"])
    }

    func testExplicitUnknownIsNeverDowngradedToNotAddedAfterRelaunch() async throws {
        do {
            let (store, record) = try fixture()
            try finish(store, record, outcome: "unknown")
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first)
        try finish(reopened, record, outcome: "not_added")
        var requests: [UNNotificationRequest] = []
        await notifier { requests.append($0) }.reconcile(store: reopened)
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized"])
    }

    func testGenericFailureDoesNotPreventLaterDefinitiveProof() async throws {
        let (store, record) = try fixture()
        try store.deliveryFinished(record, status: 503, data: Data())
        try finish(store, record, outcome: "not_added")
        var requests: [UNNotificationRequest] = []
        await notifier { requests.append($0) }.reconcile(store: store)
        XCTAssertEqual(requests.count, 2)
    }

    func testNewUncertainResponseInvalidatesUnannouncedFailure() async throws {
        let (store, record) = try fixture()
        try finish(store, record, outcome: "not_added")
        try store.deliveryFinished(record, status: 0, data: Data())
        var requests: [UNNotificationRequest] = []
        await notifier { requests.append($0) }.reconcile(store: store)
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized"])
    }

    func testNotificationSchedulingFailureRetriesWithoutReplayingRecognition() async throws {
        let (store, record) = try fixture()
        var requests: [UNNotificationRequest] = []
        await notifier { requests.append($0) }.reconcile(store: store)
        try finish(store, record, outcome: "not_added")
        await notifier { _ in throw CocoaError(.fileWriteUnknown) }.reconcile(store: store)
        await notifier { requests.append($0) }.reconcile(store: store)
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized", "Couldn't add to Spotify"])
    }

    func testAcceptedFailureRequestRecoversMissingPersistence() async throws {
        let (store, record) = try fixture()
        var requests: [UNNotificationRequest] = []
        await notifier { requests.append($0) }.reconcile(store: store)
        try finish(store, record, outcome: "not_added")
        await notifier { requests.append($0) }.reconcile(store: store)
        let failure = try XCTUnwrap(requests.last)
        XCTAssertEqual(failure.content.title, "Couldn't add to Spotify")
        // A second store models a crash after the OS accepted the alert but before its flag saved.
        let recovery = try CaptureStore(directory: directory.appendingPathComponent("recovery"))
        let recovered = CaptureRecord(id: record.id)
        recovery.context.insert(recovered)
        try recovery.matched(recovered, metadata: try XCTUnwrap(record.metadata))
        recovered.recognitionNotificationDate = Date()
        try finish(recovery, recovered, outcome: "not_added")
        await CaptureNotifications(authorization: { .authorized }, schedule: { _ in
            XCTFail("An OS-accepted failure must not repeat")
        }, existingRequests: { ([], [failure]) }).reconcile(store: recovery)
        await notifier { _ in XCTFail("Recovered history must survive notification dismissal") }.reconcile(store: recovery)
    }

    private func notifier(schedule: @escaping (UNNotificationRequest) async throws -> Void) -> CaptureNotifications {
        CaptureNotifications(authorization: { .authorized }, schedule: schedule, existingRequests: { ([], []) })
    }

    private func fixture() throws -> (CaptureStore, CaptureRecord) {
        let store = try CaptureStore(directory: directory)
        let record = CaptureRecord()
        store.context.insert(record)
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        return (store, record)
    }

    private func finish(_ store: CaptureStore, _ record: CaptureRecord, outcome: String, status: Int = 503, ok: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: ["ok": ok, "capture_id": record.id.uuidString.lowercased(),
            "spotify_outcome": outcome, "isrc": "XX0000000001"])
        try store.deliveryFinished(record, status: status, data: data)
    }
}
