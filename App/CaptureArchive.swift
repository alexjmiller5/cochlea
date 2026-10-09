import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Every capture's recording, Shazam signature and song details as one zip, so
/// nothing the app captured is locked inside it.
enum CaptureArchive {
    /// Writes `captures.json`, `recordings/` and `signatures/` into `folder`.
    @MainActor
    static func stage(store: CaptureStore, into folder: URL) throws {
        let files = FileManager.default
        let recordings = folder.appendingPathComponent("recordings", isDirectory: true)
        let signatures = folder.appendingPathComponent("signatures", isDirectory: true)
        try files.createDirectory(at: recordings, withIntermediateDirectories: true)
        try files.createDirectory(at: signatures, withIntermediateDirectories: true)
        let time = ISO8601DateFormatter()
        let manifest: [[String: Any]] = try store.records().map { record in
            let id = record.id.uuidString.lowercased()
            var recording: String?
            if let source = store.recording(for: record) {
                recording = "recordings/\(id).\(source.pathExtension)"
                try files.copyItem(at: source, to: folder.appendingPathComponent(recording!))
            }
            var signature: String?
            if let data = try? store.signature(for: record) {
                signature = "signatures/\(id).shazamsignature"
                try data.write(to: folder.appendingPathComponent(signature!))
            }
            let fields: [String: Any?] = [
                "capture_id": id, "created_at": time.string(from: record.createdAt), "state": record.state.rawValue,
                "title": record.title, "artist": record.artist, "isrc": record.isrc,
                "apple_music_id": record.appleMusicID, "apple_music_url": record.appleMusicURL, "shazam_url": record.shazamURL,
                "spotify_outcome": record.spotifyOutcome?.rawValue, "delivery_status": record.deliveryStatus?.rawValue,
                "last_error": record.lastError,
                "last_attempt_at": record.lastAttemptAt.map(time.string(from:)),
                "next_attempt_at": record.nextAttemptAt.map(time.string(from:)),
                "recording": recording, "signature": signature,
            ]
            return fields.mapValues { $0 ?? NSNull() }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("captures.json"))
    }

    /// The zip in a fresh temporary folder, named for today.
    @MainActor
    static func make(store: CaptureStore, now: Date = Date()) throws -> URL {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = "Cochlea captures \(now.formatted(.iso8601.year().month().day()))"
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try stage(store: store, into: folder)
        defer { try? files.removeItem(at: folder) }
        let archive = work.appendingPathComponent(name + ".zip")
        // Reading a folder "for uploading" makes Foundation hand over a zip of it.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            do { try files.copyItem(at: zip, to: archive) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return archive
    }
}

/// The share sheet builds the archive only when a destination is picked.
struct CaptureExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { _ in
            SentTransferredFile(try await MainActor.run { try CaptureArchive.make(store: Runtime.controller.get().store) })
        }
    }
}
