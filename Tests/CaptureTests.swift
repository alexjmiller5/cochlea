import AVFoundation
import ShazamKit
import SwiftData
import XCTest
@testable import OfflineShazam

@MainActor
final class CaptureTests: XCTestCase {
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
