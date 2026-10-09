import Foundation
import ShazamKit
import SwiftData

enum CaptureState: String, Codable {
    case pending, matched, delivered, unmatched
}

enum SpotifyOutcome: String {
    case added, notAdded = "not_added", unknown
}

/// Why the last delivery attempt did not confirm the song, as the capture list shows it.
enum DeliveryStatus: String {
    case spotifyBusy = "spotify_busy", notOnSpotify = "not_on_spotify", retrying
}

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
    var deliveryBlocked: Bool = false
    var notificationEligible: Bool = false
    var recognitionNotificationDate: Date?
    var deliveryNotificationScheduled: Bool = false
    var spotifyOutcomeValue: String?
    var spotifyFailureNotificationDate: Date?
    var deliveryStatusValue: String?
    var failedDeliveries: Int = 0
    var deliveryStartedAt: Date?

    var deliveryStatus: DeliveryStatus? {
        get { deliveryStatusValue.flatMap(DeliveryStatus.init(rawValue:)) }
        set { deliveryStatusValue = newValue?.rawValue }
    }

    var spotifyOutcome: SpotifyOutcome? {
        get { spotifyOutcomeValue.flatMap(SpotifyOutcome.init(rawValue:)) }
        set { spotifyOutcomeValue = newValue?.rawValue }
    }

    var state: CaptureState {
        get { CaptureState(rawValue: stateValue) ?? .pending }
        set { stateValue = newValue.rawValue }
    }

    init(id: UUID = UUID()) {
        self.id = id
        createdAt = Date()
        stateValue = CaptureState.pending.rawValue
    }

    var metadata: MatchMetadata? {
        guard let title, let artist else { return nil }
        return MatchMetadata(title: title, artist: artist, appleMusicID: appleMusicID, shazamURL: shazamURL, appleMusicURL: appleMusicURL, isrc: isrc)
    }
}

@MainActor
final class CaptureStore {
    let container: ModelContainer
    let context: ModelContext
    let signatureDirectory: URL
    let recordingDirectory: URL

    static func applicationDirectory(in root: URL) throws -> URL {
        let destination = root.appendingPathComponent("cochlea", isDirectory: true)
        let previous = root.appendingPathComponent("offline-shazam", isDirectory: true)
        let files = FileManager.default
        if files.fileExists(atPath: previous.path) {
            // An atomic move preserves the queue, SQLite sidecars, signatures and uploads.
            // Refuse a collision instead of silently hiding or overwriting either queue.
            try files.moveItem(at: previous, to: destination)
        }
        return destination
    }

    init(directory: URL) throws {
        signatureDirectory = directory.appendingPathComponent("signatures", isDirectory: true)
        recordingDirectory = directory.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: signatureDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        container = try ModelContainer(for: CaptureRecord.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("queue.sqlite")))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func records() throws -> [CaptureRecord] {
        try context.fetch(FetchDescriptor<CaptureRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func signatureURL(_ record: CaptureRecord) -> URL {
        signatureDirectory.appendingPathComponent(record.id.uuidString + ".shazamsignature")
    }

    /// Saves a capture; a `recording` file is moved into the store and kept for export.
    func capture(signature: SHSignature, recording: URL? = nil) throws -> CaptureRecord {
        let record = CaptureRecord()
        let url = signatureURL(record)
        try signature.dataRepresentation.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if let recording {
            let destination = recordingDirectory.appendingPathComponent(record.id.uuidString)
                .appendingPathExtension(recording.pathExtension.isEmpty ? "m4a" : recording.pathExtension)
            // The capture is already durable; a recording that cannot be kept is dropped, not fatal.
            if (try? FileManager.default.moveItem(at: recording, to: destination)) == nil {
                try? FileManager.default.removeItem(at: recording)
            }
        }
        return record
    }

    func recording(for record: CaptureRecord) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == record.id.uuidString }
    }

    func signature(for record: CaptureRecord) throws -> Data {
        try Data(contentsOf: signatureURL(record))
    }

    func replaceSignature(of record: CaptureRecord, with data: Data) throws {
        try data.write(to: signatureURL(record), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func save() throws {
        do { try context.save() }
        catch { context.rollback(); throw error }
    }

    func matched(_ record: CaptureRecord, metadata: MatchMetadata) throws {
        guard !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.coderInvalidValue)
        }
        record.title = metadata.title
        record.artist = metadata.artist
        record.appleMusicID = metadata.appleMusicID
        record.shazamURL = metadata.shazamURL
        record.appleMusicURL = metadata.appleMusicURL
        record.isrc = metadata.isrc?.replacingOccurrences(of: "-", with: "").uppercased()
        record.state = .matched
        record.notificationEligible = true
        record.lastError = nil
        record.nextAttemptAt = nil
        record.deliveryBlocked = false
        try save()
    }

