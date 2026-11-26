protocol GitLabStringValue: Codable, Hashable, Sendable {
    init(rawValue: String)
    var rawValue: String { get }
}

extension GitLabStringValue {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum GitLabMergeRequestState: GitLabStringValue {
    case opened
    case closed
    case merged
    case locked
    case reopened
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "opened": self = .opened
        case "closed": self = .closed
        case "merged": self = .merged
        case "locked": self = .locked
        case "reopened": self = .reopened
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .opened: "opened"
        case .closed: "closed"
        case .merged: "merged"
        case .locked: "locked"
        case .reopened: "reopened"
        case .unknown(let value): value
        }
    }
}

enum GitLabDetailedMergeStatus: GitLabStringValue {
    case approvalsSyncing
    case blockedStatus
    case checking
    case ciMustPass
    case ciStillRunning
    case commitsStatus
    case conflict
    case discussionsNotResolved
    case draftStatus
    case externalStatusChecks
    case jiraAssociationMissing
    case lockedLfsFiles
    case lockedPaths
    case mergeable
    case mergeRequestBlocked
    case mergeTime
    case needRebase
    case notApproved
    case notOpen
    case preparing
    case requestedChanges
    case securityPolicyPipelineCheck
    case securityPolicyViolations
    case statusChecksMustPass
    case titleRegex
    case unchecked
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "approvals_syncing": self = .approvalsSyncing
        case "blocked_status": self = .blockedStatus
        case "checking": self = .checking
        case "ci_must_pass": self = .ciMustPass
        case "ci_still_running": self = .ciStillRunning
        case "commits_status": self = .commitsStatus
        case "conflict": self = .conflict
        case "discussions_not_resolved": self = .discussionsNotResolved
        case "draft_status": self = .draftStatus
        case "external_status_checks": self = .externalStatusChecks
        case "jira_association_missing": self = .jiraAssociationMissing
        case "locked_lfs_files": self = .lockedLfsFiles
        case "locked_paths": self = .lockedPaths
        case "mergeable": self = .mergeable
        case "merge_request_blocked": self = .mergeRequestBlocked
        case "merge_time": self = .mergeTime
        case "need_rebase": self = .needRebase
        case "not_approved": self = .notApproved
        case "not_open": self = .notOpen
        case "preparing": self = .preparing
        case "requested_changes": self = .requestedChanges
        case "security_policy_pipeline_check": self = .securityPolicyPipelineCheck
        case "security_policy_violations": self = .securityPolicyViolations
        case "status_checks_must_pass": self = .statusChecksMustPass
        case "title_regex": self = .titleRegex
        case "unchecked": self = .unchecked
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .approvalsSyncing: "approvals_syncing"
        case .blockedStatus: "blocked_status"
        case .checking: "checking"
        case .ciMustPass: "ci_must_pass"
        case .ciStillRunning: "ci_still_running"
        case .commitsStatus: "commits_status"
        case .conflict: "conflict"
        case .discussionsNotResolved: "discussions_not_resolved"
        case .draftStatus: "draft_status"
        case .externalStatusChecks: "external_status_checks"
        case .jiraAssociationMissing: "jira_association_missing"
        case .lockedLfsFiles: "locked_lfs_files"
        case .lockedPaths: "locked_paths"
        case .mergeable: "mergeable"
        case .mergeRequestBlocked: "merge_request_blocked"
        case .mergeTime: "merge_time"
        case .needRebase: "need_rebase"
        case .notApproved: "not_approved"
        case .notOpen: "not_open"
        case .preparing: "preparing"
        case .requestedChanges: "requested_changes"
        case .securityPolicyPipelineCheck: "security_policy_pipeline_check"
        case .securityPolicyViolations: "security_policy_violations"
        case .statusChecksMustPass: "status_checks_must_pass"
        case .titleRegex: "title_regex"
        case .unchecked: "unchecked"
        case .unknown(let value): value
        }
    }
}

enum GitLabPipelineStatus: GitLabStringValue {
    case canceled
    case created
    case failed
    case manual
    case pending
    case preparing
    case running
    case scheduled
    case skipped
    case success
    case waitingForResource
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "canceled": self = .canceled
        case "created": self = .created
        case "failed": self = .failed
        case "manual": self = .manual
        case "pending": self = .pending
        case "preparing": self = .preparing
        case "running": self = .running
        case "scheduled": self = .scheduled
        case "skipped": self = .skipped
        case "success": self = .success
        case "waiting_for_resource": self = .waitingForResource
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .canceled: "canceled"
        case .created: "created"
        case .failed: "failed"
        case .manual: "manual"
        case .pending: "pending"
        case .preparing: "preparing"
        case .running: "running"
        case .scheduled: "scheduled"
        case .skipped: "skipped"
        case .success: "success"
        case .waitingForResource: "waiting_for_resource"
        case .unknown(let value): value
        }
    }
}

enum GitLabReviewerState: GitLabStringValue {
    case approved
    case requestedChanges
    case reviewStarted
    case reviewed
    case unapproved
    case unreviewed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "approved": self = .approved
        case "requested_changes": self = .requestedChanges
        case "review_started": self = .reviewStarted
        case "reviewed": self = .reviewed
        case "unapproved": self = .unapproved
        case "unreviewed": self = .unreviewed
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .approved: "approved"
        case .requestedChanges: "requested_changes"
        case .reviewStarted: "review_started"
        case .reviewed: "reviewed"
        case .unapproved: "unapproved"
        case .unreviewed: "unreviewed"
        case .unknown(let value): value
        }
    }
}
