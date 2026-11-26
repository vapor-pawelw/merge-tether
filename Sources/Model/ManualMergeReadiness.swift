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

struct ManualFeedbackRecovery: Equatable {
    let blocker: ManualMergeFeedbackBlocker
    let replySourceIDs: [Int]
    var recoveryAction: ManualMergeFeedbackBlocker.RecoveryAction? { blocker.recoveryAction }
}

extension MergeRequestAttentionMonitor.Item {
    func manualFeedbackRecovery() -> ManualFeedbackRecovery? {
        guard isAuthored, let request = mergeRequest, request.isOpen,
              request.webURL == url, request.projectID == id.projectID, request.iid == id.iid else { return nil }
        let feedbackBlocker = mergeFeedbackBlocker(for: request)
            ?? (verifiedFeedback.outstandingNotes.isEmpty ? nil : .unverifiedComments)
        guard let blocker = feedbackBlocker else { return nil }
        let replyIDs: [Int]
        if blocker == .reply, let status = authorFeedbackStatus {
            replyIDs = Set(status.replyNoteIDs.map { rootID in
                status.findings.first(where: { $0.id == rootID })?.sourceNoteID ?? rootID
            }).filter { $0 > 0 }.sorted()
        } else { replyIDs = [] }
        return .init(blocker: blocker, replySourceIDs: replyIDs)
    }

    func canOfferManualMerge(using status: AuthoredMergeRequestStatus) -> Bool {
        manualMergeBlocker(using: status) == nil
    }

    func manualMergeBlocker(using status: AuthoredMergeRequestStatus?) -> ManualMergeBlocker? {
        guard let request = mergeRequest, isAuthored else { return .context }
        guard let status else { return .checking }
        guard request.webURL == url, request.projectID == id.projectID, request.iid == id.iid,
              status.matchesCurrentRequest(request) else { return .context }
        guard !request.hasQueuedMerge else { return .submission }
        guard status.submissionState == .none else {
            if status.waitsForApprovalsAfterQueueDeparture, let action = status.action {
                return catalogMergeBlocker(request, action: action) ?? .prerequisite(.approvals)
            }
            return .submission
        }
        guard let action = status.action else { return .capability }
        if let blocker = catalogMergeBlocker(request, action: action) { return blocker }
        if requiresCommentReview || !drafts.isEmpty { return .prerequisite(.commentReview) }
        if let reason = mergeFeedbackBlocker(for: request) { return .feedback(reason) }
        let verified = verifiedFeedback
        if !verified.outstandingNotes.isEmpty { return .feedback(.unverifiedComments) }
        if verified.discussionsRemainOpen || hasOtherUnresolvedDiscussions { return .prerequisite(.discussions) }
        if verified.changesRemainRequested { return .prerequisite(.changesRequested) }
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
        guard request.isOpen else { return .context }
        if request.draft == true { return .prerequisite(.draft) }
        if request.canMerge == false { return .prerequisite(.permissions) }
        if request.hasMergeConflict { return .prerequisite(.conflicts) }
        if request.mergeTrainEvidenceUnavailable { return .prerequisite(.unknown) }
        if request.blockingDiscussionsResolved == false { return .prerequisite(.discussions) }
        // List responses omit user permissions and pipeline details. The exact-context
        // authored status supplies those checks; explicit newer catalog blockers still veto.
        if let pipeline = request.headPipeline, pipeline.status != .success,
           !(action == .enqueue && [.created, .pending, .running, .preparing, .waitingForResource].contains(pipeline.status)) {
            return .prerequisite(.pipeline)
        }
        switch request.detailedMergeStatus {
        case nil, .mergeable: return nil
        case .ciStillRunning where action == .enqueue: return nil
        case .draftStatus: return .prerequisite(.draft)
        case .notApproved: return .prerequisite(.approvals)
        case .requestedChanges: return .prerequisite(.changesRequested)
        case .discussionsNotResolved: return .prerequisite(.discussions)
        case .ciMustPass, .ciStillRunning, .securityPolicyPipelineCheck, .statusChecksMustPass:
            return .prerequisite(.pipeline)
        case .approvalsSyncing, .checking, .preparing, .unchecked: return .prerequisite(.checking)
        // GitLab reports this status only for unmerged merge request dependencies.
        case .mergeRequestBlocked: return .prerequisite(.dependencies)
        default: return .prerequisite(.other)
        }
    }
}

/// The checked merge decision used by Mac controls and by the phone snapshot.
struct MRManualMergePresentation {
    let status: AuthoredMergeRequestStatus?
    let blocker: ManualMergeBlocker?
    let action: MergeSubmissionAction?
    let hasDiscussionBlock: Bool
    let feedbackRecovery: ManualFeedbackRecovery?
    let hasCurrentCatalog: Bool
    let evidenceMatchesCatalogContext: Bool

    static func candidate(for item: MergeRequestAttentionMonitor.Item,
                          in statuses: [AuthoredMergeRequestStatus]) -> AuthoredMergeRequestStatus? {
        guard let request = item.mergeRequest else { return nil }
        return statuses.first { $0.matchesCurrentRequest(request) }
            ?? statuses.first { $0.id == item.id }
    }

    init(item: MergeRequestAttentionMonitor.Item, candidate: AuthoredMergeRequestStatus?,
         evidenceMatchesCatalogContext: Bool, hasCurrentCatalog: Bool) {
        self.hasCurrentCatalog = hasCurrentCatalog
        self.evidenceMatchesCatalogContext = evidenceMatchesCatalogContext
        let current = evidenceMatchesCatalogContext && hasCurrentCatalog
        let request = item.mergeRequest
        status = current && request?.webURL == item.url
            && request.map { candidate?.matchesCurrentRequest($0) == true } == true ? candidate : nil

        if !evidenceMatchesCatalogContext {
            blocker = .context
        } else if !hasCurrentCatalog {
            blocker = .checking
        } else if candidate != nil && status == nil {
            blocker = .context
        } else {
            blocker = item.manualMergeBlocker(using: status)
        }
        let owned = item.isAuthored && request?.isOpen == true
        action = owned && blocker == nil && item.reReviewReadiness?.hasConcreteConcerns != true ? status?.action : nil
        hasDiscussionBlock = status?.blockers.contains(.discussions) == true || request?.blockingDiscussionsResolved == false
        feedbackRecovery = current ? item.manualFeedbackRecovery() : nil
    }
}
