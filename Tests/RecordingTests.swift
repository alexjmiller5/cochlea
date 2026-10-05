import AVFoundation
import ShazamKit
import XCTest
@testable import Cochlea

@MainActor
final class RecordingTests: XCTestCase {
    func testOfflineDeadlinePreservesAudioForRecognitionOnNextUse() async throws {
        let recorder = AudioRecorder()
        let stream = StreamingAudio(session: try unrelatedStreamingSession())
        let audio = try await recorder.capture(using: stream, start: {
            try stream.append(streamingFixture(seconds: 4), at: nil)
            stream.session(stream.session, didNotFindMatchFor: SHSignatureGenerator().signature(), error: URLError(.notConnectedToInternet))
        }, stop: {}, timeout: .milliseconds(30))
        XCTAssertNil(audio.metadata)
        XCTAssertEqual(audio.signature.duration, 4, accuracy: 0.1)
    }

    func testSavedSignatureStopsAtTheCatalogMaximumWhileStreamingContinues() async throws {
        let recorder = AudioRecorder()
        let stream = StreamingAudio(session: try unrelatedStreamingSession())
        let audio = try await recorder.capture(using: stream, start: {
            try stream.append(streamingFixture(seconds: 8), at: nil)
            try stream.append(streamingFixture(seconds: 8, seed: 777), at: nil)
        }, stop: {}, timeout: .milliseconds(30))
        XCTAssertEqual(audio.signature.duration, CatalogLimits.maximumSeconds, accuracy: 0.1)
    }

    func testInterruptionBelowTheCatalogMinimumIsAnError() async throws {
        let recorder = AudioRecorder()
        let stream = StreamingAudio(session: try unrelatedStreamingSession())
        let started = expectation(description: "recording started")
        let task = Task { @MainActor in
            try await recorder.capture(using: stream, start: {
                try stream.append(streamingFixture(seconds: 2), at: nil)
                started.fulfill()
            }, stop: {})
        }
        await fulfillment(of: [started], timeout: 10)
        interrupt()
        do { _ = try await task.value; XCTFail("Two seconds can never be matched and must not be saved") }
        catch { XCTAssertEqual(error.localizedDescription, CaptureError.recordingInterrupted.localizedDescription) }
    }

    func testInterruptionPreservesUsefulAudioAndAnOldCaptureCannotFinishTheNextOne() async throws {
        let recorder = AudioRecorder()
        let old = StreamingAudio(session: try unrelatedStreamingSession())
        let started = expectation(description: "first recording starts")
        let first = Task { @MainActor in
            try await recorder.capture(using: old, start: {
                try old.append(streamingFixture(), at: nil)
                started.fulfill()
            }, stop: {})
        }
        await fulfillment(of: [started], timeout: 10)
        interrupt()
        let saved = try await first.value
        XCTAssertEqual(saved.signature.duration, 10, accuracy: 0.1)
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(saved.signature, representing: [SHMediaItem(properties: [.title: "Example Song", .artist: "Example Artist"])])
        let nativeResult = await SHSession(catalog: catalog).result(from: saved.signature)
        guard case .match(let staleMatch) = nativeResult else { return XCTFail("The saved fixture should match natively") }
        let current = StreamingAudio(session: try unrelatedStreamingSession())
        let nextStarted = expectation(description: "next recording starts")
        var finished = false
        let second = Task { @MainActor in
            let result = try await recorder.capture(using: current, start: { nextStarted.fulfill() }, stop: {})
            finished = true
            return result
        }
        await fulfillment(of: [nextStarted], timeout: 10)
        try old.append(streamingFixture(seconds: 2), at: nil)
        old.session(old.session, didFind: staleMatch)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished)
        second.cancel()
        do { _ = try await second.value; XCTFail("No audio should remain a cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationPreservesAudioAndStopsTheSource() async throws {
        let recorder = AudioRecorder()
        let stream = StreamingAudio(session: try unrelatedStreamingSession())
        let started = expectation(description: "recording starts")
        var stopped = false
        let task = Task { @MainActor in
            try await recorder.capture(using: stream, start: {
                try stream.append(streamingFixture(seconds: 4), at: nil)
                started.fulfill()
            }, stop: { stopped = true })
        }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        let audio = try await task.value
        XCTAssertEqual(audio.signature.duration, 4, accuracy: 0.1)
        XCTAssertTrue(stopped)
    }

    func testInterruptionWithoutAudioRemainsAnError() async {
        let recorder = AudioRecorder()
        let started = expectation(description: "recording started")
        let task = Task { @MainActor in
            try await recorder.capture(using: StreamingAudio(), start: { started.fulfill() }, stop: {})
        }
        await fulfillment(of: [started], timeout: 10)
        interrupt()
        do { _ = try await task.value; XCTFail("An empty recording cannot be saved") }
        catch { XCTAssertEqual(error.localizedDescription, CaptureError.recordingInterrupted.localizedDescription) }
    }

    private func interrupt() {
        #if os(iOS)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #else
        NotificationCenter.default.post(name: AudioRecorder.interruptionNotification, object: nil)
        #endif
    }
}
