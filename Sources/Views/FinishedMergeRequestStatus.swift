import SwiftUI

struct FinishedMergeRequestBadge: View {
    let state: MergeRequestFinishedState

    var body: some View {
        Text(state.badge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state == .merged ? Color.green : Color.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.secondary.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

struct FinishedMergeRequestStatus: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService

    var body: some View {
        if let state = MergeRequestFinishedState(item.mergeRequest) {
            HStack(spacing: 8) {
                Text(state.status).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if monitor.canAcknowledgeFinishedMergeRequest(item) {
                    Button { monitor.acknowledgeFinishedMergeRequest(item) } label: { Text(.MRLifecycle.seen) }
                        .buttonStyle(.bordered)
                        .help(Text(.MRLifecycle.seenHelp))
                }
            }
            .font(.caption)
        }
    }
}
