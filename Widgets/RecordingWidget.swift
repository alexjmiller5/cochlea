import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecordingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            Group {
                if let outcome = context.state.outcome {
                    HStack(spacing: 16) {
                        OutcomeIcon(outcome: outcome).font(.title)
                        OutcomeText(outcome: outcome)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(context.isStale ? "Capture ended" : "Listening for a song")
                                .font(.headline)
                            if !context.isStale {
                                ProgressView(timerInterval: context.state.startedAt...context.state.deadline, countsDown: false)
                                    .tint(.purple)
                                    .labelsHidden()
                                    .accessibilityLabel("Recording progress")
                            }
                        }
                        if !context.isStale { cancelButton(context.attributes.recordingID) }
                    }
                }
            }
            // System colors: the iOS 27 Lock Screen material is light or dark with the
            // appearance, so forced white text disappears on the light one.
            .padding()
        } dynamicIsland: { context in
            let outcome = context.state.outcome
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if outcome == nil {
                        Label(context.isStale ? "Capture ended" : "Listening", systemImage: "waveform")
                            .font(.headline)
                            .foregroundStyle(.purple)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if outcome == nil, !context.isStale { cancelButton(context.attributes.recordingID) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let outcome {
                        // One row under the camera keeps the icon level with the song.
                        HStack(spacing: 12) {
                            OutcomeIcon(outcome: outcome).font(.title)
                            OutcomeText(outcome: outcome)
                        }
                        .padding(.horizontal, 8)
                    } else if !context.isStale {
                        ProgressView(timerInterval: context.state.startedAt...context.state.deadline, countsDown: false)
                            .tint(.purple)
                            .accessibilityLabel("Recording progress")
                    }
                }
            } compactLeading: {
                if let outcome { OutcomeIcon(outcome: outcome) }
                else { Image(systemName: "waveform").foregroundStyle(.purple) }
            } compactTrailing: {
                if let outcome {
                    Text(outcome.shortLabel)
                        .lineLimit(1)
                        .frame(maxWidth: 72)
                        .foregroundStyle(outcome.tint)
                } else {
                    Text(timerInterval: context.state.startedAt...context.state.deadline, countsDown: true)
                        .monospacedDigit()
                        .frame(width: 36)
                        .accessibilityLabel("Recording time remaining")
                }
            } minimal: {
                if let outcome { OutcomeIcon(outcome: outcome) }
                else { Image(systemName: "waveform").foregroundStyle(.purple) }
            }
            .keylineTint(outcome?.tint ?? .purple)
        }
    }

    private func cancelButton(_ id: UUID) -> some View {
        Button(intent: CancelCaptureIntent(recordingID: id)) {
            Label("Cancel", systemImage: "xmark")
                .font(.subheadline.bold())
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.purple)
        .accessibilityLabel("Cancel and discard capture")
    }
}

private struct OutcomeIcon: View {
    let outcome: RecordingAttributes.Outcome

    var body: some View {
        Image(systemName: outcome.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(outcome.tint)
            .accessibilityHidden(true)
    }
}

private struct OutcomeText: View {
    let outcome: RecordingAttributes.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(outcome.title).font(.headline).lineLimit(1)
            Text(outcome.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension RecordingAttributes.Outcome {
    var symbol: String {
        switch self {
        case .recognized: return "checkmark.circle.fill"
        case .noMatch: return "questionmark.circle.fill"
        case .savedForLater: return "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .recognized: return .green
        case .noMatch: return .orange
        case .savedForLater: return .purple
        }
    }

    var title: String {
        switch self {
        case .recognized(let title, _): return title
        case .noMatch: return "No match"
        case .savedForLater: return "Saved for later"
        }
    }

    var subtitle: String {
        switch self {
        case .recognized(_, let artist): return artist
        case .noMatch: return "Saved to try again"
        case .savedForLater: return "Identifies when you're online"
        }
    }

    var shortLabel: String {
        switch self {
        case .recognized(let title, _): return title
        case .noMatch: return "No match"
        case .savedForLater: return "Saved"
        }
    }
}

#Preview("Lock Screen", as: .content, using: RecordingAttributes(recordingID: UUID())) {
    RecordingWidget()
} contentStates: {
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now.addingTimeInterval(15))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .recognized(title: "Flaming Hot Cheetos", artist: "Clairo"))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .noMatch)
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .savedForLater)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: RecordingAttributes(recordingID: UUID())) {
    RecordingWidget()
} contentStates: {
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now.addingTimeInterval(15))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .recognized(title: "Flaming Hot Cheetos", artist: "Clairo"))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .savedForLater)
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: RecordingAttributes(recordingID: UUID())) {
    RecordingWidget()
} contentStates: {
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now.addingTimeInterval(15))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .recognized(title: "Flaming Hot Cheetos", artist: "Clairo"))
    RecordingAttributes.ContentState(startedAt: .now, deadline: .now, outcome: .noMatch)
}
