import Foundation

enum ManualMergeBlocker: Equatable {
    case context, checking, capability, submission, feedback, pipelineHandoff
    case prerequisite(MergeRequestBlocker)

    var title: LocalizedStringResource {
        switch self {
        case .context: .MergeActions.mergeActionsContextChanged
        case .checking: .MergeActions.mergeActionsChecking
        case .capability: .MergeActions.mergeActionsUnavailable
        case .submission: .MergeActions.mergeActionsChanged
        case .feedback: .MergeActions.mergeActionsFeedback
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
        if requiresDiscussionRecheck { return .feedback }
        if needsDiscussion || hasOtherUnresolvedDiscussions { return .prerequisite(.discussions) }
        if !feedback.isEmpty { return .feedback }
        if needsChanges { return .prerequisite(.changesRequested) }
        if hasConflict { return .prerequisite(.conflicts) }
        if failedPipeline { return .prerequisite(.pipeline) }
        if needsPipelineHandoff { return .pipelineHandoff }
        if let feedback = authorFeedbackStatus,
           feedback.phase != .complete || feedback.needsAttention || feedback.head != request.sha
            || feedback.fingerprint != observedDiscussionFingerprint
            || feedback.semanticContextFingerprint != request.semanticContextFingerprint { return .feedback }
        guard status.mayMergeManually else {
            return .prerequisite(status.blockers.first ?? .unknown)
        }
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
