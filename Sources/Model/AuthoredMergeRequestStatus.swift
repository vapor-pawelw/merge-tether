import Foundation

enum MergeRequestBlocker: Hashable {
    case draft
    case unpublishedDrafts
    case commentReview
    case approvals
    case changesRequested
    case discussions
    case discussionPolicy
    case approvalPolicy
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
    let dependencyReadiness: MergeRequestDependencySummary.MergeReadiness

    var id: String { "\(request.projectID)!\(request.iid)" }

    static func orderedForMerge(_ statuses: [Self]) -> [Self] {
        statuses.sorted { $0.mergeOrder < $1.mergeOrder }
    }

    private var mergeOrder: (priority: Int, blockers: Int) {
        if blockers.contains(.draft) { return (3, 0) }
        if blockers.allSatisfy({ $0 == .approvalPolicy || $0 == .discussionPolicy }) { return (0, blockers.count) }
        let needsAction = blockers.contains { blocker in
            switch blocker {
            case .changesRequested, .discussions, .conflicts, .conflictTaskFailed:
                true
            case .pipeline:
                ["failed", "canceled", "manual"].contains(request.headPipeline?.status ?? "")
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
        canVerifyFreshApprovals: Bool = true,
        conflictTaskFailed: Bool = false,
        pendingDraftCount: Int? = 0,
        requiresCommentReview: Bool = false
    ) {
        self.request = request
        self.dependencyReadiness = dependencyReadiness
        var blockers: [MergeRequestBlocker] = []

        if request.draft == true || request.detailedMergeStatus == "draft_status" { blockers.append(.draft) }
        if let pendingDraftCount, pendingDraftCount > 0 { blockers.append(.unpublishedDrafts) }
        if requiresCommentReview { blockers.append(.commentReview) }
        if approvals?.allRequiredRulesApproved == false || request.detailedMergeStatus == "not_approved" {
            blockers.append(.approvals)
        }
        if request.detailedMergeStatus == "requested_changes" { blockers.append(.changesRequested) }
        if discussionsResolved == false || request.detailedMergeStatus == "discussions_not_resolved" {
            blockers.append(.discussions)
        }
        if request.hasMergeConflict { blockers.append(.conflicts) }
        if request.canMerge == false { blockers.append(.permissions) }

        switch request.detailedMergeStatus {
        case "ci_must_pass", "ci_still_running", "security_policy_pipeline_check", "status_checks_must_pass":
            blockers.append(.pipeline)
        case "approvals_syncing", "checking", "preparing", "unchecked":
            blockers.append(.checking)
        case "mergeable", "draft_status", "not_approved", "requested_changes", "discussions_not_resolved", "conflict":
            break
        case nil:
            break
        default:
            blockers.append(.other)
        }

        if let pipeline = request.headPipeline, pipeline.status != "success", !blockers.contains(.pipeline) {
            blockers.append(.pipeline)
        }

        if pendingDraftCount == nil || approvals == nil || discussionsResolved == nil || request.canMerge == nil
            || request.draft == nil || request.detailedMergeStatus == nil
            || (request.detailedMergeStatus == "mergeable" && (request.sha == nil || request.hasConflicts == nil)) {
            blockers.append(.unknown)
        }

        if autoMergeEnabled {
            switch dependencyReadiness {
            case .ready: break
            case .waitingForDependencies: blockers.append(.dependencies)
            case .reviewStackTarget: blockers.append(.stackTarget)
            case .unavailable: blockers.append(.dependencyEvidence)
            }
        }
        let eligibleForAutoMerge = autoMergeEnabled && blockers.isEmpty && request.isReadyForMergeChecks
            && approvals?.hasRequiredRules == true && approvals?.allRequiredRulesApproved == true
            && discussionsResolved == true
        if eligibleForAutoMerge && projectRequiresResolvedDiscussions != true {
            blockers.append(.discussionPolicy)
        }

        if eligibleForAutoMerge && !canVerifyFreshApprovals {
            blockers.append(.approvalPolicy)
        }
        if conflictTaskFailed && request.hasMergeConflict {
            blockers.append(.conflictTaskFailed)
        }

        self.blockers = blockers
        self.mayAutoMerge = eligibleForAutoMerge && projectRequiresResolvedDiscussions == true
            && canVerifyFreshApprovals
    }
}

extension GitLabMergeRequest {
    var hasMergeConflict: Bool { hasConflicts == true || detailedMergeStatus == "conflict" }

    var isReadyForMergeChecks: Bool {
        state == "opened" && draft == false && detailedMergeStatus == "mergeable"
            && hasConflicts == false && canMerge == true && sha != nil
            && (headPipeline == nil || headPipeline?.status == "success")
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
