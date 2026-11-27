import Foundation

enum MergeWorkflowTrigger: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case pipelineFailure
    case reviewUpdate
    case newDiscussion
    case blockerChange
    case stackDependencyMerged
    case reviewWaiting

    var id: String { rawValue }
}

enum ReviewLaunchReason: String, Codable, Sendable {
    case headChanged, authorReplied, discussionsChanged, discussionCoverageMissing
    case metadataChanged, metadataCoverageMissing, targetChanged, pushedDuringReview
    case automaticRetry, unverifiedReview
    case reviewRequested, approvalRequested, noVerifiedReview, manualReview, fullReview, retryReview, reasonUnavailable

    private var label: LocalizedStringResource {
        switch self {
        case .headChanged: .AutomationProgress.reviewReasonHeadChanged
        case .authorReplied: .AutomationProgress.reviewReasonAuthorReplied
        case .discussionsChanged: .AutomationProgress.reviewReasonDiscussionsChanged
        case .discussionCoverageMissing: .AutomationProgress.reviewReasonDiscussionCoverageMissing
        case .metadataChanged: .AutomationProgress.reviewReasonMetadataChanged
        case .metadataCoverageMissing: .AutomationProgress.reviewReasonMetadataCoverageMissing
        case .targetChanged: .AutomationProgress.reviewReasonTargetChanged
        case .pushedDuringReview: .AutomationProgress.reviewReasonPushedDuringReview
        case .automaticRetry: .AutomationProgress.reviewReasonAutomaticRetry
        case .unverifiedReview: .AutomationProgress.reviewReasonUnverifiedReview
        case .reviewRequested: .ReviewingContext.reviewingReviewRequested
        case .approvalRequested: .ReviewingContext.reviewingApprovalRequested
        case .noVerifiedReview: .AutomationProgress.reviewReasonNoVerifiedReview
        case .manualReview: .AutomationProgress.reviewReasonManualReview
        case .fullReview: .AutomationProgress.reviewReasonFullReview
        case .retryReview: .AutomationProgress.reviewReasonRetryReview
        case .reasonUnavailable: .AutomationProgress.reviewReasonUnavailable
        }
    }

    static func message(for reasons: [Self]) -> String? {
        guard !reasons.isEmpty else { return nil }
        return reasons.map { String(localized: $0.label) }.joined(separator: " · ")
    }

    static func requestReason(for action: ActionName?) -> Self? {
        switch action {
        case .reviewRequested: .reviewRequested
        case .approvalRequired: .approvalRequested
        default: nil
        }
    }
}

struct MergeWorkflowEvent: Codable, Sendable {
    let kind: MergeWorkflowTrigger
    let mergeRequest: GitLabMergeRequest
    let identity: String
    let context: String
    var pipelineProjectID: Int? = nil
    var pipelineID: Int? = nil
    var jobID: Int? = nil
    var isInfrastructureFailure = false
    var noteIDs: [Int] = []
    var failedPipelineJobIDs: [Int]? = nil
    var leftMergeTrain: Bool? = nil
    var reviewUpdateReasons: [ReviewLaunchReason]? = nil

    var blockerDiagnosis: MergeBlockerDiagnosis? {
        guard kind == .blockerChange else { return nil }
        return .init(request: mergeRequest, leftMergeTrain: leftMergeTrain == true)
    }

    var blockerExplanation: LocalizedStringResource? {
        guard kind == .blockerChange, leftMergeTrain != true else { return nil }
        switch mergeRequest.detailedMergeStatus {
        case .ciMustPass: return .MergeActions.mergeActionsPipeline
        case .commitsStatus: return .Menu.menuWorkflowBlockerCommits
        case .conflict: return .MergeActions.mergeActionsConflicts
        case .discussionsNotResolved: return .MergeActions.mergeActionsDiscussions
        case .draftStatus: return .MergeActions.mergeActionsDraft
        case .jiraAssociationMissing: return .Menu.menuWorkflowBlockerJira
        case .mergeable: return .Menu.menuWorkflowBlockerMergeable
        case .mergeTime: return .Menu.menuWorkflowBlockerMergeTime
        case .needRebase: return .Menu.menuWorkflowBlockerRebase
        case .notApproved: return .MergeActions.mergeActionsApprovals
        case .requestedChanges: return .MergeActions.mergeActionsChangesRequested
        case .statusChecksMustPass: return .Menu.menuWorkflowBlockerStatusChecks
        case .titleRegex: return .Menu.menuWorkflowBlockerTitle
        default: return nil
        }
    }
}

