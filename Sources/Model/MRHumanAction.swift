import Foundation

enum MRVerificationRetry: String, CaseIterable {
    case authorFeedback = "verifyAuthorFeedback"
    case drafts = "verifyDrafts"
    case reReview = "verifyReReview"

    var label: LocalizedStringResource {
        switch self {
        case .authorFeedback: .MRHumanAction.mrHumanActionActionVerifyFeedback
        case .drafts: .MRHumanAction.mrHumanActionActionRetryDraftVerification
        case .reReview: .Menu.menuReReviewRetry
        }
    }

    var effect: MRActionCTA {
        switch self {
        case .authorFeedback: .verifyFeedback
        case .drafts: .retryDraftVerification
        case .reReview: .verifyReReview
        }
    }

    @MainActor
    func isAvailable(for item: MergeRequestAttentionMonitor.Item, failedFollowUp: MRHumanAction.FailedFollowUp? = nil) -> Bool {
        guard let request = item.mergeRequest, request.isOpen, request.sha?.isEmpty == false else { return false }
        switch self {
        case .authorFeedback:
            return item.isAuthored && (failedFollowUp?.canVerify ?? (item.authorFeedbackStatus?.phase == .failed))
        case .drafts: return item.draftProofRecoveryFailure != nil
        case .reReview: return item.reReviewReadiness == .failed || item.reReviewReadiness == .unavailable
        }
    }
}

struct MRFeedbackRecheckProgress {
    let target: MRAutomationScope.Target
    let accountRevision: UInt64
    let retryIntentID: UUID?

