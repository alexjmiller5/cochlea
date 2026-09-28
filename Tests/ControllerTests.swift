import AVFoundation
import ShazamKit
import XCTest
@testable import OfflineShazam

@MainActor
final class ControllerTests: XCTestCase {
    func testExplicitCancelDiscardsEmptyAndUsefulAudioAndAllowsAnotherCapture() async throws {
        for seconds in [0, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try CaptureStore(directory: directory)
            let older = try store.capture(signature: SHSignatureGenerator().signature())
            let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
                connection: { nil }, sessionConfiguration: .ephemeral)
            let recorder = AudioRecorder()
            let started = expectation(description: "recording started with \(seconds) seconds")
            var attempt = 0
            var stopped = false
            let controller = CaptureController(store: store, delivery: service, recordAudio: {
                attempt += 1
                if attempt == 2 { return CapturedAudio(signature: SHSignatureGenerator().signature()) }
                let stream = StreamingAudio(session: try unrelatedStreamingSession())
                return try await recorder.capture(using: stream, start: {
                    if seconds > 0 { try stream.append(streamingFixture(seconds: seconds), at: nil) }
                    started.fulfill()
                }, stop: { stopped = true }, timeout: .milliseconds(200))
            }, recognize: { _ in nil })
            controller.isOnline = false
            let capture = Task { @MainActor in _ = try await controller.capture() }
            await fulfillment(of: [started], timeout: 1)
            controller.cancelCapture()
            do { _ = try await capture.value; XCTFail("Explicit cancellation must discard even useful audio") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(stopped)
            XCTAssertFalse(controller.isRecording)
            XCTAssertEqual(try CaptureStore(directory: directory).records().map(\.id), [older.id])
            _ = try await controller.capture()
            XCTAssertEqual(try store.records().count, 2)
            service.session.finishTasksAndInvalidate()
        }
    }