/// Identifies the same diagnostic independently of the number of events GitLab reports.
struct MergeBlockerDiagnosis: Codable, Equatable, Sendable {
    struct Superseded: Error {}

    private static let diagnosticStatuses: Set<GitLabDetailedMergeStatus> = [
        .blockedStatus, .externalStatusChecks, .mergeRequestBlocked,
        .securityPolicyViolations, .lockedPaths, .lockedLfsFiles
    ]
    private static let checkingStatuses: Set<GitLabDetailedMergeStatus> = [.approvalsSyncing, .checking, .preparing, .unchecked]

    let leftMergeTrain: Bool
    private let status: GitLabDetailedMergeStatus?
    private let head: String
    private let sourceProjectID: Int?
    private let sourceBranch: String
    private let targetProjectID: Int?
    private let targetBranch: String
    private let targetBase: String?
    private let diffStart: String?
    private let trainPipelineID: Int?

    init?(request: GitLabMergeRequest, leftMergeTrain: Bool) {
        let status = request.detailedMergeStatus
        guard let head = request.sha, GlabService.isFullGitSHA(head),
              leftMergeTrain || status.map(Self.diagnosticStatuses.contains) == true else { return nil }
        self.leftMergeTrain = leftMergeTrain
        self.status = leftMergeTrain ? nil : status
        self.head = head
        sourceProjectID = request.sourceProjectID
        sourceBranch = request.sourceBranch
        targetProjectID = request.targetProjectID
        targetBranch = request.targetBranch
        targetBase = request.diffRefs?.baseSHA
        diffStart = request.diffRefs?.startSHA
        trainPipelineID = leftMergeTrain ? request.headPipeline?.id : nil
    }

    func validate(_ request: GitLabMergeRequest) throws {
        guard request.isOpen, head == request.sha, sourceBranch == request.sourceBranch,
              targetBranch == request.targetBranch,
              Self.compatible(sourceProjectID, request.sourceProjectID),
              Self.compatible(targetProjectID, request.targetProjectID),
              Self.compatible(targetBase, request.diffRefs?.baseSHA),
              Self.compatible(diffStart, request.diffRefs?.startSHA),
              Self.compatible(trainPipelineID, request.headPipeline?.id) else { throw Superseded() }
        guard Self.matches(sourceProjectID, request.sourceProjectID),
              Self.matches(targetProjectID, request.targetProjectID),
              Self.matches(targetBase, request.diffRefs?.baseSHA),
              Self.matches(diffStart, request.diffRefs?.startSHA),
              Self.matches(trainPipelineID, request.headPipeline?.id) else {
            throw AssistantJobExecutor.ExecutionError.contextUnavailable
        }
        if !leftMergeTrain {
            guard let currentStatus = request.detailedMergeStatus, !Self.checkingStatuses.contains(currentStatus) else {
                throw AssistantJobExecutor.ExecutionError.contextUnavailable
            }
            guard status == currentStatus else { throw Superseded() }
        }
    }

    func isEquivalent(to other: Self) -> Bool {
        leftMergeTrain == other.leftMergeTrain && status == other.status && head == other.head
            && sourceBranch == other.sourceBranch && targetBranch == other.targetBranch
            && Self.compatible(sourceProjectID, other.sourceProjectID)
            && Self.compatible(targetProjectID, other.targetProjectID)
            && Self.compatible(targetBase, other.targetBase)
            && Self.compatible(diffStart, other.diffStart)
            && Self.compatible(trainPipelineID, other.trainPipelineID)
    }

    private static func matches<Value: Equatable>(_ expected: Value?, _ actual: Value?) -> Bool {
        expected == nil || expected == actual
    }

    // A list response can omit evidence present on the single-MR response.
    // An omitted value alone does not make a repeated event new work.
    private static func compatible<Value: Equatable>(_ first: Value?, _ second: Value?) -> Bool {
        first == nil || second == nil || first == second
    }
}

struct GitLabMergeRequestReviewer: Decodable, Sendable {
    let user: GitLabWorkflowUser
    let state: GitLabReviewerState
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case user, state
        case createdAt = "created_at"
    }
}

