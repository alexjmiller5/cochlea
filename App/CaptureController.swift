import Foundation
import Observation
import ShazamKit

@MainActor @Observable
final class CaptureController {
    let store: CaptureStore
    let delivery: DeliveryService
    let recordAudio: () async throws -> CapturedAudio
    let processor: CaptureProcessor
    let recordingActivity: RecordingActivity?
    var isOnline = true
    var isRecording = false
    var isProcessing = false
    var records: [CaptureRecord] = []
    var status: String?
    var connectionIssue: String?
    var uploadingIDs: Set<UUID> = []
    @ObservationIgnored var onRecordsChanged: (() async -> Void)?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var processingID: UUID?
    @ObservationIgnored private var recordingTask: Task<CapturedAudio, Error>?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var discardRecording = false

    init(store: CaptureStore, delivery: DeliveryService,
         recordAudio: @escaping () async throws -> CapturedAudio,
         recognize: @escaping (Data) async throws -> MatchMetadata?,
         recordingActivity: RecordingActivity? = nil) {
        self.store = store
        self.delivery = delivery
        self.recordAudio = recordAudio
        self.recordingActivity = recordingActivity
        processor = CaptureProcessor(store: store, recognize: recognize)
        delivery.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func capture(requiresLiveActivity: Bool = false) async throws -> CaptureRecord {
        guard !isRecording else { throw CaptureError.alreadyRecording }
        status = nil
        processingTask?.cancel()
        let record = try await recordAndSave(requiresLiveActivity: requiresLiveActivity)
        status = "Capture saved."
        refresh()
        await resume(preferred: record.id)
        return record
    }

    /// The `cochlea://capture` link: the same capture as the Shortcut, Control and menu-bar
    /// item. A link arriving while one records leaves it running instead of canceling it.
    func startCapture() async {
        do { _ = try await capture() }
        catch is CancellationError {}
        catch CaptureError.alreadyRecording {}
        catch { status = (error as? CaptureError)?.errorDescription ?? "Could not save this capture. Please try again." }
    }

    func cancelCapture(id: UUID? = nil) {
        guard isRecording, id == nil || id == recordingID else { return }
        discardRecording = true
        recordingTask?.cancel()
        status = "Capture canceled."
    }

    private func recordAndSave(requiresLiveActivity: Bool) async throws -> CaptureRecord {
        isRecording = true
        discardRecording = false
        let id = UUID()
        recordingID = id
        defer {
            isRecording = false
            recordingTask = nil
            recordingID = nil
        }
        let task = Task { @MainActor in
            do {
                if let recordingActivity {
                    do { try await recordingActivity.start(id: id) }
                    catch { if requiresLiveActivity { throw error } }
                } else if requiresLiveActivity {
                    throw RecordingActivityError.unavailable
                }
                try Task.checkCancellation()
                return try await recordAudio()
            } catch {
                await recordingActivity?.end()
                throw error
            }
        }
        recordingTask = task
        let audio = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        // OS/lifetime cancellation may preserve useful audio. Only the user's
        // explicit cancel action discards it before anything reaches the queue.
        guard !discardRecording else {
            audio.recording.map { try? FileManager.default.removeItem(at: $0) }
            await recordingActivity?.end()
            throw CancellationError()
        }
        do {
            let record = try store.capture(signature: audio.signature, recording: audio.recording)
            if let metadata = audio.metadata { try store.matched(record, metadata: metadata) }
            // Shown only once the capture is durable, so "saved" is never a promise.
            await recordingActivity?.finish(showing: audio.metadata.map { .recognized(title: $0.title, artist: $0.artist) }
                                            ?? (isOnline ? .noMatch : .savedForLater))
            return record
        } catch {
            audio.recording.map { try? FileManager.default.removeItem(at: $0) }
            await recordingActivity?.end()
            throw error
        }
    }

    func importAudio(_ url: URL) async throws -> CaptureRecord {
        let signature = try await AudioCapture.signature(from: url)
        // The caller owns the imported file; the store keeps its own copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        let recording = (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? nil : copy
        let record: CaptureRecord
        do { record = try store.capture(signature: signature, recording: recording) }
        catch { recording.map { try? FileManager.default.removeItem(at: $0) }; throw error }
        status = "Capture saved."
        refresh()
        await resume(preferred: record.id)
        return record
    }

    func refresh() {
        connectionIssue = delivery.connectionIssue
        uploadingIDs = delivery.uploadingIDs
        do { records = try store.records() }
        catch { status = "Could not read saved captures. Reopen the app to try again." }
    }

    func resume(preferred: UUID? = nil) async {
        guard !isRecording || preferred != nil else { return }
        while let existing = processingTask {
            guard preferred != nil else { return }
            let existingID = processingID
            existing.cancel()
            await existing.value
            if processingID == existingID {
                processingTask = nil
                processingID = nil
                isProcessing = false
            }
        }
        guard !Task.isCancelled else { return }
        let id = UUID()
        processingID = id
        isProcessing = true
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                async let recovery: Void = delivery.recoverConnection()
                await enqueueMatches()
                if isOnline {
                    try await processor.process(preferred: preferred) { await self.enqueueMatches() }
                }
                await recovery
            } catch is CancellationError {
                // Cancellation leaves durable work for the next invocation.
            } catch {
                status = "Saved captures will continue on your next use."
            }
            refresh()
        }
        processingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if processingID == id {
            processingTask = nil
            processingID = nil
            isProcessing = false
        }
    }

    private func enqueueMatches() async {
        refresh()
        await onRecordsChanged?()
        do { try await delivery.enqueue() }
        catch { status = "Saved captures will continue on your next use." }
    }
}
