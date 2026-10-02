import AVFoundation
import ShazamKit
import XCTest
@testable import OfflineShazam

@MainActor
final class IntegrationTests: XCTestCase {
    func testLiveAudioMatchesBeforeDeadlineAndItsSavedSignatureMatchesTheSameRecording() async throws {
        let buffer = try streamingFixture()
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(generator.signature(), representing: [
            SHMediaItem(properties: [.title: "Example Song", .artist: "Example Artist", .ISRC: "XX0000000001"])
        ])
        let recorder = AudioRecorder()
        let stream = StreamingAudio(session: SHSession(catalog: catalog))
        let finished = expectation(description: "native streaming match finishes before the 15 second deadline")
        var captured: CapturedAudio?
        var captureError: Error?
        var stopped = false
        let task = Task { @MainActor in
            do {
                captured = try await recorder.capture(using: stream, start: {
                    try stream.append(buffer, at: nil)
                }, stop: { stopped = true })
            } catch { captureError = error }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)
        task.cancel()
        await task.value
        XCTAssertNil(captureError)
        XCTAssertTrue(stopped, "An early match must release the audio source")
        let audio = try XCTUnwrap(captured)
        XCTAssertEqual(audio.metadata?.isrc, "XX0000000001")
        XCTAssertEqual(audio.signature.duration, 10, accuracy: 0.1)
        let restored = try SHSignature(dataRepresentation: audio.signature.dataRepresentation)
        let match = try await ShazamMatcher(session: SHSession(catalog: catalog)).match(restored.dataRepresentation)
        XCTAssertEqual(match, audio.metadata, "The durable fallback must represent the same audio that matched live")
    }

    func testConfigurationRejectsCredentialsInURLAndInsecureEndpoints() throws {
        for value in ["http://example.com/capture", "https://user:secret@example.com/capture", "https://example.com/capture?token=secret", "https://example.com/capture#token", "not a url"] {
            XCTAssertThrowsError(try DeliveryConfiguration(endpoint: value, token: "token"))
        }
        XCTAssertThrowsError(try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "\n"))
        XCTAssertThrowsError(try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "secret\nInjected: header"))
        XCTAssertThrowsError(try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "tok\u{200B}en")) { error in
            XCTAssertTrue(error.localizedDescription.contains("position 4: U+200B"), error.localizedDescription)
        }
        XCTAssertThrowsError(try DeliveryConfiguration(endpoint: "https://example.com/capture", token: "  ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("empty"), error.localizedDescription)
        }
        let config = try DeliveryConfiguration(endpoint: " https://example.com/capture ", token: "token")
        XCTAssertEqual(config.endpoint.absoluteString, "https://example.com/capture")
    }

    func testUploadCarriesOnlyTheConsumerContractAndStableCaptureID() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let metadata = MatchMetadata(title: "Example Song", artist: "Example Artist", appleMusicURL: "https://music.apple.com/example")
        let body = try CapturePayload(id: id, metadata: metadata).data()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["capture_id": "00000000-0000-4000-8000-000000000001", "title": "Example Song", "artist": "Example Artist", "apple_music_id": "", "shazam_url": ""])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("token"))
    }

    func testRecordedAudioGeneratesASignatureThatMatchesThroughNativeSDK() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
        buffer.frameLength = 441000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        var seed: UInt32 = 12345
        for index in 0..<Int(buffer.frameLength) {
            seed = 1664525 &* seed &+ 1013904223
            samples[index] = (Float(seed) / Float(UInt32.max) - 0.5) * 0.7
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let signature = try await AudioCapture.signature(from: url)
        XCTAssertEqual(signature.duration, 10, accuracy: 0.1)
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(signature, representing: [SHMediaItem(properties: [.title: "Example Song", .artist: "Example Artist", .ISRC: "XX0000000001"])])
        let matcher = ShazamMatcher(session: SHSession(catalog: catalog))
        let result = try await matcher.match(signature.dataRepresentation)
        XCTAssertEqual(result?.title, "Example Song")
        XCTAssertEqual(result?.artist, "Example Artist")
        XCTAssertEqual(result?.isrc, "XX0000000001")
    }

    func testImportedClipIsTrimmedToTheCatalogMaximumAndShortClipsAreRejected() async throws {
        for (seconds, expected) in [(20, 12.0), (2, nil)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
            let buffer = try streamingFixture(seconds: seconds)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            if let expected {
                let signature = try await AudioCapture.signature(from: url)
                XCTAssertEqual(signature.duration, expected, accuracy: 0.1)
            } else {
                do { _ = try await AudioCapture.signature(from: url); XCTFail("A clip below 3 seconds can never be matched") }
                catch { XCTAssertEqual(error.localizedDescription, CaptureError.invalidAudio.localizedDescription) }
            }
        }
    }

    func testUploadIncludesRecordingIdentityWhenShazamProvidesIt() throws {
        let metadata = MatchMetadata(title: "Example Song", artist: "Example Artist", isrc: "XX0000000001")
        let body = try CapturePayload(id: UUID(), metadata: metadata).data()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["isrc"], "XX0000000001")
    }
}
