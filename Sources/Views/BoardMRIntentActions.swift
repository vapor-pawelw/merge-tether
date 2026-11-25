import SwiftUI

/// The complete action list lives in Details; the board shows only its next action.
struct BoardMRIntentActions: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var excludingIntentID: UUID? = nil
    @Environment(\.openSettings) private var openSettings

    private var needsCLI: Bool {
        row.attentionIntents.contains(where: { $0.state != .completed && $0.kind != .refresh })
            && !monitor.selectedAssistantReady
    }

    var body: some View {
        let intents = Self.visibleIntents(row.attentionIntents, excluding: excludingIntentID)
        // Nothing to show adds no container, so the parent stack leaves no gap.
        if !intents.isEmpty || needsCLI { content(intents) }
    }

    private func content(_ intents: [MRTodoIntent]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(intents) { intent in
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
                            MRIntentActionButton(intent: intent,
                                title: intent.state == .failed ? .Board.boardIntentRetry : Self.action(intent.kind),
                                monitor: monitor)
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
                    Button {
                        SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() },
                            onConfigured: { Task { await monitor.refreshFromGitLab(for: row.id) } })
                    } label: { Text(.Settings.settingsAssistantResumeAction) }
                        .buttonStyle(.link)
                }
            }
        }
        .controlSize(.small)
    }

    /// One row per kind: queued duplicates read as the same task twice. A running one wins,
    /// then a failure that needs a retry, then the oldest pending one.
    static func visibleIntents(_ intents: [MRTodoIntent], excluding intentID: UUID? = nil) -> [MRTodoIntent] {
        let open = intents.filter { $0.state != .completed }
        func rank(_ intent: MRTodoIntent) -> Int {
            switch intent.state { case .running, .verifying: 0; case .failed: 1; default: 2 }
        }
        var chosen: [MRTodoIntent.Kind: MRTodoIntent] = [:]
        for intent in open where chosen[intent.kind].map({ rank(intent) < rank($0) }) ?? true {
            chosen[intent.kind] = intent
        }
        return open.filter { chosen[$0.kind]?.id == $0.id && $0.id != intentID }
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

struct MRIntentActionButton: View {
    let intent: MRTodoIntent
    let title: LocalizedStringResource
    let monitor: TodoMonitorService
    @State private var starting = false

    var body: some View {
        let cta = MRActionCTA(intent: intent.kind)
        Button {
            guard !starting else { return }
            starting = true
            Task {
                defer { starting = false }
                await runConfirmedIntent(intent, monitor: monitor, title: title)
            }
        } label: {
            if let cta { MRActionLabel(title: title, cta: cta) }
            else { Text(title) }
        }
        .disabled(starting)
        .mrActionHelp(cta)
    }
}