struct GitLabWorkflowUser: Codable, Sendable {
    let id: Int
    let username: String?
    let name: String?
    var avatarURL: URL? = nil

    enum CodingKeys: String, CodingKey { case id, username, name; case avatarURL = "avatar_url" }
    var author: Todo.Author? {
        guard id > 0, let username, !username.isEmpty else { return nil }
        return .init(id: id, username: username, name: name ?? username, avatarURL: avatarURL)
    }
}

struct GitLabMergeRequestDiscussion: Codable, Sendable {
    var id: String? = nil
    let notes: [Note]

    struct Note: Codable, Sendable {
        let id: Int?
        let author: GitLabWorkflowUser?
        let system: Bool?
        let resolvable: Bool?
        let resolved: Bool?
        let resolvedBy: GitLabWorkflowUser?
        var body: String? = nil
        var createdAt: String? = nil
        var updatedAt: String? = nil
        var position: GitLabDraftNote.Position? = nil

        enum CodingKeys: String, CodingKey {
            case id, author, system, resolvable, resolved, body, position
            case resolvedBy = "resolved_by"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    var reviewRoot: Note? { notes.first { $0.system != true } }
    var isResolvedForReview: Bool { reviewRoot?.resolved == true }

    static func activeForReview(_ discussions: [Self]) -> [Self] {
        discussions.filter { !$0.isResolvedForReview }
    }

    static func allConfirmedResolved(_ discussions: [Self]) -> Bool {
        discussions.allSatisfy { discussion in
            !discussion.notes.isEmpty && discussion.notes.allSatisfy {
                $0.resolvable == false || ($0.resolvable == true && $0.resolved == true)
            }
        }
    }

    /// Other human-visible participants, in thread order, for showing who a reply answers.
    func replyRecipients(excluding userID: Int) -> [PersonIdentity] {
        var seen: Set<String> = []
        return notes.compactMap { note -> PersonIdentity? in
            guard note.system != true, let author = note.author, author.id != userID else { return nil }
            let person = author.person
            guard let key = person.normalizedUsername?.lowercased(), seen.insert(key).inserted else { return nil }
            return person
        }
    }

    /// Positive evidence that no agent work remains for the selected notes: every note exists, sits in a
    /// resolvable thread and that thread is resolved. A missing, non-resolvable or unknown-state note is
    /// never treated as settled, so a partial read can only keep work, not drop it.
    static func allResolved(_ noteIDs: Set<Int>, in discussions: [Self]) -> Bool {
        guard !noteIDs.isEmpty else { return false }
        return noteIDs.allSatisfy { id in
            guard let discussion = discussions.first(where: { $0.notes.contains { $0.id == id } }),
                  let note = discussion.notes.first(where: { $0.id == id }), note.resolvable == true else { return false }
            return discussion.isResolvedForReview
        }
    }

    static func unresolvedFeedback(in discussions: [Self], excluding userID: Int) -> [Note] {
        activeForReview(discussions).flatMap(\.notes).filter {
            guard let id = $0.id, id > 0, let author = $0.author, author.id > 0 else { return false }
            return author.id != userID && $0.system == false && $0.resolvable == true && $0.resolved == false
        }
    }
}

struct ReReviewFeedback: Sendable {
    var hasUnansweredFeedback = false
    var addressedByReviewer: [Int: Int] = [:]
    var addressedNotes: Set<Int> = []
    var latestPublishedReplyID = 0

    init(discussions: [GitLabMergeRequestDiscussion], authorID: Int) {
        for discussion in discussions {
            guard !discussion.isResolvedForReview else { continue }
            let comments = discussion.notes.filter { $0.system == false }
            let latestReply = comments.filter { $0.author?.id == authorID }.compactMap(\.id).max() ?? 0
            for note in comments {
                guard note.author?.id != authorID else { continue }
                guard let id = note.id, id > 0, let reviewer = note.author?.id, reviewer > 0 else {
                    hasUnansweredFeedback = true
                    continue
                }
                let addressed = latestReply > id || (note.resolved == true && note.resolvedBy?.id == authorID)
                if addressed {
                    if latestReply > id { latestPublishedReplyID = max(latestPublishedReplyID, latestReply) }
                    addressedNotes.insert(id)
                    addressedByReviewer[reviewer] = max(addressedByReviewer[reviewer] ?? 0, id)
                } else if note.resolvable == true && note.resolved != true {
                    hasUnansweredFeedback = true
                }
            }
        }
    }
}

struct MergeRequestReviewHistory: Equatable, Sendable {
    struct Activity: Equatable, Sendable {
        var author: Todo.Author?
        var previouslyApproved = false
        var commented = false
        var noteID = 0
        var changedAt: Date?
    }
    var activities: [Int: Activity] = [:]

