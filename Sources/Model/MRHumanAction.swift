import Foundation

@MainActor
struct PreparedReplyContext {
    let draftID: Int
    let quote: String
    let discussionURL: URL?
    let reason: String
    let summary: String?

    static func rejected(in item: MergeRequestAttentionMonitor.Item) -> [Self] {
        item.rejectedDrafts.compactMap { rejection in
            guard rejection.state != .valid,
                  let draft = item.drafts.first(where: { $0.id == rejection.draftID }),
                  let quote = draft.note, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
            let noteID = rejection.discussionRootNoteID.flatMap { $0 > 0 ? $0 : nil }
            components?.fragment = noteID.map { "note_\($0)" }
            return .init(draftID: rejection.draftID, quote: quote,
                discussionURL: noteID == nil ? nil : components?.url,
                reason: rejection.reason, summary: rejection.summary)
        }
    }
}

/// A concrete reason for a human action, shared by the MR card and its detail view.
@MainActor
struct MRHumanAction {
    enum FeedbackEvidence: Equatable {
        case finding(AuthorFeedbackPolicy.Finding)
        case replyThreads([Int])
        case reReview([ReReviewReadiness.Blocker])
        case rawNotes([Int])
        case gitLabStatus
        case unavailable(Int?)
        case none
    }

    private struct EvidenceContext: Equatable {
        let head: String?
        let fingerprint: String?
        let semanticContext: String?

        init(_ status: AuthorFeedbackStatus) {
            head = status.head; fingerprint = status.fingerprint; semanticContext = status.semanticContextFingerprint
        }
        init(reReview item: MergeRequestAttentionMonitor.Item) {
            head = item.mergeRequest?.sha; fingerprint = item.reReviewFingerprint
            semanticContext = item.mergeRequest?.semanticContextFingerprint
        }
        func matches(_ status: AuthorFeedbackStatus, item: MergeRequestAttentionMonitor.Item) -> Bool {
            guard self == Self(status) else { return false }
            guard let request = item.mergeRequest else { return true }
            return head == request.sha && semanticContext == request.semanticContextFingerprint
        }
    }
    private enum Source {
        case none
        case privateCodeQuestion
        case finding(AuthorFeedbackPolicy.Finding, EvidenceContext)
        case replyThread(Int, EvidenceContext)
        case reReview(ReReviewReadiness.Blocker, EvidenceContext)
        case followUp(MRTodoIntent, String?)
    }
    private var source: Source = .none

    func feedbackEvidence(for item: MergeRequestAttentionMonitor.Item) -> FeedbackEvidence {
        switch source {
        case .privateCodeQuestion: return .none
        case .followUp(let intent, let fingerprint):
            let ids = intent.noteIDs.filter { $0 > 0 }.sorted()
            guard !ids.isEmpty, intent.headSHA == item.mergeRequest?.sha,
                  intent.request.webURL == item.url, intent.target.projectID == item.id.projectID,
                  intent.target.iid == item.id.iid, intent.target.username == intent.request.author.username,
                  item.url.isGitLabMergeRequest(host: intent.target.host, iid: item.id.iid),
                  fingerprint == item.observedDiscussionFingerprint else { return .unavailable(ids.first) }
            return .rawNotes(ids)
        case .finding(let finding, let context):
            guard let status = item.authorFeedbackStatus, context.matches(status, item: item),
                  status.phase == .complete || status.phase == .waitingPublication,
                  finding.sourceNoteID != nil, status.findings.contains(finding) else { return .unavailable(sourceNoteID) }
            return .finding(finding)
        case .replyThread(let root, let context):
            guard let status = item.authorFeedbackStatus, context.matches(status, item: item),
                  status.phase == .complete || status.phase == .waitingPublication,
                  status.replyNoteIDs.contains(root) else { return .unavailable(root) }
            return .replyThreads(status.replyNoteIDs.sorted())
        case .reReview(let blocker, let context):
            let current = Self.reReviewBlockers(item).filter { !$0.isPrivateCodeQuestion }
            guard EvidenceContext(reReview: item) == context, current.contains(blocker) else { return .unavailable(blocker.noteID) }
            return .reReview(current)
        case .none:
            guard kind == .feedback || kind == .reviewDecision || action == .verifyFeedback else { return .none }
            let ids = Array(Set(item.feedback.compactMap(\.id))).filter { $0 > 0 }.sorted()
            if !ids.isEmpty { return .rawNotes(ids) }
            if !item.feedback.isEmpty { return .unavailable(nil) }
            return kind == .feedback && (item.needsChanges || item.needsDiscussion) ? .gitLabStatus : .none
        }
    }

