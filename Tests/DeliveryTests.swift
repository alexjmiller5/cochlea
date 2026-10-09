import Foundation
import ShazamKit
import UserNotifications
import XCTest
@testable import Cochlea

@MainActor
final class DeliveryTests: XCTestCase {
    override func tearDown() {
        CaptureHTTPStub.reply = nil
        CaptureHTTPStub.response = nil
        CaptureHTTPStub.begin = nil
        super.tearDown()
    }

    func testResumeChecksBlockedCredentialsAndSendsAllWaitingSongs() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        try fixture.store.deliveryFinished(fixture.record, status: 401, data: Data())
        let newer = try fixture.store.capture(signature: SHSignatureGenerator().signature())
        try fixture.store.matched(newer, metadata: MatchMetadata(title: "New Song", artist: "Example Artist"))
        let controller = CaptureController(store: fixture.store, delivery: fixture.service,
            recordAudio: { throw CaptureError.microphoneDenied }, recognize: { _ in nil })
        let accepted = Data("{\"ok\":false,\"message\":\"capture requires capture_id, title, artist, apple_music_id and shazam_url; isrc is optional\"}".utf8)
        var checks = 0
        var uploads = 0
        CaptureHTTPStub.response = { request in
            if request.httpBody == Data("{}".utf8) {
                checks += 1
                return (422, [:], accepted)
            }
            uploads += 1
            // Concurrent URLSession uploads can arrive in either order.
            let payload = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            guard let id = payload?["capture_id"] as? String else {
                XCTFail("Upload must contain its capture ID")
                return (400, [:], Data())
            }
            XCTAssertTrue([fixture.record.id, newer.id].contains(UUID(uuidString: id)))
            return (200, [:], Data("{\"ok\":true,\"capture_id\":\"\(id)\",\"isrc\":\"XX0000000001\"}".utf8))
        }
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.state == .delivered && newer.state == .delivered
        }, object: nil)
        await controller.resume()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(uploads, 2)
        XCTAssertNil(controller.connectionIssue)
    }

    func testConnectionProbeRequiresAuthenticatedMusicSyncValidationAndNeverACapture() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPStub.self]
        let connection = try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token")
        var requests = 0
        CaptureHTTPStub.response = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (422, [:], Data("{\"ok\":false,\"message\":\"an unrelated validation error\"}".utf8))
        }
        do {
            try await ConnectionVerifier().verify(connection, sessionConfiguration: configuration)
            XCTFail("An arbitrary 422 must not claim credentials were accepted")
        } catch ConnectionCheckError.wrongEndpoint {}
        CaptureHTTPStub.response = { _ in (401, [:], Data()) }
        do {
            try await ConnectionVerifier().verify(connection, sessionConfiguration: configuration)
            XCTFail("Rejected credentials must remain rejected")
        } catch ConnectionCheckError.rejected {}
        XCTAssertEqual(requests, 1)
    }

    func testRejectedCredentialsAreRecheckedWithoutResubmittingSongs() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        try fixture.store.deliveryFinished(fixture.record, status: 401, data: Data())
        let controller = CaptureController(store: fixture.store, delivery: fixture.service,
            recordAudio: { throw CaptureError.microphoneDenied }, recognize: { _ in nil })
        var checks = 0
        CaptureHTTPStub.response = { request in
            checks += 1
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
            return (401, [:], Data())
        }
        await controller.resume()
        await controller.resume()
        XCTAssertEqual(checks, 1, "Repeated callbacks must not hammer a rejected credential")
        XCTAssertTrue(fixture.record.deliveryBlocked)
        XCTAssertTrue(controller.connectionIssue?.contains("token") == true)
        XCTAssertTrue(controller.uploadingIDs.isEmpty)
    }

    func testMissingConnectionIsVisibleAndCaptureStaysDurable() async throws {
        let fixture = try DeliveryFixture(connection: { nil })
        defer { fixture.cleanUp() }
        let controller = CaptureController(store: fixture.store, delivery: fixture.service,
            recordAudio: { throw CaptureError.microphoneDenied }, recognize: { _ in nil })
        await controller.resume()
        XCTAssertNotNil(controller.connectionIssue)
        XCTAssertTrue(controller.connectionIssue?.contains("Settings") == true)
        XCTAssertTrue(controller.uploadingIDs.isEmpty)
        let reopened = try CaptureStore(directory: fixture.directory)
        XCTAssertEqual(try reopened.records().first?.state, .matched)
        XCTAssertEqual(try reopened.records().first?.metadata, fixture.record.metadata)
        XCTAssertFalse(try reopened.signature(for: XCTUnwrap(reopened.records().first)).isEmpty)
    }

    func testActiveUploadIsVisibleAndConcurrentEnqueuesDoNotDuplicateIt() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let controller = CaptureController(store: fixture.store, delivery: fixture.service,
            recordAudio: { throw CaptureError.microphoneDenied }, recognize: { _ in nil })
        let started = expectation(description: "upload held before a receipt arrives")
        var pending: CaptureHTTPStub?
        var requests = 0
        CaptureHTTPStub.begin = { request in
            requests += 1
            if requests == 1 { pending = request; started.fulfill() }
        }
        await controller.resume()
        await fulfillment(of: [started], timeout: 10)
        XCTAssertEqual(controller.uploadingIDs, [fixture.record.id])
        XCTAssertEqual(fixture.record.state, .matched, "Starting a transfer must not claim Spotify confirmed it")
        async let first: Void = fixture.service.enqueue()
        async let second: Void = fixture.service.enqueue()
        _ = try await (first, second)
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.uploadingIDs.isEmpty && controller.records.first?.state == .delivered
        }, object: nil)
        try XCTUnwrap(pending).complete(data: fixture.receipt)
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.uploadingIDs.isEmpty)
        XCTAssertEqual(controller.records.first?.state, .delivered)
    }

    func testUploadOmittedBySessionStaysInFlightUntilItsReceiptIsProcessed() async throws {
        // URLSession can stop enumerating a completed transfer before its
        // delegate callback commits the receipt on the main actor.
        let fixture = try DeliveryFixture(existingTasks: { [] })
        defer { fixture.cleanUp() }
        let started = expectation(description: "first upload")
        var pending: CaptureHTTPStub?
        var requests = 0
        CaptureHTTPStub.begin = { request in
            requests += 1
            if requests == 1 { pending = request; started.fulfill() }
        }
        try await fixture.service.enqueue()
        await fulfillment(of: [started], timeout: 10)
        try await fixture.service.enqueue()
        XCTAssertEqual(fixture.service.uploadingIDs, [fixture.record.id])
        try XCTUnwrap(pending).complete(data: fixture.receipt)
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.state == .delivered
        }, object: nil)
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(requests, 1, "Waiting for a receipt must not resubmit the same capture")
        XCTAssertTrue(fixture.service.uploadingIDs.isEmpty)
    }

    func testRestoredUploadWithOldCredentialsDoesNotBlockCurrentConnection() async throws {
        var restored: URLSessionTask?
        let fixture = try DeliveryFixture(existingTasks: { restored.map { [$0] } ?? [] })
        defer { fixture.cleanUp() }
        var request = URLRequest(url: URL(string: "https://example.com/capture")!)
        request.setValue("Bearer obsolete-token", forHTTPHeaderField: "Authorization")
        restored = fixture.service.session.dataTask(with: request)
        restored?.taskDescription = fixture.record.id.uuidString
        defer { restored?.cancel() }
        let uploaded = expectation(description: "current credentials upload")
        CaptureHTTPStub.response = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            uploaded.fulfill()
            return (200, [:], fixture.receipt)
        }
        try await fixture.service.enqueue()
        await fulfillment(of: [uploaded], timeout: 2)
    }

    func testStaleRestoredUploadIsReplacedInsteadOfSendingForever() async throws {
        // A background upload the service never answers stays "running" for the
        // session's resource timeout (7 days by default) while iOS resends it.
        var restored: URLSessionTask?
        let fixture = try DeliveryFixture(existingTasks: { restored.map { [$0] } ?? [] })
        defer { fixture.cleanUp() }
        var request = URLRequest(url: URL(string: "https://example.com/capture")!)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let restoredStarted = expectation(description: "restored transfer is waiting for an answer")
        CaptureHTTPStub.begin = { _ in restoredStarted.fulfill() } // and never gets one
        restored = fixture.service.session.dataTask(with: request)
        restored?.taskDescription = fixture.record.id.uuidString
        restored?.resume()
        await fulfillment(of: [restoredStarted], timeout: 5)
        fixture.record.deliveryStartedAt = Date(timeIntervalSinceNow: -DeliveryService.uploadTimeout - 120)
        let replaced = expectation(description: "a fresh upload replaces the stale one")
        var requests = 0
        CaptureHTTPStub.begin = nil
        CaptureHTTPStub.response = { _ in
            requests += 1
            replaced.fulfill()
            return (503, ["Retry-After": "72000"], Data("{\"ok\":false,\"capture_id\":\"\(fixture.record.id)\"}".utf8))
        }
        try await fixture.service.enqueue()
        await fulfillment(of: [replaced], timeout: 5)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.deliveryStatus == .spotifyBusy && fixture.service.uploadingIDs.isEmpty
        }, object: nil)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(restored?.state, .completed, "The stale transfer is cancelled")
        XCTAssertEqual(requests, 1)
    }

    func testUploadsGiveUpAfterFiveMinutesSoTheAppDecidesTheRetry() throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        XCTAssertEqual(DeliveryService.uploadTimeout, 300)
        XCTAssertEqual(fixture.service.session.configuration.timeoutIntervalForResource, 300)
    }

    func testOtherRetryDeadlinesContinueWhileAnEarlierUploadIsHeld() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let retrying = try fixture.store.capture(signature: SHSignatureGenerator().signature())
        let later = try fixture.store.capture(signature: SHSignatureGenerator().signature())
        for record in [retrying, later] {
            try fixture.store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        }
        retrying.nextAttemptAt = Date().addingTimeInterval(0.15)
        later.nextAttemptAt = Date().addingTimeInterval(0.3)
        try fixture.store.save()
        let retryReceipt = Data("{\"ok\":true,\"capture_id\":\"\(retrying.id)\",\"isrc\":\"XX0000000001\"}".utf8)
        let laterReceipt = Data("{\"ok\":true,\"capture_id\":\"\(later.id)\",\"isrc\":\"XX0000000001\"}".utf8)
        var held: CaptureHTTPStub?
        var requests = 0
        CaptureHTTPStub.begin = { request in
            requests += 1
            switch requests {
            case 1: held = request
            case 2: request.complete(status: 503, headers: ["Retry-After": "0.4"], data: Data())
            case 3: request.complete(data: laterReceipt)
            case 4: request.complete(data: retryReceipt)
            default: XCTFail("A held UUID must not duplicate while other captures retry")
            }
        }
        let otherSongsConfirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            retrying.state == .delivered && later.state == .delivered
        }, object: nil)
        try await fixture.service.enqueue()
        await fulfillment(of: [otherSongsConfirmed], timeout: 10)
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(fixture.record.state, .matched)
        XCTAssertTrue(fixture.service.uploadingIDs.contains(fixture.record.id))
        let allConfirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.state == .delivered
        }, object: nil)
        try XCTUnwrap(held).complete(data: fixture.receipt)
        await fulfillment(of: [allConfirmed], timeout: 10)
    }

    func testTemporaryConnectionReadFailureAfterHTTPFailureKeepsAutomaticRetry() async throws {
        var failNextRead = false
        let fixture = try DeliveryFixture(connection: {
            if failNextRead {
                failNextRead = false
                throw ConfigurationError.keychain(errSecInteractionNotAllowed)
            }
            return try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token")
        })
        defer { fixture.cleanUp() }
        let receipt = fixture.receipt
        var requests = 0
        CaptureHTTPStub.response = { _ in
            requests += 1
            if requests == 1 {
                failNextRead = true
                return (503, ["Retry-After": "0.15"], Data())
            }
            return (200, [:], receipt)
        }
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.state == .delivered
        }, object: nil)
        try await fixture.service.enqueue()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fixture.record.state, .delivered)
        XCTAssertNil(fixture.service.connectionIssue)
    }

    func testLateOldCredentialRejectionCannotBlockReplacementOmittedFromTaskSnapshot() async throws {
        var token = "old-token"
        let fixture = try DeliveryFixture(connection: {
            try DeliveryConfiguration(endpoint: "https://example.com/capture", token: token)
        })
        defer { fixture.cleanUp() }
        let previousSession = URLSession(configuration: fixture.service.sessionConfiguration)
        defer { previousSession.invalidateAndCancel() }
        let completed = expectation(description: "previous connection task has left active snapshots")
        CaptureHTTPStub.response = { _ in (401, [:], Data()) }
        var request = URLRequest(url: URL(string: "https://example.com/capture")!)
        request.setValue("Bearer old-token", forHTTPHeaderField: "Authorization")
        let previous = previousSession.dataTask(with: request) { _, _, _ in completed.fulfill() }
        previous.taskDescription = fixture.record.id.uuidString
        previous.resume()
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(previous.state, .completed)

        token = "new-token"
        let started = expectation(description: "replacement upload remains active")
        var replacement: CaptureHTTPStub?
        CaptureHTTPStub.begin = { request in replacement = request; started.fulfill() }
        try await fixture.service.connectionChanged()
        await fulfillment(of: [started], timeout: 10)
        // The OS may deliver a completed old task after getAllTasks has omitted it.
        fixture.service.urlSession(fixture.service.session, task: previous, didCompleteWithError: nil)
        XCTAssertFalse(fixture.record.deliveryBlocked)
        XCTAssertNil(fixture.record.lastError)
        XCTAssertTrue(fixture.service.uploadingIDs.contains(fixture.record.id))
        let confirmed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            fixture.record.state == .delivered
        }, object: nil)
        try XCTUnwrap(replacement).complete(data: fixture.receipt)
        await fulfillment(of: [confirmed], timeout: 10)
    }

    func testConnectionChangeIgnoresCancelledOldCredentialTransfer() async throws {
        var token = "old-token"
        let fixture = try DeliveryFixture(connection: {
            try DeliveryConfiguration(endpoint: "https://example.com/capture", token: token)
        })
        defer { fixture.cleanUp() }
        let started = expectation(description: "old credentials have an active upload")
        CaptureHTTPStub.begin = { _ in started.fulfill() }
        try await fixture.service.enqueue()
        await fulfillment(of: [started], timeout: 10)
        let confirmed = expectation(description: "replacement credentials confirm the same capture")
        token = "new-token"
        let receipt = fixture.receipt
        CaptureHTTPStub.begin = { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            request.complete(data: receipt)
        }
        fixture.service.onChange = {
            if fixture.record.state == .delivered { fixture.service.onChange = nil; confirmed.fulfill() }
        }
        try await fixture.service.connectionChanged()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(fixture.record.state, .delivered)
        XCTAssertNil(fixture.record.lastError)
        XCTAssertNil(fixture.record.nextAttemptAt)
        XCTAssertEqual(try CaptureStore(directory: fixture.directory).records().first?.state, .delivered)
    }

    func testSavedRetryDeadlineWakesWithoutAnotherInvocation() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        fixture.record.nextAttemptAt = Date().addingTimeInterval(0.15)
        try fixture.store.save()
        let confirmed = expectation(description: "saved retry wakes and persists receipt")
        let receipt = fixture.receipt
        CaptureHTTPStub.reply = { _ in receipt }
        fixture.service.onChange = { if fixture.record.state == .delivered { fixture.service.onChange = nil; confirmed.fulfill() } }
        try await fixture.service.enqueue()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(try CaptureStore(directory: fixture.directory).records().first?.state, .delivered)
    }

    func testInvalidatedSessionDoesNotWakeItsScheduledRetry() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        fixture.record.nextAttemptAt = Date().addingTimeInterval(0.15)
        try fixture.store.save()
        let unexpected = expectation(description: "invalidated session must not send")
        unexpected.isInverted = true
        CaptureHTTPStub.begin = { _ in unexpected.fulfill() }
        try await fixture.service.enqueue()
        fixture.service.session.finishTasksAndInvalidate()
        await fulfillment(of: [unexpected], timeout: 0.4)
        XCTAssertEqual(fixture.record.state, .matched)
    }

    func testStartingRetryInvalidatesAnUnannouncedNotAddedReceipt() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let id = fixture.record.id.uuidString.lowercased()
        try fixture.store.deliveryFinished(fixture.record, status: 503,
            data: Data("{\"ok\":false,\"capture_id\":\"\(id)\",\"spotify_outcome\":\"not_added\"}".utf8))
        fixture.record.nextAttemptAt = .distantPast
        try fixture.store.save()
        let started = expectation(description: "retry in flight")
        CaptureHTTPStub.begin = { _ in started.fulfill() }
        try await fixture.service.enqueue()
        await fulfillment(of: [started], timeout: 5)
        // Check persisted state, since background uploads can outlive the app.
        let reopened = try CaptureStore(directory: fixture.directory)
        var requests: [UNNotificationRequest] = []
        await CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) },
            existingRequests: { ([], []) }).reconcile(store: reopened)
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized"])
    }

    func testOutcomeRetriesKeepImmutablePayloadAndOnlyAnnounceDefinitiveFailure() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        var requests: [UNNotificationRequest] = []
        let notifications = CaptureNotifications(authorization: { .authorized }, schedule: { requests.append($0) },
                                                  existingRequests: { ([], []) })
        let confirmed = expectation(description: "all durable stages reconciled")
        fixture.service.onRecordsChanged = {
            await notifications.reconcile(store: fixture.store)
            if fixture.record.state == .delivered { confirmed.fulfill() }
        }
        await notifications.reconcile(store: fixture.store)
        let id = fixture.record.id.uuidString.lowercased()
        var bodies: [Data] = []
        var dates: [Date] = []
        CaptureHTTPStub.response = { request in
            bodies.append(request.httpBody ?? Data())
            dates.append(Date())
            let outcome = bodies.count == 1 ? "not_added" : bodies.count == 2 ? "unknown" : "added"
            let ok = bodies.count >= 4
            let detail = ok ? "\"isrc\":\"XX0000000001\"" : "\"message\":\"capture unavailable\""
            return (ok ? 200 : 503, ["Retry-After": "0.15"],
                Data("{\"ok\":\(ok),\"capture_id\":\"\(id)\",\(detail),\"spotify_outcome\":\"\(outcome)\"}".utf8))
        }
        try await fixture.service.enqueue()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(bodies.count, 4)
        XCTAssertEqual(Set(bodies).count, 1, "Retries must send exactly the same capture ID and metadata")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(bodies.first)) as? [String: Any])
        XCTAssertEqual(payload["capture_id"] as? String, id)
        for (first, second) in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(second.timeIntervalSince(first), 0.15)
        }
        XCTAssertEqual(requests.map(\.content.title), ["Song recognized", "Couldn't add to Spotify"])
        XCTAssertEqual(fixture.record.state, .delivered)
        fixture.service.onRecordsChanged = nil
    }

    func testTransientFailureRetriesWithoutAnotherInvocation() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let confirmed = expectation(description: "failed upload retries and persists receipt")
        let receipt = fixture.receipt
        var attempts = 0
        var attemptDates: [Date] = []
        CaptureHTTPStub.response = { _ in
            attempts += 1
            attemptDates.append(Date())
            return attempts == 1 ? (503, ["Retry-After": "0.15"], Data()) : (200, [:], receipt)
        }
        fixture.service.onChange = { if fixture.record.state == .delivered { fixture.service.onChange = nil; confirmed.fulfill() } }
        try await fixture.service.enqueue()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(attempts, 2)
        if attemptDates.count == 2 {
            XCTAssertGreaterThanOrEqual(attemptDates[1].timeIntervalSince(attemptDates[0]), 0.15,
                                        "A retry must respect the service's Retry-After deadline")
        }
        XCTAssertEqual(fixture.record.state, .delivered)
    }

    func testConnectionSaveSendsExistingMatchWithoutAnotherInvocation() async throws {
        let key = "test-" + UUID().uuidString
        let connection = ConnectionStore(service: key)
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: key] as CFDictionary) }
        let fixture = try DeliveryFixture(connection: { try connection.load() })
        defer { fixture.cleanUp() }
        let controller = CaptureController(store: fixture.store, delivery: fixture.service,
            recordAudio: { throw CaptureError.microphoneDenied }, recognize: { _ in nil })
        XCTAssertNotNil(controller.connectionIssue)
        let confirmed = expectation(description: "saving connection sends the existing song")
        let receipt = fixture.receipt
        CaptureHTTPStub.reply = { _ in receipt }
        fixture.service.onChange = {
            controller.refresh()
            if fixture.record.state == .delivered { fixture.service.onChange = nil; confirmed.fulfill() }
        }
        try await fixture.service.enqueue()
        XCTAssertEqual(fixture.record.state, .matched)
        try connection.save(DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token"))
        try await fixture.service.connectionChanged()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(fixture.record.state, .delivered)
        XCTAssertNil(controller.connectionIssue)
    }

    func testUnauthorizedConnectionStaysPausedAcrossReopeningAndAppResume() async throws {
        let fixture = try DeliveryFixture()
        defer { fixture.cleanUp() }
        let rejected = expectation(description: "authorization failure persists")
        let repeated = expectation(description: "invalid credentials are not sent again")
        repeated.isInverted = true
        var attempts = 0
        CaptureHTTPStub.response = { _ in
            attempts += 1
            if attempts > 1 { repeated.fulfill() }
            return (401, [:], Data())
        }
        fixture.service.onChange = { if fixture.record.lastError != nil { fixture.service.onChange = nil; rejected.fulfill() } }
        try await fixture.service.enqueue()
        await fulfillment(of: [rejected], timeout: 10)
        fixture.service.onChange = nil
        fixture.record.nextAttemptAt = Date(timeIntervalSinceNow: -1)
        try fixture.store.save()
        let reopened = try CaptureStore(directory: fixture.directory)
        let service = DeliveryService(store: reopened, uploadDirectory: fixture.directory.appendingPathComponent("uploads"),
                                      connection: fixture.service.connection,
                                      sessionConfiguration: fixture.service.sessionConfiguration)
        defer { service.session.invalidateAndCancel() }
        try await service.enqueue()
        await fulfillment(of: [repeated], timeout: 0.3)
        XCTAssertEqual(try reopened.records().first?.state, .matched)
        XCTAssertNotNil(service.connectionIssue)
        let confirmed = expectation(description: "saving a corrected connection unblocks the saved song")
        let receipt = fixture.receipt
        CaptureHTTPStub.response = { _ in (200, [:], receipt) }
        service.onChange = {
            if (try? reopened.records().first?.state) == .delivered { service.onChange = nil; confirmed.fulfill() }
        }
        try await service.connectionChanged()
        await fulfillment(of: [confirmed], timeout: 10)
        XCTAssertEqual(try reopened.records().first?.state, .delivered)
        XCTAssertFalse(try XCTUnwrap(reopened.records().first).deliveryBlocked)
        XCTAssertNil(service.connectionIssue)
    }

    func testConnectionIsStoredAndUpdatedInKeychain() throws {
        let key = "test-" + UUID().uuidString
        let store = ConnectionStore(service: key)
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: key] as CFDictionary) }
        XCTAssertNil(try store.load())
        try store.save(DeliveryConfiguration(endpoint: "https://example.com/capture", token: "first"))
        XCTAssertEqual(try ConnectionStore(service: key).load()?.token, "first")
        try store.save(DeliveryConfiguration(endpoint: "https://example.com/capture", token: "second"))
        XCTAssertEqual(try ConnectionStore(service: key).load()?.token, "second")
    }

    func testActualUploadResponseDrivesPersistentAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = CaptureRecord()
        store.context.insert(record)
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPStub.self]
        let received = expectation(description: "persisted receipt")
        CaptureHTTPStub.reply = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.httpMethod, "POST")
            return Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8)
        }
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
                                      connection: { try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token") },
                                      sessionConfiguration: configuration)
        service.onChange = { if record.state == .delivered { service.onChange = nil; received.fulfill() } }
        try await service.enqueue()
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(record.state, .delivered)
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().first?.state, .delivered)
        service.session.finishTasksAndInvalidate()
    }
}

