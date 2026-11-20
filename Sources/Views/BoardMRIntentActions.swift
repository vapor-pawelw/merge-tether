import SwiftUI

/// The complete action list lives in Details; the board shows only its next action.
struct BoardMRIntentActions: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    @State private var starting: Set<UUID> = []
    @Environment(\.openSettings) private var openSettings

    private var needsCLI: Bool {
        row.attentionIntents.contains(where: { $0.state != .completed && $0.kind != .refresh })
            && !monitor.availableAssistants.contains(monitor.settings.automation.assistant)
    }

    var body: some View {
        // Nothing to show adds no container, so the parent stack leaves no gap.
        if !Self.visibleIntents(row.attentionIntents).isEmpty || needsCLI { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.visibleIntents(row.attentionIntents), id: \.id) { intent in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label {
                            if intent.isAwaitingFollowUpVerification {
                                Text(.AutomationProgress.progressFeedbackCheck)
                            } else if intent.state == .running, MRActionCTA(intent: intent.kind) != nil {
                                Text(verbatim: MRActivity.agentStatus(Self.title(intent.kind),
                                    assistant: row.latestJob.flatMap { $0.id == intent.jobID ? $0.key.assistant : nil }
                                        ?? monitor.settings.automation.assistant))
                            } else { Text(Self.title(intent.kind)) }
                        } icon: {
                            if intent.isAwaitingFollowUpVerification {
                                Image(systemName: "checkmark.bubble")
                            } else {
                                Image(systemName: intent.state == .running
                                    ? MRActionCTA(intent: intent.kind)?.symbol ?? symbol(intent.kind) : symbol(intent.kind))
                            }
                        }
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if intent.state == .running || intent.state == .verifying {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                let title = intent.state == .failed ? LocalizedStringResource.Board.boardIntentRetry : Self.action(intent.kind)
                                starting.insert(intent.id)
                                Task {
                                    defer { starting.remove(intent.id) }
                                    await runConfirmedIntent(intent, monitor: monitor, title: title)
                                }
                            } label: {
                                let title = intent.state == .failed ? LocalizedStringResource.Board.boardIntentRetry : Self.action(intent.kind)
                                if let cta = MRActionCTA(intent: intent.kind) { MRActionLabel(title: title, cta: cta) }
                                else { Text(title) }
                            }
                            .disabled(starting.contains(intent.id) || !canRun(intent.kind))
                            .mrActionHelp(MRActionCTA(intent: intent.kind))
                        }
                    }
                    if let error = intent.error {
                        DisclosureGroup {
                            Text(verbatim: error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } label: {
                            BoardStatusChip(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle", tint: .orange)
                        }
                        .font(.caption)
                    }
                }
            }
            if needsCLI {
                HStack {
                    BoardStatusChip(title: .Board.boardCompactCliRequired, symbol: "terminal", tint: .orange)
                        .help(Text(.Board.boardIntentCliRequired))
                    Button { openSettings() } label: { Text(.Board.boardCompactSetupCli) }
                        .buttonStyle(.link)
                }
            }
        }
        .controlSize(.small)
    }

    /// One row per kind: queued duplicates read as the same task twice. A running one wins,
    /// then a failure that needs a retry, then the oldest pending one.
    static func visibleIntents(_ intents: [MRTodoIntent]) -> [MRTodoIntent] {
        let open = intents.filter { $0.state != .completed }
        func rank(_ intent: MRTodoIntent) -> Int {
            switch intent.state { case .running, .verifying: 0; case .failed: 1; default: 2 }
        }
        var chosen: [MRTodoIntent.Kind: MRTodoIntent] = [:]
        for intent in open where chosen[intent.kind].map({ rank(intent) < rank($0) }) ?? true {
            chosen[intent.kind] = intent
        }
        return open.filter { chosen[$0.kind]?.id == $0.id }
    }

    private func canRun(_ kind: MRTodoIntent.Kind) -> Bool {
        kind == .refresh || monitor.availableAssistants.contains(monitor.settings.automation.assistant)
    }

    static func title(_ kind: MRTodoIntent.Kind) -> LocalizedStringResource {
        switch kind {
        case .review: .Board.boardIntentReview
        case .followUp: .Board.boardIntentFollowUp
        case .pipeline: .Board.boardIntentPipeline
        case .conflict: .Board.boardIntentConflict
        case .refresh: .Board.boardIntentRefresh
        }
    }

    static func action(_ kind: MRTodoIntent.Kind) -> LocalizedStringResource {
        switch kind {
        case .review: .CommandCenter.commandCenterReviewRun
        case .followUp: .Board.boardIntentHandleFeedback
        case .pipeline: .Board.boardIntentHandlePipeline
        case .conflict: .Board.boardIntentHandleConflict
        case .refresh: .CommandCenter.commandCenterRefresh
        }
    }

    private func symbol(_ kind: MRTodoIntent.Kind) -> String {
        switch kind {
        case .review: "text.magnifyingglass"
        case .followUp: "text.bubble"
        case .pipeline: "gearshape.2"
        case .conflict: "arrow.triangle.branch"
        case .refresh: "arrow.clockwise"
        }
    }
}
