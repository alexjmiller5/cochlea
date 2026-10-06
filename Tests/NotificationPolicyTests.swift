import SwiftData
import UserNotifications
import XCTest
@testable import Cochlea

@MainActor
final class NotificationPolicyTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testQuickDeliveryStillAnnouncesRecognitionOnly() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        try deliver(record, store: store)
        var requests: [UNNotificationRequest] = []
        let notifications = CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) })
        await notifications.reconcile(store: store)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.content.title, "Song recognized")
        XCTAssertEqual(request.content.body, "Example Song by Example Artist")
        XCTAssertLessThanOrEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval ?? 0, 1)
        XCTAssertNotNil(request.content.sound)
    }

    func testDeliveryAfterRecognitionDoesNotSendAnotherNotificationEvenAfterRelaunch() async throws {
        var requests: [UNNotificationRequest] = []
        let notifications = CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) })
        do {
            let store = try CaptureStore(directory: directory)
            let record = try matched(in: store)
            await notifications.reconcile(store: store)
            try deliver(record, store: store)
            await notifications.reconcile(store: store)
            XCTAssertEqual(requests.count, 1, "Spotify success must not schedule a second alert")
        }
        let reopened = try CaptureStore(directory: directory)
        await notifications.reconcile(store: reopened)
        XCTAssertEqual(requests.count, 1, "Dismissed recognition must not reappear on relaunch")
    }

    func testAmbiguousTransportOrServerFailuresDoNotClaimSongWasNotAdded() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        var requests: [UNNotificationRequest] = []
        let notifications = CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) })
        await notifications.reconcile(store: store)
        for status in [0, 401, 403, 422, 429, 503] {
            try store.deliveryFinished(record, status: status, data: Data("{\"ok\":false,\"message\":\"capture unavailable\"}".utf8))
            await notifications.reconcile(store: store)
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.title, "Song recognized")
        XCTAssertEqual(record.state, .matched)
    }

    func testPreviouslyNotifiedOrHistoricalSongsStaySilentAfterUpgrade() async throws {
        let store = try CaptureStore(directory: directory)
        let notified = try matched(in: store)
        notified.deliveryNotificationScheduled = true
        try deliver(notified, store: store)
        let history = CaptureRecord()
        history.state = .delivered
        history.title = "Historical Song"
        history.artist = "Historical Artist"
        store.context.insert(history)
        try store.save()
        await CaptureNotifications(authorization: { .authorized }, schedule: { _ in
            XCTFail("An upgrade must not replay historical recognition")
        }).reconcile(store: store)
    }

    func testUpgradeReplacesAPendingFirstSuccessWithRecognitionButDoesNotRepeatEarlierRecognition() async throws {
        for (index, earlierRecognition) in [nil, Date().addingTimeInterval(60), Date().addingTimeInterval(-60)].enumerated() {
            let store = try CaptureStore(directory: directory.appendingPathComponent(String(index)))
            let record = try matched(in: store)
            try deliver(record, store: store)
            record.deliveryNotificationScheduled = true
            record.recognitionNotificationDate = earlierRecognition
            try store.save()
            let content = UNMutableNotificationContent()
            content.title = "Added to Spotify"
            content.userInfo = ["stage": "delivered"]
            let legacy = UNNotificationRequest(identifier: "capture." + record.id.uuidString, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
            var requests: [UNNotificationRequest] = []
            await CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) },
                existingRequests: { ([legacy], []) }).reconcile(store: store)
            XCTAssertEqual(requests.count, index == 2 ? 0 : 1)
            if index != 2 {
                XCTAssertEqual(requests.first?.content.title, "Song recognized")
            }
        }
    }

    func testFailedUpgradeSchedulingCanRetryWithoutTheCanceledLegacyRequest() async throws {
        var id: UUID!
        do {
            let store = try CaptureStore(directory: directory)
            let record = try matched(in: store)
            id = record.id
            try deliver(record, store: store)
            record.deliveryNotificationScheduled = true
            try store.save()
            let content = UNMutableNotificationContent()
            content.userInfo = ["stage": "delivered"]
            let legacy = UNNotificationRequest(identifier: "capture." + record.id.uuidString, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
            await CaptureNotifications(authorization: { .authorized }, schedule: { _ in
                throw CocoaError(.fileWriteUnknown)
            }, existingRequests: { ([legacy], []) }).reconcile(store: store)
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first(where: { $0.id == id }))
        var requests: [UNNotificationRequest] = []
        await CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) },
            existingRequests: { ([], []) }).reconcile(store: reopened)
        XCTAssertEqual(record.state, .delivered)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.title, "Song recognized")
    }

    private func matched(in store: CaptureStore) throws -> CaptureRecord {
        let record = CaptureRecord()
        store.context.insert(record)
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        return record
    }

    private func deliver(_ record: CaptureRecord, store: CaptureStore) throws {
        try store.deliveryFinished(record, status: 200,
            data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8))
    }
}
