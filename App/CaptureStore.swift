import Foundation
import ShazamKit
import SwiftData

enum CaptureState: String, Codable {
    case pending, matched, delivered, unmatched
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
        try FileManager.default.createDirectory(at: signatureDirectory, withIntermediateDirectories: true)
        container = try ModelContainer(for: CaptureRecord.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("queue.sqlite")))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func records() throws -> [CaptureRecord] {
        try context.fetch(FetchDescriptor<CaptureRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func capture(signature: SHSignature) throws -> CaptureRecord {
        let record = CaptureRecord()
        let url = signatureDirectory.appendingPathComponent(record.id.uuidString + ".shazamsignature")
        try signature.dataRepresentation.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return record
    }

    func signature(for record: CaptureRecord) throws -> Data {
        try Data(contentsOf: signatureDirectory.appendingPathComponent(record.id.uuidString + ".shazamsignature"))
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

    func deliveryFinished(_ record: CaptureRecord, status: Int, data: Data, retryAfter: String? = nil,
                          now: Date = Date(), retryDelay: TimeInterval = 30) throws {
        guard record.state == .matched else { return }
        struct Receipt: Decodable {
            let ok: Bool
            let capture_id: UUID?
            let isrc: String?
        }
        let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        if (200..<300).contains(status), receipt?.ok == true,
           receipt?.capture_id == record.id, let isrc = receipt?.isrc,
           !isrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.isrc == nil || record.isrc == isrc.replacingOccurrences(of: "-", with: "").uppercased() {
            record.state = .delivered
            record.lastError = nil
            record.nextAttemptAt = nil
            record.deliveryBlocked = false
        } else {
            record.deliveryBlocked = status == 401 || status == 403
            record.lastError = record.deliveryBlocked
                ? "Connection needs attention in Settings."
                : "Delivery not confirmed. Saved for another attempt."
            record.nextAttemptAt = now.addingTimeInterval(retryDelay)
            if let retryAfter {
                if let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 {
                    record.nextAttemptAt = now.addingTimeInterval(max(retryDelay, seconds))
                } else {
                    let format = DateFormatter()
                    format.locale = Locale(identifier: "en_US_POSIX")
                    format.timeZone = TimeZone(secondsFromGMT: 0)
                    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = format.date(from: retryAfter) {
                        record.nextAttemptAt = max(now.addingTimeInterval(retryDelay), date)
                    }
                }
            }
            if record.deliveryBlocked { record.nextAttemptAt = nil }
        }
        try save()
        if record.state == .delivered {
            try? FileManager.default.removeItem(at: signatureDirectory.appendingPathComponent(record.id.uuidString + ".shazamsignature"))
        }
    }
}
