import Foundation
import OSLog
import ShazamKit
import zlib

// Shazam's catalog only matches saved signatures of 3 to 12 seconds (SHError 201 otherwise).
// Live streaming recognition has no such limit, so recording runs longer than the saved part.
enum CatalogLimits {
    static let minimumSeconds = 3.0
    static let maximumSeconds = 12.0

    /// The first 12 seconds of a longer saved signature, or nil when it already fits or is not
    /// in Shazam's format. Apple's container wraps Shazam's signature (layout as documented by
    /// SongRec's signature_format.rs): a 48-byte header with a CRC32 and the sample count, then
    /// one peak list per frequency band, each peak keyed by its 128-sample FFT pass at 16 kHz.
    static func trimmed(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        func read(_ source: [UInt8], _ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= source.count else { return nil }
            return (0..<4).reduce(0) { $0 | UInt32(source[offset + $1]) << (8 * UInt32($1)) }
        }
        func append(_ value: UInt32, to target: inout [UInt8]) {
            target += (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
        }
        func write(_ value: UInt32, at offset: Int, in target: inout [UInt8]) {
            for index in 0..<4 { target[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
        }
        func checksum(_ raw: [UInt8]) -> UInt32 { UInt32(crc32(0, Array(raw[8...]), UInt32(raw.count - 8))) }
        guard read(bytes, 0) == 0x2580_2580, let start = read(bytes, 8).map(Int.init), start + 56 <= bytes.count else { return nil }
        let raw = Array(bytes[start...])
        let rates: [UInt32: Double] = [1: 8000, 2: 11025, 3: 16000, 4: 32000, 5: 44100, 6: 48000]
        guard read(raw, 0) == 0xcafe_2580, read(raw, 8).map(Int.init) == raw.count - 48, read(raw, 4) == checksum(raw),
              read(raw, 48) == 0x4000_0000, let rate = read(raw, 28).flatMap({ rates[$0 >> 27] }),
              let samples = read(raw, 40) else { return nil }
        let padding = rate * 0.24 // the sample count field includes 240 ms of the sample rate
        guard Double(samples) - padding > maximumSeconds * rate else { return nil }
        let end = Int(maximumSeconds * 125)
        var bands: [UInt8] = []
        var offset = 56
        while offset < raw.count {
            guard let band = read(raw, offset), let length = read(raw, offset + 4).map(Int.init),
                  offset + 8 + length <= raw.count else { return nil }
            let peaks = Array(raw[(offset + 8)..<(offset + 8 + length)])
            offset += 8 + length + (4 - length % 4) % 4
            // Each peak: a 1-byte pass delta (0xff = absolute 4-byte pass follows), magnitude, frequency.
            var kept: [UInt8] = []
            var index = 0, pass = 0, written = 0
            while index < peaks.count {
                if peaks[index] == 0xff {
                    guard let absolute = read(peaks, index + 1) else { return nil }
                    pass = Int(absolute)
                    index += 5
                    continue
                }
                guard index + 5 <= peaks.count else { return nil }
                pass += Int(peaks[index])
                guard pass >= written else { return nil }
                if pass < end {
                    if pass - written >= 255 { kept.append(0xff); append(UInt32(pass), to: &kept); written = pass }
                    kept.append(UInt8(pass - written))
                    kept += peaks[(index + 1)..<(index + 5)]
                    written = pass
                }
                index += 5
            }
            guard !kept.isEmpty else { continue }
            append(band, to: &bands)
            append(UInt32(kept.count), to: &bands)
            bands += kept + [UInt8](repeating: 0, count: (4 - kept.count % 4) % 4)
        }
        var result = Array(raw[0..<56]) + bands
        write(UInt32(result.count - 48), at: 8, in: &result)
        write(UInt32(maximumSeconds * rate + padding), at: 40, in: &result)
        write(UInt32(result.count - 48), at: 52, in: &result)
        write(checksum(result), at: 4, in: &result)
        return Data(bytes[0..<start] + result)
    }
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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cochlea", category: "recognition")

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

    /// 0.3.2 and earlier gave up on signatures over 12 seconds; they are now cut to fit.
    static let legacyLengthRejection = "This recording's length cannot be identified by Shazam."

    /// Failures no later attempt can change: Shazam rejecting the saved signature itself, or its file being gone.
    static func permanentFailure(_ error: Error) -> String? {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (SHErrorDomain, SHError.Code.signatureDurationInvalid.rawValue):
            return "Shazam can't identify a recording of this length."
        case (SHErrorDomain, SHError.Code.signatureInvalid.rawValue):
            return "This saved recording is damaged, so Shazam can't identify it."
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            return "This saved recording is missing, so Shazam can't identify it."
        default:
            return nil
        }
    }

    func process(preferred: UUID? = nil, limit: Int = 3, didProcess: () async -> Void = {}) async throws {
        guard !processing, limit > 0 else { return }
        processing = true
        defer { processing = false }
        let pending = try store.records().filter {
            $0.state == .pending || ($0.state == .unmatched && $0.lastError == Self.legacyLengthRejection)
        }.sorted {
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
                var signature = try store.signature(for: record)
                if let trimmed = CatalogLimits.trimmed(signature) {
                    try store.replaceSignature(of: record, with: trimmed)
                    signature = trimmed
                }
                if let metadata = try await recognize(signature) {
                    try store.matched(record, metadata: metadata)
                } else {
                    record.state = .unmatched
                    record.lastError = "Shazam could not identify this recording."
                }
            } catch {
                if !(error is CancellationError) { RecognitionDiagnostics.log(error) }
                if let reason = Self.permanentFailure(error) {
                    // Retrying cannot help; the capture list offers Retry and Delete instead.
                    record.state = .unmatched
                    record.lastError = reason
                } else {
                    record.lastError = "Recognition interrupted. Saved for next use."
                    try store.save()
                    if error is CancellationError { throw error }
                }
            }
            try store.save()
            await didProcess()
        }
    }
}
