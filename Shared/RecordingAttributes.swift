#if os(iOS)
import ActivityKit
#endif
import Foundation

struct RecordingContentState: Codable, Hashable {
    let startedAt: Date
    let deadline: Date
    // Set once recording ends; the activity shows it briefly before dismissing.
    var outcome: RecordingOutcome? = nil
}

enum RecordingOutcome: Codable, Hashable, CustomStringConvertible {
    case recognized(title: String, artist: String)
    case noMatch
    case savedForLater

    var description: String {
        switch self {
        case .recognized(let title, let artist): return "recognized \(title) by \(artist)"
        case .noMatch: return "no match"
        case .savedForLater: return "saved for later"
        }
    }
}

#if os(iOS)
struct RecordingAttributes: ActivityAttributes {
    typealias ContentState = RecordingContentState
    typealias Outcome = RecordingOutcome
    let recordingID: UUID
}
#else
struct RecordingAttributes {
    typealias ContentState = RecordingContentState
    typealias Outcome = RecordingOutcome
    let recordingID: UUID
}
#endif
