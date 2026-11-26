import Foundation

enum MergeRequestBlocker: Hashable {
    case draft
    case unpublishedDrafts
    case commentReview
    case approvals
    case changesRequested
    case discussions
    case discussionPolicy
    case dependencies
    case stackTarget
    case dependencyEvidence
    case conflictTaskFailed
    case conflicts
    case pipeline
    case permissions
    case checking
    case other
    case unknown
}

struct AuthoredMergeRequestStatus: Identifiable {
    let request: GitLabMergeRequest
    let blockers: [MergeRequestBlocker]
    let mayAutoMerge: Bool
    let mayMergeManually: Bool
    let action: MergeSubmissionAction?
    var submissionState: MergeSubmissionState
    let queueHasEnded: Bool
    let dependencyReadiness: MergeRequestDependencySummary.MergeReadiness

    var id: GitLabMergeRequestID { request.mergeRequestID }

    var waitsForApprovalsAfterQueueDeparture: Bool {
        queueHasEnded && submissionState == .changed && request.headPipeline?.status == .success && blockers == [.approvals]
    }

    var displayedSubmissionState: MergeSubmissionState {
        waitsForApprovalsAfterQueueDeparture ? .none : submissionState
    }

    var automaticMergePolicyHold: LocalizedStringResource? {
        if blockers.contains(.discussionPolicy) { return .MergeActions.mergeActionsAutomaticDiscussionPolicy }
        return nil
    }

    func matchesCurrentRequest(_ current: GitLabMergeRequest) -> Bool {
        MergeRequestDependencySummary.Context(request) == .init(current)
            && request.evidenceContext().binds(to: current.evidenceContext(), policy: .semanticText)
            && request.draft == current.draft && request.author.id == current.author.id
            && request.author.username == current.author.username
            && request.assigneeIdentities == current.assigneeIdentities
    }

    static func orderedForMerge(_ statuses: [Self]) -> [Self] {
        statuses.sorted { $0.mergeOrder < $1.mergeOrder }
    }

    private var mergeOrder: (priority: Int, blockers: Int) {
        if blockers.contains(.draft) { return (3, 0) }
        if blockers.allSatisfy({ $0 == .discussionPolicy }) { return (0, blockers.count) }
        let needsAction = blockers.contains { blocker in
            switch blocker {
            case .changesRequested, .discussions, .conflicts, .conflictTaskFailed:
                true
            case .pipeline:
                [.failed, .canceled, .manual].contains(request.headPipeline?.status)
            default:
                false
            }
        }
        return (needsAction ? 1 : 2, blockers.count)
    }

