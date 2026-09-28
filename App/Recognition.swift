import Foundation
import OSLog
import ShazamKit

// Shazam's catalog only matches saved signatures of 3 to 12 seconds (SHError 201 otherwise).
// Live streaming recognition has no such limit, so recording runs longer than the saved part.
enum CatalogLimits {
    static let minimumSeconds = 3.0
    static let maximumSeconds = 12.0
}

struct MatchMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    var appleMusicID: String? = nil
    var shazamURL: String? = nil
    var appleMusicURL: String? = nil
    var isrc: String? = nil
}

extension MatchMetadata {
    init?(_ item: SHMediaItem) {
        guard let title = item.title, let artist = item.artist else { return nil }
        self.init(title: title, artist: artist, appleMusicID: item.appleMusicID,
                  shazamURL: item.webURL?.absoluteString, appleMusicURL: item.appleMusicURL?.absoluteString, isrc: item.isrc)
    }
}

enum RecognitionDiagnostics {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "offline-shazam", category: "recognition")

    static func log(_ error: Error) {
        let error = error as NSError
        logger.error("Recognition failed: \(error.domain, privacy: .public) code \(error.code)")
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("Underlying failure: \(underlying.domain, privacy: .public) code \(underlying.code)")
        }
    }
}

@MainActor
final class CaptureProcessor {
    let store: CaptureStore
    let recognize: (Data) async throws -> MatchMetadata?
    private var processing = false

    init(store: CaptureStore, recognize: @escaping (Data) async throws -> MatchMetadata?) {
        self.store = store
        self.recognize = recognize
    }

    func process(preferred: UUID? = nil, limit: Int = 3, didProcess: () async -> Void = {}) async throws {
        guard !processing, limit > 0 else { return }
        processing = true
        defer { processing = false }
        let pending = try store.records().filter { $0.state == .pending }.sorted {
            if $0.id == $1.id { return false }
            if $0.id == preferred { return true }
            if $1.id == preferred { return false }
            let left = $0.lastAttemptAt ?? .distantPast
            let right = $1.lastAttemptAt ?? .distantPast
            return left == right ? $0.createdAt < $1.createdAt : left < right
        }
        for record in pending.prefix(limit) {
            try Task.checkCancellation()
            record.lastAttemptAt = Date()
            do {
                if let metadata = try await recognize(store.signature(for: record)) {
                    try store.matched(record, metadata: metadata)
                } else {
                    record.state = .unmatched
                    record.lastError = "Shazam could not identify this recording."
                }
            } catch let error as NSError where error.domain == SHErrorDomain
                        && error.code == SHError.Code.signatureDurationInvalid.rawValue {
                // The catalog will never accept this length; retrying cannot help.
                record.state = .unmatched
                record.lastError = "This recording's length cannot be identified by Shazam."
            } catch {
                if !(error is CancellationError) { RecognitionDiagnostics.log(error) }
                record.lastError = "Recognition interrupted. Saved for next use."
                try store.save()
                if error is CancellationError { throw error }
            }
            try store.save()
            await didProcess()
        }
    }
}