    func isActive(for target: MRAutomationScope.Target?, revision: UInt64, refreshing: Bool,
                  phase: AuthorFeedbackStatus.Phase?) -> Bool {
        self.target == target && accountRevision == revision && (refreshing || phase == .checking)
    }
}

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

    struct FailedFollowUp {
        let intent: MRTodoIntent
        let job: AssistantAutomationRunner.Handoff?
        let feedback: AuthorFeedbackStatus?
        let evidence: FeedbackEvidence
        let discussionFingerprint: String?
        let diagnostics: String?
        let retriesWorker: Bool

        var prefersVerification: Bool { job?.operationalExecution?.state == .succeeded }
        var canVerify: Bool { feedback.map { $0.phase != .checking } == true }
        var title: LocalizedStringResource {
            prefersVerification ? .CommandCenter.commandCenterFollowUpNeedsVerification : .MRHumanAction.mrHumanActionFollowUpFailed
        }
        var reason: String? {
            if prefersVerification { return String(localized: .CommandCenter.commandCenterFollowUpVerificationReason) }
            let reason = AgentExplanation.summary(diagnostics)
            return reason == String(localized: title) ? nil : reason
        }
        var retryActionID: String {
            if retriesWorker, let job { return "job:\(job.id)" }
            return "intent:\(intent.id)"
        }

        func matchesOriginalNote(_ id: Int, authorID: Int, body: String) -> Bool {
            guard let revisions = job?.verifiedFeedbackNotes else { return true }
            return revisions[id] == UserAttentionSnapshot.digest("\(authorID)\n\(body)")
        }
    }

    func failedFollowUp(in row: MergeRequestBoardSnapshot.Row,
                        jobs: [AssistantAutomationRunner.Handoff]) -> FailedFollowUp? {
        guard row.evidenceMatchesCatalogContext, !row.hasFollowUpInProgress,
              let intent = row.attentionIntents.first(where: { candidate in
                  guard candidate.kind == .followUp, candidate.state == .failed, !row.isReconciling(candidate) else { return false }
                  if action == .retryRun { return retryJob.map { $0.id == candidate.jobID } == true }
                  return retryIntent?.id == candidate.id
              }),
              let request = row.displayRequest, request.isOpen,
              intent.target.username == request.author.username,
              intent.target.projectID == request.projectID, intent.target.iid == request.iid,
              intent.request.webURL == request.webURL,
              request.webURL.isGitLabMergeRequest(host: intent.target.host, iid: request.iid) else { return nil }
        let job = jobs.first {
            $0.id == intent.jobID && $0.workflow == .followUp
                && $0.key.username == intent.target.username && $0.key.work.host == intent.target.host
                && $0.key.work.projectID == request.projectID && $0.key.work.iid == request.iid
        }
        let retriesWorker = action == .retryRun && job?.id == retryJob?.id && job?.selectedFollowUpNotes.isEmpty == false
        guard retriesWorker || retryIntent?.id == intent.id else { return nil }
        let fingerprint = row.item.observedDiscussionFingerprint
        let diagnostics = intent.failureExplanation(currentHead: request.sha)
            ?? job?.execution.flatMap { intent.failureExplanation(currentHead: request.sha, execution: $0) }
        return .init(intent: intent, job: job, feedback: row.item.authorFeedbackStatus,
            evidence: Self.followUpEvidence(intent, fingerprint: fingerprint, item: row.item), discussionFingerprint: fingerprint,
            diagnostics: diagnostics, retriesWorker: retriesWorker)
    }

    private static func reReviewEvidence(_ item: MergeRequestAttentionMonitor.Item) -> EvidenceContext {
        .init(head: item.mergeRequest?.sha,
              discussionContent: item.reReviewFingerprint.map(DiscussionContentDigest.init),
              semanticContext: item.mergeRequest?.semanticContextDigest)
    }

    private static func matchesFeedback(_ recorded: EvidenceContext, status: AuthorFeedbackStatus,
                                        item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard recorded.binds(to: status.evidenceContext, policy: .feedbackPresentation) else { return false }
        guard let request = item.mergeRequest else { return true }
        return recorded.binds(to: request.evidenceContext(), policy: .requestText)
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
            return Self.followUpEvidence(intent, fingerprint: fingerprint, item: item)
        case .finding(let finding, let context):
            guard let status = item.authorFeedbackStatus, Self.matchesFeedback(context, status: status, item: item),
                  status.phase == .complete || status.phase == .waitingPublication,
                  finding.sourceNoteID != nil, status.findings.contains(finding) else { return .unavailable(sourceNoteID) }
            return .finding(finding)
        case .replyThread(let root, let context):
            guard let status = item.authorFeedbackStatus, Self.matchesFeedback(context, status: status, item: item),
                  status.phase == .complete || status.phase == .waitingPublication,
                  status.replyNoteIDs.contains(root) else { return .unavailable(root) }
            return .replyThreads(status.replyNoteIDs.sorted())
        case .reReview(let blocker, let context):
            let current = Self.reReviewBlockers(item).filter { !$0.isPrivateCodeQuestion }
            guard context.binds(to: Self.reReviewEvidence(item), policy: .feedbackPresentation),
                  current.contains(blocker) else { return .unavailable(blocker.noteID) }
            return .reReview(current)
        case .none:
            guard kind == .feedback || kind == .reviewDecision || action == .verifyFeedback else { return .none }
            let ids = Array(Set(item.feedback.compactMap(\.id))).filter { $0 > 0 }.sorted()
            if !ids.isEmpty { return .rawNotes(ids) }
            if !item.feedback.isEmpty { return .unavailable(nil) }
            return kind == .feedback && (item.needsChanges || item.needsDiscussion) ? .gitLabStatus : .none
        }
    }

    private static func followUpEvidence(_ intent: MRTodoIntent, fingerprint: String?,
                                         item: MergeRequestAttentionMonitor.Item) -> FeedbackEvidence {
        let ids = intent.noteIDs.filter { $0 > 0 }.sorted()
        let recorded = EvidenceContext(head: intent.headSHA, discussionContent: fingerprint.map(DiscussionContentDigest.init))
        let current = EvidenceContext(head: item.mergeRequest?.sha,
                                      discussionContent: item.observedDiscussionFingerprint.map(DiscussionContentDigest.init))
        guard !ids.isEmpty, recorded.binds(to: current, policy: .followUpPresentation),
              intent.request.webURL == item.url, intent.target.projectID == item.id.projectID,
              intent.target.iid == item.id.iid, intent.target.username == intent.request.author.username,
              item.url.isGitLabMergeRequest(host: intent.target.host, iid: item.id.iid) else { return .unavailable(ids.first) }
        return .rawNotes(ids)
    }

    enum Kind: Equatable { case blockedRun, interruptedRun, publication, commentReview, uncheckedDrafts, duplicateDrafts, verificationFailure, setupAssistant, reviewDecision, approval, pipelineHandoff, merge, feedback, intent }
    enum Action: Equatable { case reviewRun, retryRun, reviewDrafts, verifyFeedback, retryDraftVerification, retryReReview, setupAssistant, reviewDecision, reviewApproval, reviewHandoff, reviewMerge, handleFeedback, retryIntent, reviewFeedback, reviewIssue }
    let kind: Kind
    let action: Action
    let message: LocalizedStringResource
    let detail: String?
    let summary: String?
    let preparedReply: PreparedReplyContext?
    private(set) var retryIntent: MRTodoIntent?
    private(set) var retryJob: AssistantAutomationRunner.Handoff?

    var executableActionID: String? {
        switch action {
        case .retryIntent: retryIntent.map { "intent:\($0.id)" }
        case .retryRun: retryJob.map { "job:\($0.id)" }
        case .handleFeedback: "prepare"
        case .verifyFeedback: MRVerificationRetry.authorFeedback.rawValue
        case .retryDraftVerification: MRVerificationRetry.drafts.rawValue
        case .retryReReview: MRVerificationRetry.reReview.rawValue
        default: nil
        }
    }
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
        let reason = kind == .feedback || retryIntent?.kind == .review ? AgentExplanation.summary(detail) : nil
        let explanation = AgentExplanation.summary(summary) ?? reason ?? String(localized: message)
        guard preparedReply != nil else { return explanation }
        let subject = String(localized: .PreparedReplies.preparedRepliesNeedsReview)
        return explanation == subject ? subject : subject + " " + explanation
    }
    var actionLabel: LocalizedStringResource {
        if kind == .commentReview { return .CommentReview.commentReviewFinish }
        if preparedReply != nil { return .PreparedReplies.preparedRepliesReviewAction }
        return switch action {
        case .reviewRun: .MRHumanAction.mrHumanActionActionReviewRun
        case .retryRun: retryJob.map(Self.retryLabel) ?? .MRHumanAction.mrHumanActionActionRetryRun
        case .reviewDrafts: .MRHumanAction.mrHumanActionActionReviewDrafts
        case .verifyFeedback: .MRHumanAction.mrHumanActionActionVerifyFeedback
        case .retryDraftVerification: .MRHumanAction.mrHumanActionActionRetryDraftVerification
        case .retryReReview: MRVerificationRetry.reReview.label
        case .setupAssistant: .MRHumanAction.mrHumanActionActionSetupAssistant
        case .reviewDecision: .MRHumanAction.mrHumanActionActionReviewDecision
        case .reviewApproval: .MRHumanAction.mrHumanActionActionReviewApproval
        case .reviewHandoff: .MRHumanAction.mrHumanActionActionReviewHandoff
        case .reviewMerge: .MRHumanAction.mrHumanActionActionReviewMerge
        case .handleFeedback: .MRHumanAction.mrHumanActionActionHandleFeedback
        case .retryIntent: retryIntent.map(Self.intentLabel) ?? .MRHumanAction.mrHumanActionActionRetryIntent
        case .reviewFeedback: .MRHumanAction.mrHumanActionActionReviewFeedback
        case .reviewIssue: .MRHumanAction.mrHumanActionActionReviewIssue
        }
    }

    enum DraftPublicationShortcut: Equatable { case publishAll, review }

    func draftPublicationShortcut(for drafts: [GitLabDraftNote]) -> DraftPublicationShortcut? {
        guard action == .reviewDrafts, preparedReply == nil, !drafts.isEmpty,
              [.publication, .uncheckedDrafts, .duplicateDrafts].contains(kind) else { return nil }
        if drafts.contains(where: DraftPublicationRisk.hasSideEffects) { return .review }
        return kind == .publication ? .publishAll : nil
    }

    init?(row: MergeRequestBoardSnapshot.Row, assistantReady: Bool,
          confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
          automaticallyPublishedDraftIDs: Set<Int> = [], automaticMergePolicyHold: LocalizedStringResource? = nil) {
        let item = row.presented
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
            if executable { retryJob = row.latestJob }
            if let remaining, let status = item.authorFeedbackStatus { source = .finding(remaining, status.evidenceContext) }
            return
        }

        if item.requiresCommentReview, item.drafts.isEmpty {
            self.init(kind: .commentReview, action: .reviewDrafts, message: .CommentReview.commentReviewPending)
            return
        }

        // Recovery verifies evidence, so its retry must never publish the draft.
        // An independent stopped worker keeps the higher-priority action above.
        if item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation {
            guard let intent = row.attentionIntents.first(where: { $0.state == .failed && !row.isReconciling($0) }) else { return nil }
            self.init(kind: .intent, action: .retryIntent, message: Self.intentMessage(intent),
                      detail: intent.failureExplanation(currentHead: row.displayRequest?.sha))
            retryIntent = intent
            if intent.kind == .followUp { source = .followUp(intent, item.observedDiscussionFingerprint) }
            return
        }
        if let failure = item.draftProofRecoveryFailure {
            if let reply = PreparedReplyContext.rejected(in: item.evidence).first {
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
        let count = max(item.draftCount, item.authorFeedbackStatus?.pendingDraftCount ?? 0) - knownAutomatic
        let unchecked = item.awaitingRemoteVerification || item.requiresDiscussionRecheck || confirmationState == .changed
        // A draft repeating a published reply is deleted, not published; it never offers direct publication.
        let duplicates = item.duplicateDraftIDs.count
        if duplicates > 0 {
            self.init(kind: .duplicateDrafts, action: .reviewDrafts, message: duplicates == 1
                ? .MRHumanAction.mrHumanActionDuplicateDraftSingle : .MRHumanAction.mrHumanActionDuplicateDrafts(duplicates))
            return
        }
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
        let hasOutstandingFeedback = item.authorFeedbackStatus?.needsAttention == true
            || item.needsChanges || !item.feedback.isEmpty || item.reReviewReadiness?.hasConcreteConcerns == true
        if assistantReady, MRVerificationRetry.reReview.isAvailable(for: item.evidence), item.authorFeedbackStatus?.needsAttention != true {
            self.init(kind: .verificationFailure, action: .retryReReview, message: .MRHumanAction.mrHumanActionVerificationFailure)
        } else if item.canConfirmReReview, item.reReviewReadiness?.hasConcreteConcerns != true {
            self.init(kind: .reviewDecision, action: .reviewDecision, message: Self.reviewDecisionMessage(item),
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if item.canApprove && !item.approvalWaitingForReadiness {
            self.init(kind: .approval, action: .reviewApproval, message: .MRHumanAction.mrHumanActionApproval)
        } else if item.needsPipelineHandoff {
            self.init(kind: .pipelineHandoff, action: .reviewHandoff, message: .MRHumanAction.mrHumanActionPipelineHandoff)
        } else if item.needsMerge && !hasOutstandingFeedback {
            self.init(kind: .merge, action: .reviewMerge, message: automaticMergePolicyHold ?? .MRHumanAction.mrHumanActionMerge)
        } else if item.authorFeedbackStatus?.phase == .failed {
            self.init(kind: .verificationFailure, action: assistantReady ? .verifyFeedback : .setupAssistant,
                      message: .MRHumanAction.mrHumanActionVerificationFailure)
        } else if !assistantReady && needsAssistant && item.authorFeedbackStatus?.primaryFinding?.manualDecision == nil
            && item.reReviewReadiness?.hasConcreteConcerns != true {
            self.init(kind: .setupAssistant, action: .setupAssistant, message: .MRHumanAction.mrHumanActionSetupAssistant)
        } else if item.authorFeedbackStatus?.needsAttention == true {
            self.init(kind: .feedback, action: Self.feedbackAction(item), message: Self.feedbackMessage(item),
                      detail: Self.feedbackDetail(item), summary: Self.feedbackSummary(item))
        } else if let intent {
            self.init(kind: .intent, action: .retryIntent, message: Self.intentMessage(intent),
                      detail: intent.failureExplanation(currentHead: row.displayRequest?.sha))
            retryIntent = intent
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
                source = .finding(finding, status.evidenceContext)
                requiresPublishedReply = item.authorFeedbackStatus?.replyNoteIDs.contains(finding.id) == true
                    && ![.needsChanges, .needsVerification].contains(finding.state)
            } else if let status = item.authorFeedbackStatus, let root = status.replyNoteIDs.min() {
                source = .replyThread(root, status.evidenceContext)
                requiresPublishedReply = true
            } else if item.authorFeedbackStatus?.codeReviewRequests.isEmpty == false {
                source = .privateCodeQuestion
            } else if let blocker = Self.reReviewBlockers(item.evidence).first {
                source = blocker.isPrivateCodeQuestion ? .privateCodeQuestion : .reReview(blocker, Self.reReviewEvidence(item.evidence))
            }
        }
    }

    private init(kind: Kind, action: Action, message: LocalizedStringResource, detail: String? = nil, summary: String? = nil,
                 preparedReply: PreparedReplyContext? = nil) {
        self.kind = kind; self.action = action; self.message = message; self.detail = detail; self.summary = summary
        self.preparedReply = preparedReply
    }

    private static func feedbackFinding(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> AuthorFeedbackPolicy.Finding? {
        item.authorFeedbackStatus?.primaryFinding
    }

    private static func feedbackSummary(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> String? {
        if let finding = feedbackFinding(item) { return finding.summary }
        if item.authorFeedbackStatus?.replyNoteIDs.isEmpty == false { return nil }
        return item.authorFeedbackStatus?.codeReviewRequests.first?.summary ?? reReviewBlockers(item.evidence).first?.summary
    }

    private static func reReviewBlockers(_ item: MergeRequestAttentionMonitor.Item) -> [ReReviewReadiness.Blocker] {
        switch item.reReviewReadiness {
        case .blocked(let blockers), .uncertain(let blockers): blockers
        default: []
        }
    }

    private static func feedbackAction(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> Action {
        feedbackFinding(item)?.state == .needsVerification ? .reviewFeedback : .handleFeedback
    }

    private static func feedbackMessage(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> LocalizedStringResource {
        if let finding = feedbackFinding(item) {
            if finding.manualDecision != nil { return .AuthorFeedback.authorFeedbackManualDecision }
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
              status.evidenceContext.binds(to: item.observedEvidenceContext, policy: .verifiedFeedback) else { return nil }
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

    private static func feedbackDetail(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> String? {
        if let finding = feedbackFinding(item) {
            guard let reason = finding.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return reason
        }
        if item.authorFeedbackStatus?.replyNoteIDs.isEmpty == false { return nil }
        return item.authorFeedbackStatus?.codeReviewRequests.first?.question ?? reReviewBlockers(item.evidence).first?.reason
    }

    private static func reviewDecisionMessage(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> LocalizedStringResource {
        switch item.reReviewReadiness {
        case .failed, .unavailable: .MRHumanAction.mrHumanActionVerificationFailure
        case .blocked: .MRHumanAction.mrHumanActionFeedback
        case .uncertain: .MRHumanAction.mrHumanActionFeedbackUnverified
        default: .MRHumanAction.mrHumanActionReviewDecision
        }
    }

    static func retryLabel(_ job: AssistantAutomationRunner.Handoff) -> LocalizedStringResource {
        switch job.taskIntent {
        case .pipelineDiagnosis: return .MRHumanAction.mrHumanActionRetryPipeline
        case .conflictResolution: return .MRHumanAction.mrHumanActionRetryConflict
        case .review: return .MRHumanAction.mrHumanActionRetryReview
        case nil: break
        }
        switch job.workflow {
        case .review: return .MRHumanAction.mrHumanActionRetryReview
        case .followUp: return .MRHumanAction.mrHumanActionRetryFollowUp
        case .draftReply: return .MRHumanAction.mrHumanActionRetryDraftReply
        case nil: return .MRHumanAction.mrHumanActionActionRetryRun
        }
    }

    static func intentLabel(_ intent: MRTodoIntent) -> LocalizedStringResource {
        let failed = intent.state == .failed
        switch intent.kind {
        case .review: return failed ? .MRHumanAction.mrHumanActionRetryReview : .CommandCenter.commandCenterReviewRun
        case .followUp: return failed ? .MRHumanAction.mrHumanActionRetryFollowUp : .MRHumanAction.mrHumanActionRunFollowUp
        case .pipeline: return failed ? .MRHumanAction.mrHumanActionRetryPipeline : .MRHumanAction.mrHumanActionRunPipeline
        case .conflict: return failed ? .MRHumanAction.mrHumanActionRetryConflict : .MRHumanAction.mrHumanActionRunConflict
        case .refresh: return failed ? .MRHumanAction.mrHumanActionRetryRefresh : .MRHumanAction.mrHumanActionRunRefresh
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
