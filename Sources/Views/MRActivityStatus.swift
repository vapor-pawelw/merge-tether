import SwiftUI

/// Tick only the activity label, leaving the board and its polling state untouched.
struct MRActivityStatus: View {
    let status: String
    let startedAt: Date?
    var effect: MRActionEffect? = nil
    var assistant: AutomationAssistant? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                if let effect { MRActionEffectIcon(effect: effect, assistant: assistant) }
                if let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(.AutomationProgress.progressTimedStatus(status,
                            MRActivity.elapsed(since: startedAt, now: context.date)))
                            .monospacedDigit()
                    }
                } else {
                    Text(verbatim: status)
                }
            }
            if let detail {
                Text(verbatim: detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MRMergeStageBanner: View {
    let stage: MRCardPresentation.MergeStage
    var startedAt: Date? = nil

    private var tint: Color {
        switch stage {
        case .merging: .green
        case .inTrain: .indigo
        case .queued: .blue
        }
    }

    var body: some View {
        Group {
            if stage == .merging {
                MRActivityStatus(status: String(localized: stage.title), startedAt: startedAt)
            } else {
                Label { Text(stage.title) } icon: {
                    Image(systemName: stage == .inTrain ? "tram.fill" : "clock")
                        .foregroundStyle(tint)
                }
            }
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}