    init(reviewers: [GitLabMergeRequestReviewer] = [], discussions: [GitLabMergeRequestDiscussion] = [], authorID: Int = 0) {
        for reviewer in reviewers where reviewer.user.id > 0 && reviewer.user.id != authorID {
            activities[reviewer.user.id] = Activity(author: reviewer.user.author,
                previouslyApproved: reviewer.state == .unapproved || reviewer.state == .approved,
                changedAt: Self.date(reviewer.createdAt))
        }
        let notes = discussions.flatMap(\.notes)
        for note in notes {
            guard let id = note.id, id > 0, let user = note.author, user.id > 0, user.id != authorID else { continue }
            let approval = note.system == true && note.body.map { ["approved this merge request", "unapproved this merge request"].contains($0) } == true
            let comment = note.system == false || (note.system == true && note.body == "left review comments")
            guard approval || comment else { continue }
            var activity = activities[user.id] ?? Activity()
            activity.author = activity.author ?? user.author
            activity.previouslyApproved = activity.previouslyApproved || approval
            activity.commented = activity.commented || comment
            activity.noteID = max(activity.noteID, id)
            activity.changedAt = [activity.changedAt, Self.date(note.createdAt), Self.date(note.updatedAt)].compactMap { $0 }.max()
            activities[user.id] = activity
        }
        // GitLab attributes reset/request events to the actor, while the changed
        // review status belongs to the mentioned reviewers.
        for note in notes where note.system == true {
            guard let body = note.body,
                  body.hasPrefix("reset approvals from @") || body.hasPrefix("requested review from @")
                    || body.hasPrefix("removed review request for @") else { continue }
            let handles = Set(body.split { !(($0.isLetter || $0.isNumber) || "@_.-".contains($0)) }
                .filter { $0.hasPrefix("@") }.map { String($0.dropFirst()) })
            for id in Array(activities.keys) {
                guard let username = activities[id]?.author?.username, handles.contains(username) else { continue }
                guard var activity = activities[id] else { continue }
                if body.hasPrefix("reset approvals from @") { activity.previouslyApproved = true }
                activity.changedAt = [activity.changedAt, Self.date(note.createdAt)].compactMap { $0 }.max()
                activities[id] = activity
            }
        }
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

struct ReReviewReceipt: Codable {
    struct Key: Codable, Hashable {
        let host: String
        let authorID: Int
        let projectID: Int
        let iid: Int
        let reviewerID: Int
    }

    let noteID: Int
    var unconfirmed = false
    var requested: Bool?
    var headSHA: String? = nil
    // An observed head can fence a legacy attempt, but cannot prove the head of the original write.
    var adoptedFenceHeadSHA: String? = nil

    var fenceHeadSHA: String? { headSHA ?? adoptedFenceHeadSHA }

    func covers(noteID: Int, headSHA: String) -> Bool {
        guard self.noteID >= noteID else { return false }
        if unconfirmed {
            // Keep fencing replay until a complete GitLab read supplies a head for the legacy receipt.
            guard let fenceHeadSHA else { return true }
            return EvidenceContext(head: fenceHeadSHA).binds(to: .init(head: headSHA), policy: .uncertainReReviewReceipt)
        }
        return EvidenceContext(head: self.headSHA).binds(to: .init(head: headSHA), policy: .head)
    }
}

struct GitLabPipelineJob: Decodable, Sendable {
    let id: Int
    let status: GitLabPipelineStatus
    let allowFailure: Bool?
    let failureReason: String?

    static func blockingFailureIDs(_ jobs: [Self]) -> [Int] {
        Set(jobs.lazy.filter { $0.status == .failed && $0.id > 0 && $0.allowFailure != true }.map(\.id)).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case allowFailure = "allow_failure"
        case failureReason = "failure_reason"
    }
}
