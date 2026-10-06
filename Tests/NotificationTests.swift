#if os(iOS)
import SwiftData
import UserNotifications
import XCTest
@testable import Cochlea

@MainActor
final class NotificationTests: XCTestCase {
    private let center = UNUserNotificationCenter.current()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let presentation = NotificationPresentation()
    private var identifiers: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        center.delegate = presentation
        let allowed = try await center.requestAuthorization(options: [.provisional, .alert, .sound])
        XCTAssertTrue(allowed, "Native notification tests require provisional simulator authorization")
        // Some iOS 27 simulators refuse every scheduled notification ("Source is not
        // authorized", UNErrorDomain 2003) even when authorized; these native tests cannot run there.
        do {
            try await center.add(UNNotificationRequest(identifier: "authorization-probe", content: UNMutableNotificationContent(),
                                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
            center.removePendingNotificationRequests(withIdentifiers: ["authorization-probe"])
        } catch let error as NSError where error.domain == UNErrorDomain {
            throw XCTSkip("This simulator refuses to schedule notifications (UNErrorDomain \(error.code)); use one that accepts them")
        }
    }

    override func tearDown() async throws {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.delegate = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testRecognitionSchedulesPromptNativeNotificationWithoutClaimingSpotifySuccess() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        var scheduled: UNNotificationRequest?
        await CaptureNotifications(schedule: { request in
            scheduled = request
            try await self.center.add(request)
        }).reconcile(store: store)
        let request = try XCTUnwrap(scheduled)
        _ = try await delivered(record)
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
        XCTAssertFalse(request.trigger?.repeats ?? true)
        XCTAssertTrue(request.content.body.contains("Example Song"))
        XCTAssertTrue(request.content.body.contains("Example Artist"))
        XCTAssertFalse(request.content.title.contains("Spotify"))
        XCTAssertNotNil(request.content.sound)
    }

    func testQuickDeliveryLeavesOneRecognitionNotification() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        let notifications = CaptureNotifications()
        await notifications.reconcile(store: store)
        try deliver(record, store: store)
        await notifications.reconcile(store: store)
        let request = try await delivered(record)
        let pendingRequestAfterDelivery = await pending(record)
        XCTAssertNil(pendingRequestAfterDelivery, "Recognition delivers without a separate success request")
        XCTAssertEqual(request.content.title, "Song recognized")
        XCTAssertTrue(request.content.body.contains("Example Song"))
        XCTAssertNotNil(request.content.sound, "Recognition is the only success alert")
        let cards = await center.deliveredNotifications().filter { $0.request.identifier == request.identifier }
        XCTAssertEqual(cards.count, 1)
    }

