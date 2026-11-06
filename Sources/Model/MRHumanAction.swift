import Foundation

/// A concrete reason for a human action, shared by the MR card and its detail view.
@MainActor
struct MRHumanAction {
    enum Kind: Equatable { case blockedRun, interruptedRun, publication, uncheckedDrafts, verificationFailure, setupAssistant, reviewDecision, approval, pipelineHandoff, merge, feedback, intent }
    enum Action: Equatable { case reviewRun, reviewDrafts, verifyFeedback, setupAssistant, reviewDecision, reviewApproval, reviewHandoff, reviewMerge, handleFeedback, retryIntent, reviewFeedback, reviewIssue }
    let kind: Kind
    let action: Action
    let message: LocalizedStringResource
    let detail: String?
    var actionLabel: LocalizedStringResource {
        switch action {
        case .reviewRun: .MRHumanAction.mrHumanActionActionReviewRun
        case .reviewDrafts: .MRHumanAction.mrHumanActionActionReviewDrafts
        case .verifyFeedback: .MRHumanAction.mrHumanActionActionVerifyFeedback
        case .setupAssistant: .MRHumanAction.mrHumanActionActionSetupAssistant
        case .reviewDecision: .MRHumanAction.mrHumanActionActionReviewDecision
        case .reviewApproval: .MRHumanAction.mrHumanActionActionReviewApproval
        case .reviewHandoff: .MRHumanAction.mrHumanActionActionReviewHandoff
        case .reviewMerge: .MRHumanAction.mrHumanActionActionReviewMerge
        case .handleFeedback: .MRHumanAction.mrHumanActionActionHandleFeedback
        case .retryIntent: .MRHumanAction.mrHumanActionActionRetryIntent
        case .reviewFeedback: .MRHumanAction.mrHumanActionActionReviewFeedback
        case .reviewIssue: .MRHumanAction.mrHumanActionActionReviewIssue
        }
    }

