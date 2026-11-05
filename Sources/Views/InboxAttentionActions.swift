import SwiftUI

struct InboxAttentionActions: View {
    let item: MergeRequestAttentionMonitor.Item
    let feedbackAction: TodoAutomationService.ActionState?
    let onFeedback: () -> Void
    let onPipeline: () -> Void
    let onMerge: () -> Void
    @State private var confirmsPipeline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if item.needsConfirmation {
                if item.hasConflict { Text(.Menu.menuAttentionConflict) }
                if item.failedPipeline { Text(.Menu.menuAttentionPipeline) }
                if item.needsChanges { Text(.Menu.menuAttentionChanges) }
                if item.needsDiscussion || !item.feedback.isEmpty { Text(.Menu.menuAttentionDiscussions) }
            }
            if feedbackAction == .running {
                HStack { ProgressView().controlSize(.small); Text(.Menu.menuTodoAutomationRunning) }
            } else if feedbackAction == .ready(.assistant) || feedbackAction == .failed {
                if feedbackAction == .failed { Text(.Menu.menuTodoAutomationFailed).foregroundStyle(.orange) }
                Button(action: onFeedback) { Text(.Menu.menuTodoAutomationPrepareFollowUp) }
                    .buttonStyle(.bordered)
            }
            if item.needsPipelineHandoff {
                Button { confirmsPipeline = true } label: { Text(.Menu.menuWorkflowHandoffButton) }
                    .buttonStyle(.borderedProminent)
                    .confirmationDialog(Text(.Menu.menuWorkflowHandoffTitle), isPresented: $confirmsPipeline, titleVisibility: .visible) {
                        Button(action: onPipeline) { Text(.Menu.menuWorkflowHandoffConfirm) }
                    } message: { Text(.Menu.menuWorkflowHandoffExplanation) }
            }
            if item.needsMerge {
                Button(action: onMerge) { Text(.Menu.menuInboxOpenToMerge) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
