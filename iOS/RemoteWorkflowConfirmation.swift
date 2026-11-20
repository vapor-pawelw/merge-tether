import SwiftUI
import MergeTetherRemote

struct RemoteWorkflowConfirmation: Identifiable {
    let id = UUID()
    let card: RemoteCard
    let action: RemoteAction
    let preferenceID: String

    var title: Text {
        if let label = action.label { Text(verbatim: label) }
        else if let cta = card.primaryCTA, cta.actionID == action.id { Text(verbatim: cta.title) }
        else { Text(action.kind.title) }
    }

    var message: Text {
        if let message = action.confirmationText { return Text(verbatim: message) }
        switch action.kind {
        case .finishCommentReview:
            return Text(.ActionEffects.finishCommentReview) + Text("\n\n") + Text(.ActionEffects.thenMayRequestReReview)
                + Text("\n") + Text(.ActionEffects.thenResumesAutomation)
        case .publish:
            return Text(.ActionEffects.publishComments) + Text("\n\n") + Text(.ActionEffects.thenResumesAutomation)
        case .markReady:
            return Text(.ActionEffects.markReady) + Text("\n\n") + Text(.ActionEffects.thenResumesAutomation)
        case .prepare: return Text(.ActionEffects.handleFeedback)
        case .handoff: return Text(.ActionEffects.confirmPipelineHandoff)
        case .retryJob: return Text(.ActionEffects.retryRun)
        case .runReview: return Text(.Remote.remoteRunReviewHelp)
        case .reReview: return Text(.Remote.remoteReReviewConfirmation)
        case .verify where action.isAuthorFeedbackVerification:
            return Text(.ActionEffects.verifyFeedback) + Text("\n\n") + Text(.ActionEffects.thenMayStartAgent)
        case .verify where action.id == "verifyDrafts": return Text(.ActionEffects.retryDraftVerification)
        case .verify:
            return Text(.ActionEffects.verifyReReview) + Text("\n\n") + Text(.ActionEffects.thenMayRequestReReview)
        case .merge, .enqueueMerge: return Text(.ActionEffects.merge)
        case .checkThreads: return Text(.ActionEffects.resolveThreads)
        case .resolveThreads: return Text(.MergeActions.mergeActionsResolveHelp)
        default: return Text(.Remote.remoteConfirmHelp)
        }
    }
}

struct RemoteWorkflowConfirmationSheet: View {
    let confirmation: RemoteWorkflowConfirmation
    let onAccept: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            confirmation.title.font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ScrollView {
                confirmation.message.font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { remember.toggle() } label: {
                Label(.RemoteDetail.remoteDetailDontAskAgain, systemImage: remember ? "checkmark.square.fill" : "square")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(remember ? .isSelected : [])
            .accessibilityIdentifier("remote.confirmation.remember")
            ViewThatFits {
                HStack { cancel; accept }
                VStack { accept; cancel }
            }
        }
        .padding(24)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var cancel: some View {
        Button(.Remote.remoteCancel, role: .cancel) { dismiss() }
            .buttonStyle(.bordered).controlSize(.large)
    }

    private var accept: some View {
        Button { onAccept(remember) } label: {
            confirmation.title.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .accessibilityIdentifier("remote.confirmation.accept")
    }
}
