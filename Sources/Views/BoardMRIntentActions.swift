import SwiftUI

/// The complete action list lives in Details; the board shows only its next action.
struct BoardMRIntentActions: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    @State private var starting: Set<UUID> = []
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(row.intents.filter { $0.state != .completed }, id: \.id) { intent in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Label { Text(Self.title(intent.kind)) } icon: { Image(systemName: symbol(intent.kind)) }
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if intent.state == .running {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                starting.insert(intent.id)
                                Task {
                                    defer { starting.remove(intent.id) }
                                    await monitor.runMRTodoIntent(id: intent.id)
                                }
                            } label: { Text(intent.state == .failed ? .Board.boardIntentRetry : Self.action(intent.kind)) }
                            .disabled(starting.contains(intent.id) || !canRun(intent.kind))
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
            if row.intents.contains(where: { $0.state != .completed && $0.kind != .refresh }),
               !monitor.availableAssistants.contains(monitor.settings.automation.assistant) {
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