    init?(row: MergeRequestBoardSnapshot.Row, assistantReady: Bool,
          confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
          automaticallyPublishedDraftIDs: Set<Int> = []) {
        let item = row.item
        guard row.needsAttention, row.latestJob?.execution?.state.isActive != true,
              item.authorFeedbackStatus?.phase != .checking, item.reReviewReadiness != .checking,
              confirmationState != .publishing, confirmationState != .approving else { return nil }

        let stoppedRun = row.latestJob?.execution.flatMap {
            MergeRequestBoardSnapshot.Row.jobNeedsAttention($0.state) ? $0 : nil
        }
        let previousHead = row.latestJob?.expectedHeadSHA
        let currentHead = item.mergeRequest?.sha
        // A push-enabled run may itself have advanced the starting head before
        // stopping; that lease is not evidence that its result is obsolete.
        let mayHavePushed = row.latestJob?.allowsPush == true || row.latestJob?.followUpPushAllowed == true
        let stoppedOnOlderHead = !mayHavePushed && previousHead != nil && currentHead != nil && previousHead != currentHead
        if let execution = stoppedRun, !stoppedOnOlderHead {
            let interrupted = execution.state == .interrupted || execution.state == .cancelled
            self.init(kind: interrupted ? .interruptedRun : .blockedRun, action: .reviewRun,
                      message: interrupted ? .MRHumanAction.mrHumanActionInterruptedRun : .MRHumanAction.mrHumanActionBlockedRun,
                      detail: execution.attentionExplanation)
            return
        }

        let knownAutomatic = automaticallyPublishedDraftIDs.intersection(Set(item.drafts.compactMap(\.id))).count
        let count = max(item.draftCount, item.drafts.count, item.authorFeedbackStatus?.pendingDraftCount ?? 0) - knownAutomatic
        let unchecked = item.awaitingRemoteVerification || item.requiresDiscussionRecheck || confirmationState == .changed
        if count > 0 {
            let message: LocalizedStringResource
            if unchecked {
                message = count == 1 ? .MRHumanAction.mrHumanActionUncheckedDraftSingle : .MRHumanAction.mrHumanActionUncheckedDrafts(count)
            } else {
                message = count == 1 ? .MRHumanAction.mrHumanActionPublicationSingle : .MRHumanAction.mrHumanActionPublication(count)
            }
            self.init(kind: unchecked ? .uncheckedDrafts : .publication, action: .reviewDrafts, message: message)
            return
        }
        let intent = row.intents.first { $0.state == .failed } ?? row.intents.first { $0.state == .pending }
        let needsAssistant = intent.map { $0.kind != .refresh } == true || !item.feedback.isEmpty
            || item.needsDiscussion || item.needsChanges || item.failedPipeline || item.hasConflict
            || item.authorFeedbackStatus?.needsAttention == true || item.autoApproveReady
        if item.canConfirmReReview {
            self.init(kind: .reviewDecision, action: .reviewDecision, message: Self.reviewDecisionMessage(item),
                      detail: Self.feedbackDetail(item))
        } else if item.canApprove {
            self.init(kind: .approval, action: .reviewApproval, message: .MRHumanAction.mrHumanActionApproval)
        } else if item.needsPipelineHandoff {
            self.init(kind: .pipelineHandoff, action: .reviewHandoff, message: .MRHumanAction.mrHumanActionPipelineHandoff)
        } else if item.needsMerge {
            self.init(kind: .merge, action: .reviewMerge, message: .MRHumanAction.mrHumanActionMerge)
        } else if item.authorFeedbackStatus?.phase == .failed {
            self.init(kind: .verificationFailure, action: assistantReady ? .verifyFeedback : .setupAssistant,
                      message: .MRHumanAction.mrHumanActionVerificationFailure)
        } else if !assistantReady && needsAssistant {
            self.init(kind: .setupAssistant, action: .setupAssistant, message: .MRHumanAction.mrHumanActionSetupAssistant)
        } else if item.authorFeedbackStatus?.needsAttention == true {
            self.init(kind: .feedback, action: .handleFeedback, message: .MRHumanAction.mrHumanActionFeedback,
                      detail: Self.feedbackDetail(item))
        } else if let intent {
            self.init(kind: .intent, action: .retryIntent, message: Self.intentMessage(intent))
        } else if item.hasConflict {
            self.init(kind: .intent, action: .reviewIssue, message: .MRHumanAction.mrHumanActionConflictIntent)
        } else if item.failedPipeline {
            self.init(kind: .intent, action: .reviewIssue, message: .MRHumanAction.mrHumanActionPipelineIntent)
        } else if item.reReviewReadiness != nil || item.reReviewUnconfirmed {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: Self.reviewDecisionMessage(item),
                      detail: Self.feedbackDetail(item))
        } else if item.needsChanges || !item.feedback.isEmpty {
            self.init(kind: .feedback, action: .handleFeedback, message: .MRHumanAction.mrHumanActionFeedback,
                      detail: Self.feedbackDetail(item))
        } else if item.needsDiscussion {
            self.init(kind: .feedback, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionDiscussion)
        } else if unchecked {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionCurrentCheckMissing)
        } else if confirmationState == .failed {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionLastActionFailed)
        } else if stoppedRun != nil {
            self.init(kind: .interruptedRun, action: .reviewRun, message: .MRHumanAction.mrHumanActionPreviousHeadRun)
        } else { return nil }
    }

    private init(kind: Kind, action: Action, message: LocalizedStringResource, detail: String? = nil) {
        self.kind = kind; self.action = action; self.message = message; self.detail = detail
    }

    private static func feedbackDetail(_ item: MergeRequestAttentionMonitor.Item) -> String? {
        let reason = item.authorFeedbackStatus?.findings.first { finding in
            [.needsChanges, .needsVerification].contains(finding.state)
                || item.authorFeedbackStatus?.replyNoteIDs.contains(finding.id) == true
        }?.reason
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reason }
        switch item.reReviewReadiness {
        case .blocked(let blockers), .uncertain(let blockers): return blockers.first?.reason
        default: return nil
        }
    }

    private static func reviewDecisionMessage(_ item: MergeRequestAttentionMonitor.Item) -> LocalizedStringResource {
        switch item.reReviewReadiness {
        case .failed, .unavailable: .MRHumanAction.mrHumanActionVerificationFailure
        case .blocked, .uncertain: .MRHumanAction.mrHumanActionFeedback
        default: .MRHumanAction.mrHumanActionReviewDecision
        }
    }

    private static func intentMessage(_ intent: MRTodoIntent) -> LocalizedStringResource {
        let failed = intent.state == .failed
        switch intent.kind {
        case .review: return failed ? .MRHumanAction.mrHumanActionReviewFailed : .MRHumanAction.mrHumanActionReviewIntent
        case .followUp: return failed ? .MRHumanAction.mrHumanActionFollowUpFailed : .MRHumanAction.mrHumanActionFollowUpIntent
        case .pipeline: return failed ? .MRHumanAction.mrHumanActionPipelineFailed : .MRHumanAction.mrHumanActionPipelineIntent
        case .conflict: return failed ? .MRHumanAction.mrHumanActionConflictFailed : .MRHumanAction.mrHumanActionConflictIntent
        case .refresh: return failed ? .MRHumanAction.mrHumanActionRefreshFailed : .MRHumanAction.mrHumanActionRefreshIntent
        }
    }
}
