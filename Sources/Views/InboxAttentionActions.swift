import SwiftUI

struct InboxAttentionActions: View {
    let item: MergeRequestAttentionMonitor.Item
    let feedbackAction: TodoAutomationService.ActionState?
    let onFeedback: () -> Void
    let onPipeline: () -> Void
    let onMerge: () -> Void
    @State private var confirmsPipeline = false

    private var hasContent: Bool {
        (item.needsConfirmation && (item.hasConflict || item.failedPipeline || item.needsChanges
            || item.needsDiscussion || !item.feedback.isEmpty))
            || feedbackAction == .running || feedbackAction == .ready(.assistant) || feedbackAction == .failed
            || item.needsPipelineHandoff || item.needsMerge
    }

    var body: some View {
        // Nothing to show adds no container, so the parent stack leaves no gap.
        if hasContent { content }
    }

    private var content: some View {
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
                Button(action: onFeedback) { MRActionLabel(title: .Menu.menuTodoAutomationPrepareFollowUp, cta: .handleFeedback) }
                    .buttonStyle(.bordered)
                    .mrActionHelp(.handleFeedback)
            }
            if item.needsPipelineHandoff {
                Button { confirmsPipeline = true } label: {
                    MRActionLabel(title: .Menu.menuWorkflowHandoffButton, cta: .confirmPipelineHandoff)
                }
                    .buttonStyle(.borderedProminent)
                    .mrActionHelp(.confirmPipelineHandoff)
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
    }
}