    init(
        request: GitLabMergeRequest,
        approvals: GitLabMergeRequestApprovalState?,
        discussionsResolved: Bool?,
        projectRequiresResolvedDiscussions: Bool?,
        autoMergeEnabled: Bool,
        dependencyReadiness: MergeRequestDependencySummary.MergeReadiness = .unavailable,
        conflictTaskFailed: Bool = false,
        pendingDraftCount: Int? = 0,
        requiresCommentReview: Bool = false,
        action: MergeSubmissionAction? = .mergeNow,
        submissionState: MergeSubmissionState = .none,
        queueHasEnded: Bool = false
    ) {
        self.action = action
        self.submissionState = submissionState
        self.queueHasEnded = queueHasEnded
        self.request = request
        self.dependencyReadiness = dependencyReadiness
        var blockers: [MergeRequestBlocker] = []

        if request.isDraft { blockers.append(.draft) }
        if let pendingDraftCount, pendingDraftCount > 0 { blockers.append(.unpublishedDrafts) }
        if requiresCommentReview { blockers.append(.commentReview) }
        if approvals?.allRequiredRulesApproved == false || request.detailedMergeStatus == .notApproved {
            blockers.append(.approvals)
        }
        if request.detailedMergeStatus == .requestedChanges { blockers.append(.changesRequested) }
        if discussionsResolved == false || request.detailedMergeStatus == .discussionsNotResolved {
            blockers.append(.discussions)
        }
        if request.hasMergeConflict { blockers.append(.conflicts) }
        if request.canMerge == false { blockers.append(.permissions) }

        let canQueuePipeline = action == .enqueue && request.isReadyForMergeSubmission(.enqueue)
        switch request.detailedMergeStatus {
        case .ciMustPass, .ciStillRunning, .securityPolicyPipelineCheck, .statusChecksMustPass:
            if !canQueuePipeline { blockers.append(.pipeline) }
        case .approvalsSyncing, .checking, .preparing, .unchecked:
            blockers.append(.checking)
        case .mergeable, .draftStatus, .notApproved, .requestedChanges, .discussionsNotResolved, .conflict:
            break
        case nil:
            break
        default:
            blockers.append(.other)
        }

        if let pipeline = request.headPipeline, pipeline.status != .success, !canQueuePipeline, !blockers.contains(.pipeline) {
            blockers.append(.pipeline)
        }

        if pendingDraftCount == nil || approvals == nil || discussionsResolved == nil || request.canMerge == nil
            || request.mergeTrainEvidenceUnavailable
            || request.draft == nil || request.detailedMergeStatus == nil
            || (request.detailedMergeStatus == .mergeable && (request.sha == nil || request.hasConflicts == nil)) {
            blockers.append(.unknown)
        }

        var dependenciesReady = false
        do {
            switch dependencyReadiness {
            case .notChecked: break
            case .ready: dependenciesReady = true
            case .waitingForDependencies: blockers.append(.dependencies)
            case .reviewStackTarget: blockers.append(.stackTarget)
            case .unavailable: blockers.append(.dependencyEvidence)
            }
        }
        let ready = action.map { request.isReadyForMergeSubmission($0) } == true && submissionState == .none
        self.mayMergeManually = dependenciesReady && blockers.isEmpty && ready && approvals?.allRequiredRulesApproved == true && discussionsResolved == true
        let eligibleForAutoMerge = autoMergeEnabled && mayMergeManually
        if eligibleForAutoMerge && projectRequiresResolvedDiscussions != true {
            blockers.append(.discussionPolicy)
        }

        if conflictTaskFailed && request.hasMergeConflict {
            blockers.append(.conflictTaskFailed)
        }

        self.blockers = blockers
        self.mayAutoMerge = eligibleForAutoMerge && projectRequiresResolvedDiscussions == true
    }
}

extension GitLabMergeRequest {
    var hasMergeConflict: Bool {
        hasConflicts == true || detailedMergeStatus == .conflict || mergeTrainConflict?.matches(self) == true
    }

    var isReadyForMergeChecks: Bool {
        isOpen && draft == false && detailedMergeStatus == .mergeable
            && hasConflicts == false && !hasMergeConflict && !mergeTrainEvidenceUnavailable && canMerge == true && sha != nil
            && (headPipeline == nil || headPipeline?.status == .success)
    }
}

struct MergeConflictReceipt: Codable, Hashable {
    let host: String
    let userID: Int
    let projectID: Int
    let iid: Int
    let sourceSHA: String
    let targetSHA: String
    var allowsPush: Bool? = nil
    var jobID: UUID? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host && lhs.userID == rhs.userID && lhs.projectID == rhs.projectID
            && lhs.iid == rhs.iid && lhs.sourceSHA == rhs.sourceSHA && lhs.targetSHA == rhs.targetSHA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host); hasher.combine(userID); hasher.combine(projectID)
        hasher.combine(iid); hasher.combine(sourceSHA); hasher.combine(targetSHA)
    }

    func matches(_ request: GitLabMergeRequest, host: String, userID: Int) -> Bool {
        self.host == host && self.userID == userID && projectID == request.projectID && iid == request.iid
    }
}
