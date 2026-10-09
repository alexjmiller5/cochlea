import AVFoundation
import ShazamKit
import SwiftData
import XCTest
@testable import Cochlea

@MainActor
final class CaptureTests: XCTestCase {
    func testRenamedApplicationKeepsQueueSignatureAndUploadPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("offline-shazam")
        let signature = try makeSignature()
        var id: UUID!
        do {
            let store = try CaptureStore(directory: old)
            let record = try store.capture(signature: signature)
            id = record.id
            try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        }
        let uploads = old.appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try Data("pending-upload".utf8).write(to: uploads.appendingPathComponent("payload.json"))
        let destination = try CaptureStore.applicationDirectory(in: root)
        XCTAssertEqual(destination.lastPathComponent, "cochlea")
        let store = try CaptureStore(directory: destination)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.state, .matched)
        XCTAssertEqual(try store.signature(for: record), signature.dataRepresentation)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("uploads/payload.json")), Data("pending-upload".utf8))
        XCTAssertEqual(try CaptureStore.applicationDirectory(in: root), destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testRenameNeverOverwritesAnExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["offline-shazam", "cochlea"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: root.appendingPathComponent(name + "/marker"))
        }
        XCTAssertThrowsError(try CaptureStore.applicationDirectory(in: root))
        for name in ["offline-shazam", "cochlea"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name + "/marker")), Data(name.utf8))
        }
    }

    func testExistingQueueMigratesWithoutLosingMatchedSongOrRetryDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let deadline = Date(timeIntervalSince1970: 2000)
        do {
            let container = try ModelContainer(for: OriginalCaptureSchema.CaptureRecord.self,
                configurations: ModelConfiguration(url: directory.appendingPathComponent("queue.sqlite")))
            let context = ModelContext(container)
            let record = OriginalCaptureSchema.CaptureRecord(id: id)
            record.title = "Example Song"
            record.artist = "Example Artist"
            record.isrc = "XX0000000001"
            record.nextAttemptAt = deadline
            context.insert(record)
            try context.save()
        }
        let reopened = try CaptureStore(directory: directory)
        let record = try XCTUnwrap(reopened.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.metadata?.title, "Example Song")
        XCTAssertEqual(record.metadata?.isrc, "XX0000000001")
        XCTAssertEqual(record.state, .matched)
        XCTAssertEqual(record.nextAttemptAt, deadline)
        XCTAssertFalse(record.deliveryBlocked)
    }

    func testRetryAfterCannotCauseAnImmediateFailureLoop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        let now = Date(timeIntervalSince1970: 1000)
        for retryAfter in ["0", "-1", "nan", "inf", "bad", "Thu, 01 Jan 1970 00:00:00 GMT"] {
            record.failedDeliveries = 0 // parsing only; backoff has its own test
            try store.deliveryFinished(record, status: 503, data: Data(), retryAfter: retryAfter, now: now)
            XCTAssertEqual(record.nextAttemptAt, Date(timeIntervalSince1970: 1030))
        }
        try store.deliveryFinished(record, status: 429, data: Data(), retryAfter: "Thu, 01 Jan 1970 00:20:00 GMT", now: now)
        XCTAssertEqual(record.nextAttemptAt, Date(timeIntervalSince1970: 1200))
    }

    func testOfflineCaptureSurvivesReopeningWithOriginalSignature() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signature = try makeSignature()
        var identifier: UUID!
        do {
            let store = try CaptureStore(directory: directory)
            identifier = try store.capture(signature: signature).id
        }
        let reopened = try CaptureStore(directory: directory)
        let records = try reopened.records()
        XCTAssertEqual(records.count, 1, "A capture must be saved before reporting success")
        let saved = try XCTUnwrap(records.first)
        XCTAssertEqual(saved.id, identifier)
        XCTAssertEqual(saved.state, .pending)
        let restored = try SHSignature(dataRepresentation: reopened.signature(for: saved))
        XCTAssertEqual(restored.duration, signature.duration, accuracy: 0.001)
    }

    func testSignatureWriteFailureDoesNotCreateSuccessfulCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        try FileManager.default.removeItem(at: store.signatureDirectory)
        try Data().write(to: store.signatureDirectory)
        XCTAssertThrowsError(try store.capture(signature: makeSignature()))
        XCTAssertTrue(try store.records().isEmpty)
    }

    func testNextUseProcessesSavedCapturesAndPrioritizesCurrentCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let older = try store.capture(signature: makeSignature())
        let current = try store.capture(signature: makeSignature())
        let metadata = MatchMetadata(title: "Example Song", artist: "Example Artist")
        let processor = CaptureProcessor(store: store) { _ in metadata }
        try await processor.process(preferred: current.id, limit: 1)
        XCTAssertEqual(current.metadata, metadata)
        XCTAssertEqual(current.state, .matched)
        XCTAssertEqual(older.state, .pending, "A bounded invocation leaves its remaining backlog durable")
        try await processor.process()
        XCTAssertEqual(older.state, .matched)
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().filter { $0.state == .matched }.count, 2)
    }

    func testRecognitionFailureAndNoMatchDoNotBlockLaterCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let first = try store.capture(signature: makeSignature())
        let second = try store.capture(signature: makeSignature())
        let third = try store.capture(signature: makeSignature())
        var calls = 0
        let processor = CaptureProcessor(store: store) { _ in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            if calls == 2 { return nil }
            return MatchMetadata(title: "Example Song", artist: "Example Artist")
        }
        try await processor.process()
        XCTAssertEqual(first.state, .pending)
        XCTAssertNotNil(first.lastError)
        XCTAssertEqual(second.state, .unmatched)
        XCTAssertEqual(third.state, .matched)
        XCTAssertFalse(try store.signature(for: first).isEmpty)
    }

    func testSignatureOutsideTheCatalogRangeIsUnmatchedNotRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        var calls = 0
        let processor = CaptureProcessor(store: store) { _ in
            calls += 1
            throw NSError(domain: SHErrorDomain, code: SHError.Code.signatureDurationInvalid.rawValue)
        }
        try await processor.process()
        XCTAssertEqual(record.state, .unmatched)
        XCTAssertTrue(record.lastError?.contains("length") == true)
        try await processor.process()
        XCTAssertEqual(calls, 1, "A rejected length must not be retried on every use")
    }

    // Captures saved before the 12-second cap hold ~16 s signatures that Shazam rejects (SHError 201).
    func testOverlongSavedSignatureIsCutToTwelveSecondsAndIdentified() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (signature, catalog) = try overlongSignatureAndCatalog()
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: signature)
        let processor = CaptureProcessor(store: store) { try await ShazamMatcher(session: SHSession(catalog: catalog)).match($0) }
        try await processor.process()
        XCTAssertEqual(record.state, .matched, record.lastError ?? "")
        XCTAssertEqual(record.title, "Example Song")
        XCTAssertEqual(try SHSignature(dataRepresentation: store.signature(for: record)).duration, 12, accuracy: 0.01)
    }

    func testCaptureRejectedForLengthByAnEarlierVersionIsIdentifiedAfterUpgrade() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (signature, catalog) = try overlongSignatureAndCatalog()
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: signature)
        record.state = .unmatched
        record.lastError = "This recording's length cannot be identified by Shazam."
        try store.save()
        let processor = CaptureProcessor(store: store) { try await ShazamMatcher(session: SHSession(catalog: catalog)).match($0) }
        try await processor.process()
        XCTAssertEqual(record.state, .matched, record.lastError ?? "")
    }

    func testDamagedOrMissingSignatureStopsRetryingAndSaysWhy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let damaged = try store.capture(signature: makeSignature())
        try Data("not a signature".utf8).write(to: store.signatureDirectory.appendingPathComponent(damaged.id.uuidString + ".shazamsignature"))
        let missing = try store.capture(signature: makeSignature())
        try FileManager.default.removeItem(at: store.signatureDirectory.appendingPathComponent(missing.id.uuidString + ".shazamsignature"))
        var calls = 0
        // ShazamKit's own SHError 200 for unreadable data. Raised here rather than through
        // ShazamMatcher: XCTest's error observation aborts the test host when an async
        // method throws before its first suspension.
        let processor = CaptureProcessor(store: store) {
            calls += 1
            _ = try SHSignature(dataRepresentation: $0)
            return nil
        }
        try await processor.process()
        for record in [damaged, missing] {
            XCTAssertEqual(record.state, .unmatched, "A capture Shazam can never read must not stay pending")
            XCTAssertTrue(record.lastError?.contains("can't identify") == true, record.lastError ?? "")
        }
        try await processor.process()
        XCTAssertEqual(calls, 1, "Only the damaged file reaches Shazam, and only once")
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().map(\.state), [.unmatched, .unmatched])
    }

    func testTransientShazamFailuresKeepTheCaptureForAnotherAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        for error: Error in [NSError(domain: SHErrorDomain, code: SHError.Code.matchAttemptFailed.rawValue), URLError(.timedOut),
                             CocoaError(.fileReadNoPermission)] {
            try await CaptureProcessor(store: store) { _ in throw error }.process()
            XCTAssertEqual(record.state, .pending, "\(error)")
        }
    }

    func testTrimOnlyShortensOverlongShazamSignatures() throws {
        let (signature, _) = try overlongSignatureAndCatalog()
        let trimmed = try XCTUnwrap(CatalogLimits.trimmed(signature.dataRepresentation))
        XCTAssertEqual(try SHSignature(dataRepresentation: trimmed).duration, 12, accuracy: 0.01)
        XCTAssertLessThan(trimmed.count, signature.dataRepresentation.count)
        XCTAssertNil(CatalogLimits.trimmed(trimmed), "A signature that fits is left as it is")
        XCTAssertNil(CatalogLimits.trimmed(try makeSignature().dataRepresentation))
        var damaged = signature.dataRepresentation
        damaged[100] ^= 0xff
        XCTAssertNil(CatalogLimits.trimmed(damaged), "A checksum mismatch is not rewritten")
        for data in [Data(), Data("not a signature".utf8), signature.dataRepresentation.prefix(200)] {
            XCTAssertNil(CatalogLimits.trimmed(data))
        }
    }

    func testNoExactSpotifyMatchIsNotOnSpotifyAndRecheckedDaily() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        let now = Date(timeIntervalSince1970: 1000)
        let noMatch = Data("""
            {"ok":false,"capture_id":"\(record.id)","spotify_outcome":"not_added","reason":"no_match",\
            "message":"Could not find Example Song by Example Artist on Spotify","isrc":null}
            """.utf8)
        for retryAfter in ["86400", nil] {
            try store.deliveryFinished(record, status: 422, data: noMatch, retryAfter: retryAfter, now: now)
            XCTAssertEqual(record.state, .matched, "A song Spotify may add later is kept for the daily recheck")
            XCTAssertEqual(record.deliveryStatus, .notOnSpotify)
            XCTAssertEqual(record.nextAttemptAt, now.addingTimeInterval(86400), "Checked once a day, never every 30 seconds")
            XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now),
                           "Not on Spotify (no exact match)")
        }
        XCTAssertEqual(try CaptureStore(directory: directory).records().first?.deliveryStatus, .notOnSpotify)
    }

    func testAcceptedCaptureIsSavedToMusicSyncAndItsStatusDecidesTheOutcome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        let other = try store.capture(signature: makeSignature())
        try store.matched(other, metadata: MatchMetadata(title: "Other Song", artist: "Example Artist"))
        let now = Date(timeIntervalSince1970: 1000)
        let queued = view(record, status: "queued")
        try store.deliveryFinished(record, status: 202, data: queued, now: now)
        XCTAssertEqual(record.state, .accepted, "Music Sync holds it now; the upload is done")
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now), "Saved to Music Sync")
        XCTAssertEqual(record.nextAttemptAt, now.addingTimeInterval(15), "The first status check follows shortly")
        try store.deliveryFinished(other, status: 202, data: queued, now: now)
        XCTAssertEqual(other.state, .matched, "Another capture's acceptance proves nothing")

        try store.statusChecked(record, status: 200, data: view(record, status: "queued", retryAt: "1970-01-01T00:30:00.000Z"), now: now)
        XCTAssertEqual(record.nextAttemptAt, Date(timeIntervalSince1970: 1800), "Music Sync's retry time decides the next check")
        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            try store.statusChecked(record, status: 200, data: queued, now: now)
            delays.append(try XCTUnwrap(record.nextAttemptAt).timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [60, 120, 240], "Checks back off while it stays queued")
        XCTAssertEqual(record.state, .accepted)

        try store.statusChecked(record, status: 200, data: view(record, status: "added", isrc: "XX0000000001"), now: now)
        XCTAssertEqual(record.state, .delivered)
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now), "Added to Spotify")
        XCTAssertThrowsError(try store.signature(for: record), "Delivery removes the signature")
        XCTAssertEqual(try CaptureStore(directory: directory).records().first { $0.id == record.id }?.state, .delivered)
    }

    func testStatusCheckShowsNotOnSpotifyAndRecoversAMissingOrRejectedCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1000)
        func accepted() throws -> CaptureRecord {
            let record = try store.capture(signature: makeSignature())
            try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
            try store.deliveryFinished(record, status: 202, data: view(record, status: "queued"), now: now)
            return record
        }
        let missing = try accepted()
        try store.statusChecked(missing, status: 200, data: view(missing, status: "not_added", reason: "no_match",
                                                                 retryAt: "1970-01-02T00:00:00.000Z"), now: now)
        XCTAssertEqual(missing.state, .accepted)
        XCTAssertEqual(missing.deliveryStatus, .notOnSpotify)
        XCTAssertEqual(missing.spotifyOutcome, .notAdded)
        XCTAssertEqual(missing.nextAttemptAt, Date(timeIntervalSince1970: 86400))
        XCTAssertEqual(missing.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now),
                       "Not on Spotify (no exact match)")
        XCTAssertEqual(missing.lastError, "Music Sync checks Spotify again " + CaptureRecord.retryTime(Date(timeIntervalSince1970: 86400), now: now) + ".")

        let forgotten = try accepted()
        try store.statusChecked(forgotten, status: 404, data: Data(), now: now)
        XCTAssertEqual(forgotten.state, .matched, "A capture Music Sync does not know is sent again")
        XCTAssertNil(forgotten.nextAttemptAt)

        let revoked = try accepted()
        try store.statusChecked(revoked, status: 200, data: view(revoked, status: "rejected"), now: now)
        XCTAssertEqual(revoked.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now), "Needs reconnect")
        let unauthorized = try accepted()
        try store.statusChecked(unauthorized, status: 401, data: Data(), now: now)
        XCTAssertTrue(unauthorized.deliveryBlocked)

        let mismatched = try accepted()
        try store.statusChecked(mismatched, status: 200, data: view(revoked, status: "added", isrc: "XX0000000001"), now: now)
        XCTAssertEqual(mismatched.state, .accepted, "Another capture's status proves nothing")
    }

    private func view(_ record: CaptureRecord, status: String, isrc: String? = nil, reason: String? = nil,
                      retryAt: String? = nil) -> Data {
        let fields: [String: Any] = [
            "ok": status != "not_added", "capture_id": record.id.uuidString.lowercased(), "status": status,
            "spotify_outcome": status == "added" ? "added" : "not_added", "isrc": isrc ?? NSNull(),
            "title": "Example Song", "artist": "Example Artist", "retry_at": retryAt ?? NSNull(), "reason": reason ?? NSNull(),
        ]
        return try! JSONSerialization.data(withJSONObject: fields)
    }

    func testSpotifyRateLimitShowsBusyUntilItsRetryAfter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        let now = Date(timeIntervalSince1970: 1000)
        let busy = Data("""
            {"ok":false,"message":"Spotify is rate limiting; retry later","capture_id":"\(record.id)","spotify_outcome":"not_added"}
            """.utf8)
        try store.deliveryFinished(record, status: 503, data: busy, retryAfter: "72000", now: now)
        XCTAssertEqual(record.deliveryStatus, .spotifyBusy)
        XCTAssertEqual(record.nextAttemptAt, now.addingTimeInterval(72000))
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now),
                       "Spotify busy, retrying at " + CaptureRecord.retryTime(now.addingTimeInterval(72000), now: now))
        XCTAssertEqual(record.deliveryLabel(isUploading: true, isOnline: true, connectionIssue: nil, now: now), "Sending to Spotify…")
        try store.deliveryFinished(record, status: 200, data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8), now: now)
        XCTAssertEqual(record.state, .delivered)
        XCTAssertNil(record.deliveryStatus)
    }

    func testRepeatedFailuresBackOffInsteadOfRetryingEveryThirtySeconds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        let now = Date(timeIntervalSince1970: 1000)
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            try store.deliveryFinished(record, status: 0, data: Data(), now: now)
            delays.append(try XCTUnwrap(record.nextAttemptAt).timeIntervalSince(now))
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
        XCTAssertEqual(record.deliveryStatus, .retrying)
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now),
                       "Retrying at " + CaptureRecord.retryTime(now.addingTimeInterval(3600), now: now))
        try store.deliveryFinished(record, status: 401, data: Data(), now: now)
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: true, connectionIssue: nil, now: now), "Needs reconnect")
        XCTAssertEqual(record.deliveryLabel(isUploading: false, isOnline: false, connectionIssue: nil, now: now), "Waiting for internet")
        try store.deliveryFinished(record, status: 200, data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8), now: now)
        XCTAssertEqual(record.failedDeliveries, 0)
    }

    func testExportArchiveCarriesEveryRecordingSignatureAndItsMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("audio".utf8).write(to: clip)
        let delivered = try store.capture(signature: makeSignature(), recording: clip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path), "The store owns the recording")
        try store.matched(delivered, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist",
            appleMusicID: "1", shazamURL: "https://www.shazam.com/track/1", isrc: "XX0000000001"))
        try store.deliveryFinished(delivered, status: 200, data: Data("{\"ok\":true,\"capture_id\":\"\(delivered.id)\",\"isrc\":\"XX0000000001\"}".utf8))
        let waiting = try store.capture(signature: makeSignature())
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try CaptureArchive.stage(store: store, into: stage)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stage.appendingPathComponent("captures.json"))) as? [[String: Any]])
        XCTAssertEqual(manifest.count, 2)
        let first = try XCTUnwrap(manifest.first { $0["capture_id"] as? String == delivered.id.uuidString.lowercased() })
        XCTAssertEqual(first["title"] as? String, "Example Song")
        XCTAssertEqual(first["artist"] as? String, "Example Artist")
        XCTAssertEqual(first["isrc"] as? String, "XX0000000001")
        XCTAssertEqual(first["apple_music_id"] as? String, "1")
        XCTAssertEqual(first["shazam_url"] as? String, "https://www.shazam.com/track/1")
        XCTAssertEqual(first["state"] as? String, "delivered")
        XCTAssertEqual(first["spotify_outcome"] as? String, "added")
        XCTAssertNotNil(first["created_at"] as? String)
        let recording = try XCTUnwrap(first["recording"] as? String)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(recording)), Data("audio".utf8))
        XCTAssertTrue(first["signature"] is NSNull, "Delivery removes the signature; the recording stays")
        let second = try XCTUnwrap(manifest.first { $0["capture_id"] as? String == waiting.id.uuidString.lowercased() })
        let signature = try XCTUnwrap(second["signature"] as? String)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent(signature)), try store.signature(for: waiting))
        XCTAssertTrue(second["recording"] is NSNull)
        let archive = try CaptureArchive.make(store: store)
        defer { try? FileManager.default.removeItem(at: archive) }
        XCTAssertEqual(archive.pathExtension, "zip")
        XCTAssertEqual(try Data(contentsOf: archive).prefix(2), Data("PK".utf8))
    }

    func testDeliveryRequiresMatchingBodyAcknowledgementAndPreservesMetadataForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        let metadata = MatchMetadata(title: "Example Song", artist: "Example Artist")
        try store.matched(record, metadata: metadata)
        for response in ["{\"ok\":false}", "{\"ok\":true}", "{\"ok\":true,\"capture_id\":\"\(UUID())\",\"isrc\":\"XX0000000001\"}", "not json"] {
            try store.deliveryFinished(record, status: 200, data: Data(response.utf8))
            XCTAssertEqual(record.state, .matched)
            XCTAssertEqual(record.metadata, metadata)
            XCTAssertNotNil(record.lastError)
        }
        let now = Date(timeIntervalSince1970: 1000)
        try store.deliveryFinished(record, status: 429, data: Data(), retryAfter: "120", now: now)
        XCTAssertEqual(record.nextAttemptAt, Date(timeIntervalSince1970: 1120))
        try store.deliveryFinished(record, status: 200, data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000001\"}".utf8))
        XCTAssertEqual(record.state, .delivered)
        XCTAssertNil(record.lastError)
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().first?.state, .delivered)
    }

    func testMatchedCaptureIsNotRecognizedAgainWhenDeliveryIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist"))
        let processor = CaptureProcessor(store: store) { _ in
            XCTFail("A delivery retry must reuse already matched metadata")
            return nil
        }
        try await processor.process()
        XCTAssertEqual(record.state, .matched)
    }

    func testReceiptMustAcknowledgeTheRecordingShazamIdentified() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let record = try store.capture(signature: makeSignature())
        try store.matched(record, metadata: MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001"))
        let reopened = try CaptureStore(directory: directory)
        XCTAssertEqual(try reopened.records().first?.metadata?.isrc, "XX0000000001")
        try store.deliveryFinished(record, status: 200, data: Data("{\"ok\":true,\"capture_id\":\"\(record.id)\",\"isrc\":\"XX0000000002\"}".utf8))
        XCTAssertEqual(record.state, .matched, "A different recording is not a successful delivery")
        XCTAssertFalse(try store.signature(for: record).isEmpty)
    }

    private func overlongSignatureAndCatalog() throws -> (SHSignature, SHCustomCatalog) {
        let generator = SHSignatureGenerator()
        try generator.append(streamingFixture(seconds: 16), at: nil)
        let signature = generator.signature()
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(signature, representing: [SHMediaItem(properties: [.title: "Example Song", .artist: "Example Artist"])])
        try catalog.addReferenceSignature(unrelatedSignature(), representing: [SHMediaItem(properties: [.title: "Other Song", .artist: "Example Artist"])])
        return (signature, catalog)
    }

    private func unrelatedSignature() throws -> SHSignature {
        let generator = SHSignatureGenerator()
        try generator.append(streamingFixture(seconds: 16, seed: 54321), at: nil)
        return generator.signature()
    }

    private func makeSignature() throws -> SHSignature {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
        buffer.frameLength = 88200
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100)) * 0.25
        }
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        return generator.signature()
    }
}

// The previously shipped model, kept here only to exercise native lightweight migration.
private enum OriginalCaptureSchema {
    @Model
    final class CaptureRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var stateValue: String
        var title: String?
        var artist: String?
        var appleMusicID: String?
        var shazamURL: String?
        var appleMusicURL: String?
        var isrc: String?
        var lastError: String?
        var nextAttemptAt: Date?
        var lastAttemptAt: Date?

        init(id: UUID) {
            self.id = id
            createdAt = Date()
            stateValue = "matched"
        }
    }
}