    func testDelayedDeliveryDoesNotAlertAgainOrReplaceTheRecognitionCard() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        var schedules = 0
        let notifications = CaptureNotifications(schedule: { request in
            schedules += 1
            try await self.center.add(request)
        })
        await notifications.reconcile(store: store)
        let recognition = try await delivered(record)
        XCTAssertEqual(recognition.content.title, "Song recognized")
        try deliver(record, store: store)
        await notifications.reconcile(store: store)
        let final = try await delivered(record)
        XCTAssertEqual(final.identifier, recognition.identifier)
        XCTAssertEqual(final.content.title, "Song recognized")
        XCTAssertEqual(schedules, 1, "A delayed Spotify success must remain silent")
    }

    func testRelaunchAndDeliveryRetriesDoNotRescheduleOrRepeatDismissedNotifications() async throws {
        var id: UUID!
        do {
            let store = try CaptureStore(directory: directory)
            let record = try matched(in: store)
            id = record.id
            var schedules = 0
            let notifications = CaptureNotifications(schedule: { request in
                schedules += 1
                try await self.center.add(request)
            })
            await notifications.reconcile(store: store)
            _ = try await delivered(record)
            for _ in 0..<2 {
                try store.deliveryFinished(record, status: 503, data: Data())
                await notifications.reconcile(store: store)
            }
            XCTAssertEqual(schedules, 1, "Retries must not replace recognition or alert again")
        }
        do {
            let store = try CaptureStore(directory: directory)
            let record = try XCTUnwrap(store.records().first(where: { $0.id == id }))
            try deliver(record, store: store)
            await CaptureNotifications().reconcile(store: store)
            _ = try await delivered(record, containing: "Song recognized")
            center.removeDeliveredNotifications(withIdentifiers: [identifier(record)])
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first(where: { $0.id == id }))
        var schedules = 0
        let notifications = CaptureNotifications(schedule: { request in
            schedules += 1
            try await self.center.add(request)
        })
        await notifications.reconcile(store: reopened)
        XCTAssertEqual(schedules, 0, "A persisted completed alert must not return after dismissal or restart")
        let pendingRequest = await pending(record)
        XCTAssertNil(pendingRequest)
    }

    func testUnvalidatedReceiptsNeverScheduleSpotifySuccess() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        var requests: [UNNotificationRequest] = []
        let notifications = CaptureNotifications(schedule: { request in
            requests.append(request)
            try await self.center.add(request)
        })
        for body in ["{\"ok\":true}", "{\"ok\":true,\"capture_id\":\"\(UUID())\",\"isrc\":\"XX0000000001\"}", "not json"] {
            try store.deliveryFinished(record, status: 200, data: Data(body.utf8))
            await notifications.reconcile(store: store)
            XCTAssertEqual(record.state, .matched)
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.title, "Song recognized")
        _ = try await delivered(record)
    }

    func testDeniedAuthorizationLeavesTheCaptureQueueUsable() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        let denied = CaptureNotifications(authorization: { .denied }, schedule: { _ in
            XCTFail("Denied permission must not attempt notification delivery")
        })
        await denied.reconcile(store: store)
        try deliver(record, store: store)
        await denied.reconcile(store: store)
        XCTAssertEqual(record.state, .delivered)
        XCTAssertNil(record.lastError)
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().first?.state, .delivered)
    }

    func testSchedulingFailureCanRetryAfterRelaunchWithoutLosingTheSong() async throws {
        do {
            let store = try CaptureStore(directory: directory)
            let record = try matched(in: store)
            let failing = CaptureNotifications(schedule: { _ in throw CocoaError(.fileWriteUnknown) })
            await failing.reconcile(store: store)
            let pendingRequest = await pending(record)
            XCTAssertNil(pendingRequest)
            XCTAssertEqual(record.state, .matched)
            XCTAssertNil(record.lastError)
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first)
        await CaptureNotifications().reconcile(store: reopened)
        _ = try await delivered(record)
    }

    func testExistingDeliveredHistoryDoesNotGenerateUpgradeAlerts() async throws {
        let store = try CaptureStore(directory: directory)
        let record = CaptureRecord()
        record.state = .delivered
        record.title = "Example Song"
        record.artist = "Example Artist"
        store.context.insert(record)
        try store.save()
        var schedules = 0
        await CaptureNotifications(schedule: { _ in schedules += 1 }).reconcile(store: store)
        XCTAssertEqual(schedules, 0, "Previously completed history must remain quiet after upgrade")
    }

    func testReceiptArrivingDuringNativeSchedulingDoesNotScheduleAnotherAlert() async throws {
        let store = try CaptureStore(directory: directory)
        let record = try matched(in: store)
        let started = expectation(description: "Recognition has reached the native scheduler")
        var release: CheckedContinuation<Void, Never>?
        var schedules = 0
        let notifications = CaptureNotifications(schedule: { request in
            schedules += 1
            if schedules == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
            try await self.center.add(request)
        })
        let recognition = Task { await notifications.reconcile(store: store) }
        await fulfillment(of: [started], timeout: 10)
        try deliver(record, store: store)
        let delivery = Task { await notifications.reconcile(store: store) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(schedules, 1, "An awaited native add must finish before a newer request starts")
        release?.resume()
        await recognition.value
        await delivery.value
        let request = try await delivered(record, containing: "Song recognized")
        XCTAssertEqual(request.content.title, "Song recognized")
        XCTAssertEqual(schedules, 1)
        let pendingRequest = await pending(record)
        XCTAssertNil(pendingRequest)
    }

    private func matched(in store: CaptureStore) throws -> CaptureRecord {
        let record = CaptureRecord()
        identifiers.append(identifier(record))
        store.context.insert(record)
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        return record
    }

    private func deliver(_ record: CaptureRecord, store: CaptureStore) throws {
        try store.deliveryFinished(record, status: 200,
            data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8))
    }

    private func identifier(_ record: CaptureRecord) -> String { "capture." + record.id.uuidString }

    private func pending(_ record: CaptureRecord) async -> UNNotificationRequest? {
        await center.pendingNotificationRequests().first { $0.identifier == identifier(record) }
    }

    private func delivered(_ record: CaptureRecord, containing: String? = nil, timeout: TimeInterval = 4) async throws -> UNNotificationRequest {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let delivered = await center.deliveredNotifications()
            if let request = delivered.first(where: { notification in
                notification.request.identifier == identifier(record)
                    && (containing.map { notification.request.content.title.contains($0) } ?? true)
            })?.request { return request }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        throw XCTUnwrapFailure.missingNotification
    }
}

private enum XCTUnwrapFailure: Error { case missingNotification }

private final class NotificationPresentation: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }
}
#endif
