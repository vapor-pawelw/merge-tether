import Foundation

enum ManualMergeBlocker: Equatable {
    case context, checking, capability, submission, pipelineHandoff
    case feedback(ManualMergeFeedbackBlocker)
    case prerequisite(MergeRequestBlocker)

    var recoveryAction: ManualMergeFeedbackBlocker.RecoveryAction? {
        if case .feedback(let reason) = self { return reason.recoveryAction }
        return nil
    }

    var title: LocalizedStringResource {
        switch self {
        case .context: .MergeActions.mergeActionsContextChanged
        case .checking: .MergeActions.mergeActionsChecking
        case .capability: .MergeActions.mergeActionsUnavailable
        case .submission: .MergeActions.mergeActionsChanged
        case .feedback(let reason): reason.title
        case .pipelineHandoff: .MergeActions.mergeActionsPipelineHandoff
        case .prerequisite(let blocker):
            switch blocker {
            case .draft: .MergeActions.mergeActionsDraft
            case .unpublishedDrafts, .commentReview: .MergeActions.mergeActionsCommentReview
            case .approvals: .MergeActions.mergeActionsApprovals
            case .changesRequested: .MergeActions.mergeActionsChangesRequested
            case .discussions: .MergeActions.mergeActionsDiscussions
            case .dependencies: .MergeActions.mergeActionsDependencies
            case .stackTarget: .MergeActions.mergeActionsStackTarget
            case .dependencyEvidence: .MergeActions.mergeActionsDependencyEvidence
            case .conflictTaskFailed, .conflicts: .MergeActions.mergeActionsConflicts
            case .pipeline: .MergeActions.mergeActionsPipeline
            case .permissions: .MergeActions.mergeActionsPermissions
            case .checking: .MergeActions.mergeActionsChecking
            case .unknown: .MergeActions.mergeActionsEvidenceUnavailable
            default: .MergeActions.mergeActionsBlocked
            }
        }
    }
}

enum ManualMergeFeedbackBlocker: Equatable {
    enum RecoveryAction: Equatable { case refresh, verifyFeedback, reviewFeedback }
    case checking, verificationFailed, sourceChanged, discussionChanged, descriptionChanged, conversationUnavailable
    case assessmentMissing, unverifiedComments, changes, verificationNeeded, publication, reply, codeReview, followUp

    var title: LocalizedStringResource {
        switch self {
        case .checking: .MergeActions.mergeActionsFeedbackChecking
        case .verificationFailed: .MergeActions.mergeActionsFeedbackFailed
        case .sourceChanged: .MergeActions.mergeActionsFeedbackSourceChanged
        case .discussionChanged: .MergeActions.mergeActionsFeedbackDiscussionChanged
        case .descriptionChanged: .MergeActions.mergeActionsFeedbackDescriptionChanged
        case .conversationUnavailable: .MergeActions.mergeActionsFeedbackConversationUnavailable
        case .assessmentMissing, .unverifiedComments: .MergeActions.mergeActionsFeedbackUnverified
        case .changes, .followUp: .MergeActions.mergeActionsFeedbackChanges
        case .verificationNeeded: .MergeActions.mergeActionsFeedbackVerificationNeeded
        case .publication: .MergeActions.mergeActionsFeedbackPublication
        case .reply: .MergeActions.mergeActionsFeedbackReply
        case .codeReview: .MergeActions.mergeActionsFeedbackCodeReview
        }
    }

    var recoveryAction: RecoveryAction? {
        switch self {
        case .checking: nil
        case .verificationFailed, .assessmentMissing: .verifyFeedback
        case .sourceChanged, .discussionChanged, .descriptionChanged, .conversationUnavailable: .refresh
        default: .reviewFeedback
        }
    }
}

enum ManualFeedbackRecheckRoute: Equatable {
    case verify, review

    init(backgroundCheckAllowed: Bool) { self = backgroundCheckAllowed ? .verify : .review }

    var recoveryAction: ManualMergeFeedbackBlocker.RecoveryAction {
        self == .verify ? .verifyFeedback : .reviewFeedback
    }

    func perform(verify: () -> Void, review: () -> Void) {
        switch self {
        case .verify: verify()
        case .review: review()
        }
    }
}

enum ManualFeedbackReviewDestination: Equatable {
    case gitLab(URL), verification

    init(item: MergeRequestAttentionMonitor.Item) {
        self = item.authorFeedbackStatus == nil ? .gitLab(item.url) : .verification
    }
}

