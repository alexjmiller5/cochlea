import AVFoundation
import ShazamKit

struct CapturedAudio {
    let signature: SHSignature
    var metadata: MatchMetadata? = nil
}

// The audio tap and Shazam callbacks run outside the main actor. The lock also
// makes the saved signature a consistent snapshot when capture finishes.
final class StreamingAudio: NSObject, SHSessionDelegate, @unchecked Sendable {
    let session: SHSession
    private let generator = SHSignatureGenerator()
    private let lock = NSLock()
    private var active = true
    private var generatedSeconds = 0.0
    private var metadata: MatchMetadata?
    private var onMatch: (() -> Void)?

    init(session: SHSession = SHSession()) {
        self.session = session
        super.init()
        session.delegate = self
    }

    func start(onMatch: @escaping () -> Void) {
        lock.lock()
        self.onMatch = onMatch
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws {
        lock.lock()
        guard active else { lock.unlock(); return }
        // The saved signature stops at the catalog maximum; streaming keeps the whole buffer.
        let original = buffer.frameLength
        let rate = buffer.format.sampleRate
        let remaining = max(0, Int((CatalogLimits.maximumSeconds - generatedSeconds) * rate))
        if remaining < Int(original) { buffer.frameLength = AVAudioFrameCount(remaining) }
        defer { buffer.frameLength = original }
        if buffer.frameLength > 0 {
            do { try generator.append(buffer, at: time) }
            catch { lock.unlock(); throw error }
            generatedSeconds += Double(buffer.frameLength) / rate
        }
        lock.unlock()
        buffer.frameLength = original
        session.matchStreamingBuffer(buffer, at: time)
    }

    func finish() -> CapturedAudio {
        lock.lock()
        active = false
        onMatch = nil
        let audio = CapturedAudio(signature: generator.signature(), metadata: metadata)
        lock.unlock()
        session.delegate = nil
        return audio
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let metadata = match.mediaItems.first.flatMap(MatchMetadata.init) else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        self.metadata = metadata
        let callback = onMatch
        lock.unlock()
        callback?()
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error { RecognitionDiagnostics.log(error) }
        // A missed window or temporary network failure must not discard audio.
    }
}

@MainActor
final class AudioRecorder {
    private var continuation: CheckedContinuation<CapturedAudio, Error>?
    private var deadline: Task<Void, Never>?
    private var recordingID: UUID?
    private var requestingCapture = false

    func capture() async throws -> CapturedAudio {
        guard !requestingCapture, recordingID == nil else { throw CaptureError.alreadyRecording }
        requestingCapture = true
        defer { requestingCapture = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard allowed else { throw CaptureError.microphoneDenied }
        try Task.checkCancellation()
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        defer { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, [48000, 44100, 32000, 16000].contains(format.sampleRate) else {
            throw CaptureError.invalidAudio
        }
        let stream = StreamingAudio()
        var installedTap = false
        return try await capture(using: stream, start: {
            guard let id = self.recordingID else { throw CaptureError.recordingInterrupted }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                do { try stream.append(buffer, at: time) }
                catch {
                    RecognitionDiagnostics.log(error)
                    Task { @MainActor in self.finish(id: id, stream: stream, error: error) }
                }
            }
            installedTap = true
            engine.prepare()
            try engine.start()
        }, stop: {
            engine.stop()
            if installedTap { input.removeTap(onBus: 0) }
        })
    }

    func capture(using stream: StreamingAudio, start: () throws -> Void,
                 stop: () -> Void, timeout: Duration = .seconds(15)) async throws -> CapturedAudio {
        guard recordingID == nil else { throw CaptureError.alreadyRecording }
        let id = UUID()
        recordingID = id
        let observer = NotificationCenter.default.addObserver(
            forName: Self.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard Self.isInterruptionBegan(notification) else { return }
            MainActor.assumeIsolated { self?.finish(id: id, stream: stream, error: CaptureError.recordingInterrupted) }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            stop()
            if recordingID == id { recordingID = nil }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                stream.start { [weak self] in
                    Task { @MainActor in self?.finish(id: id, stream: stream) }
                }
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(id: id, stream: stream)
                }
                do { try start() }
                catch { finish(id: id, stream: stream, error: error) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id: id, stream: stream, error: CancellationError()) }
        }
    }

    #if os(iOS)
    static let interruptionNotification = AVAudioSession.interruptionNotification
    static func isInterruptionBegan(_ notification: Notification) -> Bool {
        (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
    }
    #else
    // macOS has no audio session; engine configuration changes are the equivalent interruption.
    static let interruptionNotification = Notification.Name.AVAudioEngineConfigurationChange
    static func isInterruptionBegan(_ notification: Notification) -> Bool { true }
    #endif

    private func finish(id: UUID, stream: StreamingAudio, error: Error? = nil) {
        guard recordingID == id, let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        let audio = stream.finish()
        if audio.signature.duration >= CatalogLimits.minimumSeconds { continuation.resume(returning: audio) }
        else { continuation.resume(throwing: error ?? CaptureError.invalidAudio) }
    }
}