import Security

final class CaptureHTTPStub: URLProtocol, @unchecked Sendable {
    static var reply: ((URLRequest) -> Data)?
    static var response: ((URLRequest) -> (Int, [String: String], Data))?
    static var begin: ((CaptureHTTPStub) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let begin = Self.begin { begin(self); return }
        // URLSession hands protocols an in-memory body as a stream, never as httpBody.
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            stream.open()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = body
        }
        let result = Self.response?(request) ?? (200, [:], Self.reply?(request) ?? Data())
        complete(status: result.0, headers: result.1, data: result.2)
    }
    func complete(status: Int = 200, headers: [String: String] = [:], data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class DeliveryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: CaptureStore
    let record: CaptureRecord
    let service: DeliveryService
    var receipt: Data { Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8) }

    init(connection: @escaping () throws -> DeliveryConfiguration? = {
        try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token")
    }, existingTasks: (() async -> [URLSessionTask])? = nil) throws {
        store = try CaptureStore(directory: directory)
        let generator = SHSignatureGenerator()
        try generator.append(streamingFixture(seconds: 2), at: nil)
        record = try store.capture(signature: generator.signature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPStub.self]
        service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
                                  connection: connection, sessionConfiguration: configuration, retryDelay: 0.05,
                                  existingTasks: existingTasks)
    }

    func cleanUp() {
        service.onChange = nil
        service.session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