    func testCanceledCaptureKeepsItsAudioAndRetriesAutomaticallyOnNextUse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { nil }, sessionConfiguration: .ephemeral)
        let recorder = AudioRecorder()
        let started = expectation(description: "audio captured before cancellation")
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            let stream = StreamingAudio(session: try unrelatedStreamingSession())
            return try await recorder.capture(using: stream, start: {
                try stream.append(streamingFixture(seconds: 4), at: nil)
                started.fulfill()
            }, stop: {})
        }, recognize: { _ in MatchMetadata(title: "Example Song", artist: "Example Artist") })
        let capture = Task { _ = try await controller.capture() }
        await fulfillment(of: [started], timeout: 1)
        capture.cancel()
        try await capture.value
        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.state, .pending)
        XCTAssertEqual(try SHSignature(dataRepresentation: store.signature(for: record)).duration, 2, accuracy: 0.1)
        XCTAssertEqual(try CaptureStore(directory: directory).records().count, 1)
        await controller.resume()
        XCTAssertEqual(record.state, .matched)
        service.session.finishTasksAndInvalidate()
    }

    func testLiveMatchIsPersistedAndUploadedBeforeRetryingOlderCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let older = try store.capture(signature: SHSignatureGenerator().signature())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPStub.self]
        let uploaded = expectation(description: "live match uploads during older recognition")
        CaptureHTTPStub.reply = { _ in uploaded.fulfill(); return Data("{}".utf8) }
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token") },
            sessionConfiguration: configuration)
        let backlogStarted = expectation(description: "older recognition starts")
        let metadata = MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001")
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            CapturedAudio(signature: SHSignatureGenerator().signature(), metadata: metadata)
        }, recognize: { data in
            XCTAssertEqual(data, try store.signature(for: older), "A live match must reuse its captured metadata")
            backlogStarted.fulfill()
            try await Task.sleep(for: .seconds(60))
            return nil
        })
        let capture = Task { _ = try await controller.capture() }
        await fulfillment(of: [backlogStarted, uploaded], timeout: 2)
        let persisted = try CaptureStore(directory: directory).records().first { $0.id != older.id }
        XCTAssertEqual(persisted?.metadata, metadata)
        XCTAssertEqual(controller.records.first(where: { $0.id != older.id })?.metadata, metadata)
        capture.cancel()
        try await capture.value
        service.session.finishTasksAndInvalidate()
    }

    func testCurrentCaptureUploadsAndAppearsBeforeOlderRecognitionFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let older = try store.capture(signature: SHSignatureGenerator().signature())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureHTTPStub.self]
        let uploaded = expectation(description: "current match uploads while backlog waits")
        CaptureHTTPStub.reply = { _ in uploaded.fulfill(); return Data("{}".utf8) }
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"),
            connection: { try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "test-token") },
            sessionConfiguration: configuration)
        let backlogStarted = expectation(description: "older recognition is waiting")
        var calls = 0
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in
            calls += 1
            if calls == 2 {
                backlogStarted.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
            return MatchMetadata(title: "Example Song", artist: "Example Artist")
        })
        let capture = Task { _ = try await controller.capture() }
        await fulfillment(of: [backlogStarted], timeout: 2)
        XCTAssertEqual(controller.records.first(where: { $0.id != older.id })?.metadata?.title, "Example Song")
        await fulfillment(of: [uploaded], timeout: 1)
        capture.cancel()
        _ = try await capture.value
        service.session.finishTasksAndInvalidate()
    }

    func testImportedAudioIsAttemptedBeforeReturningEvenWhenAnotherPassIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        _ = try store.capture(signature: SHSignatureGenerator().signature())
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"), connection: { nil }, sessionConfiguration: .ephemeral)
        let started = expectation(description: "older recognition started")
        var matches = 0
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            XCTFail("Import must not start another microphone recording")
            return CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in
            matches += 1
            if matches == 1 { started.fulfill(); try await Task.sleep(for: .seconds(60)) }
            return MatchMetadata(title: "Example Song", artist: "Example Artist")
        })
        let previous = Task { await controller.resume() }
        await fulfillment(of: [started], timeout: 2)
        let url = directory.appendingPathComponent("capture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 220500))
        buffer.frameLength = 220500
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(Double(index) * 0.07)) * 0.5 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let imported = try await controller.importAudio(url)
        XCTAssertEqual(imported.state, .matched, "An import must not return while excluded from the current pass")
        previous.cancel()
        await previous.value
        service.session.finishTasksAndInvalidate()
    }

    func testStartingAnotherCaptureCancelsBacklogWithoutClearingTheNewRecordingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"), connection: { nil }, sessionConfiguration: .ephemeral)
        let firstMatching = expectation(description: "first capture begins matching")
        let secondRecording = expectation(description: "second recording starts promptly")
        var recordings = 0
        var matches = 0
        var finishRecording: CheckedContinuation<Void, Never>?
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            recordings += 1
            if recordings == 2 {
                await withCheckedContinuation { continuation in
                    finishRecording = continuation
                    secondRecording.fulfill()
                }
            }
            return CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in
            matches += 1
            if matches == 1 {
                firstMatching.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
            return MatchMetadata(title: "Example Song", artist: "Example Artist")
        })
        let first = Task { @MainActor in _ = try await controller.capture() }
        await fulfillment(of: [firstMatching], timeout: 3)
        let second = Task { @MainActor in _ = try await controller.capture() }
        await fulfillment(of: [secondRecording], timeout: 3)
        _ = try await first.value
        XCTAssertTrue(controller.isRecording, "Finishing the previous request must not enable a third recording")
        finishRecording?.resume()
        _ = try await second.value
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(recordings, 2)
        service.session.finishTasksAndInvalidate()
    }

    func testOfflineCaptureThenNextOnlineUseRecordsBeforeProcessingBacklog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"), connection: { nil }, sessionConfiguration: .ephemeral)
        var events: [String] = []
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            events.append("record")
            return CapturedAudio(signature: SHSignatureGenerator().signature())
        }, recognize: { _ in
            events.append("recognize")
            return MatchMetadata(title: "Example Song", artist: "Example Artist")
        })
        controller.isOnline = false
        let first = try await controller.capture()
        XCTAssertEqual(events, ["record"])
        XCTAssertEqual(first.state, .pending)
        XCTAssertEqual(try CaptureStore(directory: directory).records().count, 1)
        controller.isOnline = true
        _ = try await controller.capture()
        XCTAssertEqual(events, ["record", "record", "recognize", "recognize"])
        XCTAssertEqual(try store.records().filter { $0.state == .matched }.count, 2)
        service.session.finishTasksAndInvalidate()
    }

    func testFailedRecordingDoesNotClaimToSaveOrTouchTheBacklog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CaptureStore(directory: directory)
        let service = DeliveryService(store: store, uploadDirectory: directory.appendingPathComponent("uploads"), connection: { nil }, sessionConfiguration: .ephemeral)
        let controller = CaptureController(store: store, delivery: service, recordAudio: {
            throw CaptureError.microphoneDenied
        }, recognize: { _ in
            XCTFail("Do not process a backlog ahead of the requested capture")
            return nil
        })
        do { _ = try await controller.capture(); XCTFail("The caller must receive the recording failure") }
        catch { XCTAssertEqual(error.localizedDescription, CaptureError.microphoneDenied.localizedDescription) }
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertFalse(controller.isRecording)
        service.session.finishTasksAndInvalidate()
    }
}