    func deliveryStarted(_ record: CaptureRecord) throws {
        // A new request may reach Spotify. A previous pre-mutation failure no
        // longer proves the current outcome, even if this process is terminated.
        if record.spotifyOutcome == .notAdded { record.spotifyOutcome = nil }
        record.deliveryStartedAt = Date()
        try save()
    }

    /// Seconds a numeric or HTTP-date Retry-After asks for; nil when absent or unusable.
    private static func retryAfterDelay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return format.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    func deliveryFinished(_ record: CaptureRecord, status: Int, data: Data, retryAfter: String? = nil,
                          now: Date = Date(), retryDelay: TimeInterval = 30) throws {
        guard record.state == .matched else { return }
        struct Receipt: Decodable {
            let ok: Bool
            let capture_id: UUID?
            let isrc: String?
            let reason: String?
        }
        struct OutcomeReceipt: Decodable {
            let spotify_outcome: String?
        }
        let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        // Decode the additive field separately: malformed optional data must not
        // invalidate the service's established successful acknowledgement.
        let outcomeValue = try? JSONDecoder().decode(OutcomeReceipt.self, from: data).spotify_outcome
        let trustedReceipt = ((200..<300).contains(status) || (400..<600).contains(status)) &&
            status != 401 && status != 403 && receipt?.capture_id == record.id
        let outcome = trustedReceipt ? outcomeValue.flatMap(SpotifyOutcome.init(rawValue:)) : nil
        // Explicit unknown means the service crossed its durable attempt marker.
        // Neither that fact nor an acknowledged addition can later be downgraded.
        if record.spotifyOutcome != .added {
            if outcome == .added {
                record.spotifyOutcome = .added
            } else if record.spotifyOutcome != .unknown {
                record.spotifyOutcome = outcome == .notAdded && receipt?.ok != false ? nil : outcome
            }
        }
        if (200..<300).contains(status), receipt?.ok == true,
           receipt?.capture_id == record.id, let isrc = receipt?.isrc,
           !isrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.isrc == nil || record.isrc == isrc.replacingOccurrences(of: "-", with: "").uppercased() {
            record.state = .delivered
            record.spotifyOutcome = .added
            record.lastError = nil
            record.nextAttemptAt = nil
            record.deliveryBlocked = false
            record.deliveryStatus = nil
            record.failedDeliveries = 0
            record.deliveryStartedAt = nil
        } else {
            record.deliveryBlocked = status == 401 || status == 403
            record.deliveryStartedAt = nil
            let serverDelay = Self.retryAfterDelay(retryAfter, now: now)
            if record.deliveryBlocked {
                record.deliveryStatus = nil
                record.lastError = "Connection needs attention in Settings."
                record.nextAttemptAt = nil
            } else if trustedReceipt, receipt?.reason == "no_match" {
                // Definitive until Spotify's catalog changes: check once a day.
                record.deliveryStatus = .notOnSpotify
                record.lastError = "Spotify has no exact match for this recording yet."
                record.nextAttemptAt = now.addingTimeInterval(max(86400, serverDelay ?? 0))
            } else if status == 503 || status == 429, let serverDelay {
                record.deliveryStatus = .spotifyBusy
                record.lastError = "Spotify is limiting requests from Music Sync."
                record.nextAttemptAt = now.addingTimeInterval(max(retryDelay, serverDelay))
            } else {
                // Without a server deadline, back off exponentially up to an hour.
                let backoff = min(3600, retryDelay * pow(2, Double(min(record.failedDeliveries, 16))))
                record.deliveryStatus = .retrying
                record.lastError = "Delivery not confirmed. Saved for another attempt."
                record.nextAttemptAt = now.addingTimeInterval(max(backoff, serverDelay ?? 0))
            }
            record.failedDeliveries += 1
        }
        try save()
        if record.state == .delivered {
            try? FileManager.default.removeItem(at: signatureURL(record))
        }
    }
}

extension CaptureRecord {
    /// The capture list's status for this capture: what delivery is actually doing, never an open-ended spinner.
    func deliveryLabel(isUploading: Bool, isOnline: Bool, connectionIssue: String?, now: Date = Date()) -> String {
        switch state {
        case .pending: return "Saved for identification"
        case .delivered: return "Added to Spotify"
        case .unmatched: return "Not identified"
        case .matched:
            if !isOnline { return "Waiting for internet" }
            if deliveryBlocked || connectionIssue != nil { return "Needs reconnect" }
            if isUploading { return "Sending to Spotify…" }
            guard let next = nextAttemptAt else { return "Queued for Spotify" }
            switch deliveryStatus {
            case .notOnSpotify: return "Not on Spotify yet, checking daily"
            case .spotifyBusy: return "Spotify busy, retrying at " + Self.retryTime(next, now: now)
            case .retrying, nil: return "Retrying at " + Self.retryTime(next, now: now)
            }
        }
    }

    static func retryTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