    enum Kind: Equatable { case blockedRun, interruptedRun, publication, commentReview, uncheckedDrafts, verificationFailure, setupAssistant, reviewDecision, approval, pipelineHandoff, merge, feedback, intent }
    enum Action: Equatable { case reviewRun, retryRun, reviewDrafts, verifyFeedback, retryDraftVerification, setupAssistant, reviewDecision, reviewApproval, reviewHandoff, reviewMerge, handleFeedback, retryIntent, reviewFeedback, reviewIssue }
    let kind: Kind
    let action: Action
    let message: LocalizedStringResource
    let detail: String?
    let summary: String?
    let preparedReply: PreparedReplyContext?
    /// Exact source of the displayed concern, which can differ from its thread root.
    var sourceNoteID: Int? {
        switch source {
        case .none, .privateCodeQuestion, .followUp: nil
        case .finding(let finding, _): finding.sourceNoteID
        case .replyThread(let root, _): root
        case .reReview(let blocker, _): blocker.noteID
        }
    }
    private var requiresPublishedReply = false
    var explanation: String {
        if requiresPublishedReply { return String(localized: .MRHumanAction.mrHumanActionFeedbackReply) }
        let feedbackReason = kind == .feedback ? AgentExplanation.summary(detail) : nil
        let explanation = AgentExplanation.summary(summary) ?? feedbackReason ?? String(localized: message)
        guard preparedReply != nil else { return explanation }
        let subject = String(localized: .PreparedReplies.preparedRepliesNeedsReview)
        return explanation == subject ? subject : subject + " " + explanation
    }
    var actionLabel: LocalizedStringResource {
        if kind == .commentReview { return .CommentReview.commentReviewFinish }
        if preparedReply != nil { return .PreparedReplies.preparedRepliesReviewAction }
        return switch action {
        case .reviewRun: .MRHumanAction.mrHumanActionActionReviewRun
        case .retryRun: .MRHumanAction.mrHumanActionActionRetryRun
        case .reviewDrafts: .MRHumanAction.mrHumanActionActionReviewDrafts
        case .verifyFeedback: .MRHumanAction.mrHumanActionActionVerifyFeedback
        case .retryDraftVerification: .MRHumanAction.mrHumanActionActionRetryDraftVerification
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

    var showsDirectPublication: Bool {
        kind == .publication && action == .reviewDrafts && preparedReply == nil
    }

    init?(row: MergeRequestBoardSnapshot.Row, assistantReady: Bool,
          confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
          automaticallyPublishedDraftIDs: Set<Int> = []) {
        let item = row.item
        guard row.needsAttention, row.latestJob?.operationalExecution?.state.isActive != true,
              !item.aiOriginChecking,
              item.authorFeedbackStatus?.phase != .checking || item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation,
              item.reReviewReadiness != .checking,
              confirmationState?.isBusy != true else { return nil }

        let stoppedRun = row.stoppedJobNeedsAttention ? row.latestJob?.operationalExecution : nil
        let previousHead = row.latestJob?.expectedHeadSHA
        let currentHead = item.mergeRequest?.sha
        // A push-enabled run may itself have advanced the starting head before
        // stopping; that lease is not evidence that its result is obsolete.
        let mayHavePushed = row.latestJob?.allowsPush == true || row.latestJob?.followUpPushAllowed == true
        let stoppedOnOlderHead = !mayHavePushed && previousHead != nil && currentHead != nil && previousHead != currentHead
        if let execution = stoppedRun, !stoppedOnOlderHead {
            let interrupted = execution.state == .interrupted || execution.state == .cancelled
            let executable = row.latestJob?.taskPrompt != nil && row.latestJob?.mergeRequestURL != nil
            let remaining = Self.remainingConcern(in: row)
            // A different feedback finding is not proof that an independent tool
            // or delivery failure has gone away. Keep that cause visible first.
            let currentSummary = remaining?.summary.map { summary in
                let cause = execution.attentionExplanation
                return cause == summary ? summary : [cause, summary].compactMap { $0 }.joined(separator: "\n")
            } ?? execution.blocker
            self.init(kind: interrupted ? .interruptedRun : .blockedRun, action: executable ? .retryRun : .reviewRun,
                      message: interrupted ? .MRHumanAction.mrHumanActionInterruptedRun : .MRHumanAction.mrHumanActionBlockedRun,
                      detail: execution.attentionExplanation, summary: currentSummary)
            if let remaining, let status = item.authorFeedbackStatus { source = .finding(remaining, EvidenceContext(status)) }
            return
        }

        if item.requiresCommentReview, item.draftCount == 0, item.drafts.isEmpty {
            self.init(kind: .commentReview, action: .reviewDrafts, message: .CommentReview.commentReviewPending)
            return
        }

        // Recovery verifies evidence, so its retry must never publish the draft.
        // An independent stopped worker keeps the higher-priority action above.
        if item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation {
            guard let intent = row.attentionIntents.first(where: { $0.state == .failed && !row.isReconciling($0) }) else { return nil }
            self.init(kind: .intent, action: .retryIntent, message: Self.intentMessage(intent),
                      detail: intent.error.map(GlabService.redactWorkflowEvidence))
            if intent.kind == .followUp { source = .followUp(intent, item.observedDiscussionFingerprint) }
            return
        }
        if let failure = item.draftProofRecoveryFailure {
            if let reply = PreparedReplyContext.rejected(in: item).first {
                self.init(kind: .verificationFailure, action: .reviewDrafts,
                          message: .PreparedReplies.preparedRepliesNeedsReview,
                          detail: reply.reason, summary: reply.summary, preparedReply: reply)
                return
            }
            self.init(kind: .verificationFailure, action: .retryDraftVerification,
                      message: .MRHumanAction.mrHumanActionDraftVerificationFailure,
                      detail: GlabService.redactWorkflowEvidence(failure), summary: item.draftProofRecoverySummary)
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
        let intent = row.attentionIntents.first { $0.state == .failed && !row.isReconciling($0) }
            ?? row.attentionIntents.first { $0.state == .pending && !$0.isDeferredReview }
        let needsAssistant = intent.map { $0.kind != .refresh } == true || !item.feedback.isEmpty
            || item.needsDiscussion || item.needsChanges || item.failedPipeline || item.hasConflict
            || item.authorFeedbackStatus?.needsAttention == true || item.autoApproveReady
        if item.canConfirmReReview {
            self.init(kind: .reviewDecision, action: .reviewDecision, message: Self.reviewDecisionMessage(item),
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if item.canApprove && !item.approvalWaitingForReadiness {
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
            self.init(kind: .feedback, action: Self.feedbackAction(item), message: Self.feedbackMessage(item),
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if let intent {
            self.init(kind: .intent, action: .retryIntent, message: Self.intentMessage(intent),
                      detail: intent.error.map(GlabService.redactWorkflowEvidence))
            if intent.kind == .followUp { source = .followUp(intent, item.observedDiscussionFingerprint) }
        } else if item.hasConflict {
            self.init(kind: .intent, action: .reviewIssue, message: .MRHumanAction.mrHumanActionConflictIntent)
        } else if item.failedPipeline {
            self.init(kind: .intent, action: .reviewIssue, message: .MRHumanAction.mrHumanActionPipelineIntent)
        } else if item.reReviewReadiness != nil || item.reReviewUnconfirmed {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: Self.reviewDecisionMessage(item),
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if item.needsChanges || !item.feedback.isEmpty {
            self.init(kind: .feedback, action: .reviewFeedback,
                      message: item.needsChanges ? .MRHumanAction.mrHumanActionChangesRequested : .MRHumanAction.mrHumanActionFeedbackUnverified,
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if item.needsDiscussion {
            self.init(kind: .feedback, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionDiscussion)
        } else if unchecked {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionCurrentCheckMissing)
        } else if confirmationState == .failed {
            self.init(kind: .reviewDecision, action: .reviewFeedback, message: .MRHumanAction.mrHumanActionLastActionFailed)
        } else if stoppedRun != nil {
            self.init(kind: .interruptedRun, action: .reviewRun, message: .MRHumanAction.mrHumanActionPreviousHeadRun)
        } else { return nil }
        if kind == .feedback || kind == .reviewDecision {
            if let status = item.authorFeedbackStatus, let finding = Self.feedbackFinding(item) {
                source = .finding(finding, EvidenceContext(status))
                requiresPublishedReply = item.authorFeedbackStatus?.replyNoteIDs.contains(finding.id) == true
                    && ![.needsChanges, .needsVerification].contains(finding.state)
            } else if let status = item.authorFeedbackStatus, let root = status.replyNoteIDs.min() {
                source = .replyThread(root, EvidenceContext(status))
                requiresPublishedReply = true
            } else if item.authorFeedbackStatus?.codeReviewRequests.isEmpty == false {
                source = .privateCodeQuestion
            } else if let blocker = Self.reReviewBlockers(item).first {
                source = blocker.isPrivateCodeQuestion ? .privateCodeQuestion : .reReview(blocker, EvidenceContext(reReview: item))
            }
        }
    }

    private init(kind: Kind, action: Action, message: LocalizedStringResource, detail: String? = nil, summary: String? = nil,
                 preparedReply: PreparedReplyContext? = nil) {
        self.kind = kind; self.action = action; self.message = message; self.detail = detail; self.summary = summary
        self.preparedReply = preparedReply
    }

    private static func feedbackFinding(_ item: MergeRequestAttentionMonitor.Item) -> AuthorFeedbackPolicy.Finding? {
        item.authorFeedbackStatus?.primaryFinding
    }

    private static func feedbackSummary(_ item: MergeRequestAttentionMonitor.Item) -> String? {
        if let finding = feedbackFinding(item) { return finding.summary }
        if item.authorFeedbackStatus?.replyNoteIDs.isEmpty == false { return nil }
        return item.authorFeedbackStatus?.codeReviewRequests.first?.summary ?? reReviewBlockers(item).first?.summary
    }

    private static func reReviewBlockers(_ item: MergeRequestAttentionMonitor.Item) -> [ReReviewReadiness.Blocker] {
        switch item.reReviewReadiness {
        case .blocked(let blockers), .uncertain(let blockers): blockers
        default: []
        }
    }

    private static func feedbackAction(_ item: MergeRequestAttentionMonitor.Item) -> Action {
        feedbackFinding(item)?.state == .needsVerification ? .reviewFeedback : .handleFeedback
    }

    private static func feedbackMessage(_ item: MergeRequestAttentionMonitor.Item) -> LocalizedStringResource {
        if let finding = feedbackFinding(item) {
            if finding.state == .needsChanges { return .MRHumanAction.mrHumanActionFeedback }
            if finding.state == .needsVerification { return .MRHumanAction.mrHumanActionFeedbackUnverified }
            if item.authorFeedbackStatus?.replyNoteIDs.contains(finding.id) == true { return .MRHumanAction.mrHumanActionFeedbackReply }
        }
        if item.authorFeedbackStatus?.replyNoteIDs.isEmpty == false { return .MRHumanAction.mrHumanActionFeedbackReply }
        return .MRHumanAction.mrHumanActionFeedbackUnverified
    }

    private static func remainingConcern(in row: MergeRequestBoardSnapshot.Row) -> AuthorFeedbackPolicy.Finding? {
        let item = row.item
        guard let job = row.latestJob, job.workflow == .followUp,
              job.key.work.projectID == item.id.projectID, job.key.work.iid == item.id.iid,
              let request = item.mergeRequest, request.author.username == job.key.username,
              item.url.isGitLabMergeRequest(host: job.key.work.host, iid: item.id.iid),
              let status = item.authorFeedbackStatus, status.phase == .complete,
              status.head == request.sha, status.fingerprint == item.observedDiscussionFingerprint,
              status.semanticContextFingerprint == request.semanticContextFingerprint else { return nil }
        let selected = Set(job.feedbackNoteIDs ?? [])
        guard !selected.isDisjoint(with: status.ignoredNoteIDs) else { return nil }
        var selectedStatus = status
        selectedStatus.findings = status.findings.filter { finding in
            guard let source = finding.sourceNoteID, selected.contains(source),
                  status.followUpNoteIDs.contains(source), !status.ignoredNoteIDs.contains(source),
                  [.needsChanges, .needsVerification].contains(finding.state) else { return false }
            return true
        }
        return selectedStatus.primaryFinding
    }

    private static func feedbackDetail(_ item: MergeRequestAttentionMonitor.Item) -> String? {
        if let finding = feedbackFinding(item) {
            guard let reason = finding.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return reason
        }
        if item.authorFeedbackStatus?.replyNoteIDs.isEmpty == false { return nil }
        return item.authorFeedbackStatus?.codeReviewRequests.first?.question ?? reReviewBlockers(item).first?.reason
    }

    private static func reviewDecisionMessage(_ item: MergeRequestAttentionMonitor.Item) -> LocalizedStringResource {
        switch item.reReviewReadiness {
        case .failed, .unavailable: .MRHumanAction.mrHumanActionVerificationFailure
        case .blocked: .MRHumanAction.mrHumanActionFeedback
        case .uncertain: .MRHumanAction.mrHumanActionFeedbackUnverified
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