extension MergeRequestAttentionMonitor.Item {
    func canOfferManualMerge(using status: AuthoredMergeRequestStatus) -> Bool {
        manualMergeBlocker(using: status) == nil
    }

    func manualMergeBlocker(using status: AuthoredMergeRequestStatus?) -> ManualMergeBlocker? {
        guard let request = mergeRequest, isAuthored else { return .context }
        guard let status else { return .checking }
        guard request.webURL == url, request.projectID == id.projectID, request.iid == id.iid,
              status.matchesCurrentRequest(request) else { return .context }
        guard status.submissionState == .none, !request.hasQueuedMerge else { return .submission }
        guard let action = status.action else { return .capability }
        if let blocker = catalogMergeBlocker(request, action: action) { return blocker }
        if requiresCommentReview || draftCount > 0 || !drafts.isEmpty { return .prerequisite(.commentReview) }
        if let reason = mergeFeedbackBlocker(for: request) { return .feedback(reason) }
        let verified = presentingVerifiedAuthorFeedback()
        if !verified.feedback.isEmpty { return .feedback(.unverifiedComments) }
        if verified.needsDiscussion || verified.hasOtherUnresolvedDiscussions { return .prerequisite(.discussions) }
        if verified.needsChanges { return .prerequisite(.changesRequested) }
        if hasConflict { return .prerequisite(.conflicts) }
        if failedPipeline { return .prerequisite(.pipeline) }
        if needsPipelineHandoff { return .pipelineHandoff }
        guard status.mayMergeManually else {
            return .prerequisite(status.blockers.first ?? .unknown)
        }
        return nil
    }

    private func mergeFeedbackBlocker(for request: GitLabMergeRequest) -> ManualMergeFeedbackBlocker? {
        if requiresDiscussionRecheck { return .discussionChanged }
        guard let status = authorFeedbackStatus else { return feedback.isEmpty ? nil : .assessmentMissing }
        guard status.head == request.sha else { return .sourceChanged }
        guard status.semanticContextFingerprint != nil else { return .assessmentMissing }
        guard status.semanticContextFingerprint == request.semanticContextFingerprint else { return .descriptionChanged }
        guard observedDiscussionFingerprint != nil else { return .conversationUnavailable }
        guard status.fingerprint == observedDiscussionFingerprint else { return .discussionChanged }
        if status.phase == .checking { return .checking }
        if status.phase == .failed { return .verificationFailed }
        if status.phase == .waitingPublication || status.pendingDraftCount > 0 { return .publication }
        if !status.replyNoteIDs.isEmpty { return .reply }
        if !status.codeReviewRequests.isEmpty { return .codeReview }
        if status.findings.contains(where: { $0.state == .needsChanges }) { return .changes }
        if status.findings.contains(where: { $0.state == .needsVerification }) { return .verificationNeeded }
        if !status.followUpNoteIDs.isEmpty { return .followUp }
        return nil
    }

    private func catalogMergeBlocker(_ request: GitLabMergeRequest, action: MergeSubmissionAction) -> ManualMergeBlocker? {
        guard request.state == "opened" else { return .context }
        if request.draft == true { return .prerequisite(.draft) }
        if request.canMerge == false { return .prerequisite(.permissions) }
        if request.hasMergeConflict { return .prerequisite(.conflicts) }
        if request.mergeTrainEvidenceUnavailable { return .prerequisite(.unknown) }
        if request.blockingDiscussionsResolved == false { return .prerequisite(.discussions) }
        // List responses omit user permissions and pipeline details. The exact-context
        // authored status supplies those checks; explicit newer catalog blockers still veto.
        if let pipeline = request.headPipeline, pipeline.status != "success",
           !(action == .enqueue && ["created", "pending", "running", "preparing", "waiting_for_resource"].contains(pipeline.status)) {
            return .prerequisite(.pipeline)
        }
        switch request.detailedMergeStatus {
        case nil, "mergeable": return nil
        case "ci_still_running" where action == .enqueue: return nil
        case "draft_status": return .prerequisite(.draft)
        case "not_approved": return .prerequisite(.approvals)
        case "requested_changes": return .prerequisite(.changesRequested)
        case "discussions_not_resolved": return .prerequisite(.discussions)
        case "ci_must_pass", "ci_still_running", "security_policy_pipeline_check", "status_checks_must_pass":
            return .prerequisite(.pipeline)
        case "approvals_syncing", "checking", "preparing", "unchecked": return .prerequisite(.checking)
        default: return .prerequisite(.other)
        }
    }
}
