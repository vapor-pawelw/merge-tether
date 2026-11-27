import Foundation

struct MergeRequestApprovalProgress: Equatable, Sendable {
    let completed: Int
    let required: Int
    let approvedBy: [Todo.Author]
    var requirementsSatisfied: Bool? = nil
    var reviewHistory = MergeRequestReviewHistory()
    var approvalDates: [Int: Date] = [:]
    var currentApproverIDs: Set<Int>? = nil
    var userCanApprove: Bool? = nil
    var isSatisfied: Bool { completed > 0 && (requirementsSatisfied ?? (required == 0 || completed >= required)) }
    init?(completed: Int, required: Int, approvedBy: [Todo.Author] = []) {
        guard required >= 0, completed >= 0 else { return nil }
        self.completed = completed; self.required = required
        self.approvedBy = approvedBy
    }

    struct Participant: Identifiable {
        enum Status: Int { case approved, previouslyApproved, commented, assigned }
        let author: Todo.Author
        let status: Status
        var changedAt: Date? = nil
        var id: Int { author.id }
        var approved: Bool { status == .approved }
    }

    func participants(reviewers: [Todo.Author]) -> [Participant] {
        Self.participants(approvedBy: approvedBy, reviewers: reviewers, history: reviewHistory, approvalDates: approvalDates)
    }

    static func assignedReviewerCount(_ reviewers: [Todo.Author]?) -> Int? {
        reviewers.map { Set($0.map(\.id)).count }
    }

    /// The signed-in reviewer's own approval on someone else's MR. Returns nil for the
    /// viewer's own MR, an unknown viewer, or a viewer who never approved.
    enum ViewerApproval: Equatable {
        case approved(Todo.Author)
        /// Approved earlier, but the approval no longer counts (reset by a push or withdrawn).
        case noLongerCounts(Todo.Author)
        var author: Todo.Author {
            switch self { case .approved(let author), .noLongerCounts(let author): author }
        }
    }

    func viewerApproval(username: String?, reviewers: [Todo.Author], isOwnMergeRequest: Bool) -> ViewerApproval? {
        guard !isOwnMergeRequest,
              let username = username.map({ GitLabAccountIdentity.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              !username.isEmpty,
              let viewer = participants(reviewers: reviewers).first(where: { GitLabAccountIdentity.normalize($0.author.username) == username })
        else { return nil }
        switch viewer.status {
        case .approved: return .approved(viewer.author)
        case .previouslyApproved: return .noLongerCounts(viewer.author)
        case .commented, .assigned: return nil
        }
    }

    static func participants(approvedBy: [Todo.Author] = [], reviewers: [Todo.Author],
                             history: MergeRequestReviewHistory = .init(), approvalDates: [Int: Date] = [:]) -> [Participant] {
        var seen: Set<Int> = []
        let approvedIDs = Set(approvedBy.map(\.id))
        let authors = approvedBy + reviewers + history.activities.values.compactMap(\.author).sorted { $0.id < $1.id }
        let people = authors.filter { $0.id > 0 && seen.insert($0.id).inserted }.map { author in
            let activity = history.activities[author.id]
            let status: Participant.Status = approvedIDs.contains(author.id) ? .approved
                : activity?.previouslyApproved == true ? .previouslyApproved
                : activity?.commented == true ? .commented : .assigned
            return Participant(author: author, status: status,
                changedAt: [approvalDates[author.id], activity?.changedAt].compactMap { $0 }.max())
        }
        return people.enumerated().sorted { lhs, rhs in
            if lhs.element.status != rhs.element.status { return lhs.element.status.rawValue < rhs.element.status.rawValue }
            if lhs.element.changedAt != rhs.element.changedAt {
                return (lhs.element.changedAt ?? .distantPast) > (rhs.element.changedAt ?? .distantPast)
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

struct GitLabMergeRequestApprovalCounts: Decodable, Sendable {
    private let required: Int?
    private let remaining: Int?
    private let projectID: Int?
    private let iid: Int?
    private let approvedBy: [Approver]?
    let userCanApprove: Bool?

    var approverIDs: Set<Int>? { approvedBy.map { Set($0.map(\.user.id).filter { $0 > 0 }) } }

    private struct Approver: Decodable, Sendable {
        let user: User
        let approvedAt: String?
        enum CodingKeys: String, CodingKey { case user; case approvedAt = "approved_at" }
        struct User: Decodable, Sendable {
            let id: Int
            let username: String?
            let name: String?
            let avatarURL: URL?
            enum CodingKeys: String, CodingKey { case id, username, name; case avatarURL = "avatar_url" }
            var author: Todo.Author? {
                guard id > 0, let username else { return nil }
                return .init(id: id, username: username, name: name ?? username, avatarURL: avatarURL)
            }
        }
    }
    enum CodingKeys: String, CodingKey {
        case required = "approvals_required", remaining = "approvals_left", projectID = "project_id", iid
        case approvedBy = "approved_by"
        case userCanApprove = "user_can_approve"
    }
    func progress(projectID: Int, iid: Int) -> MergeRequestApprovalProgress? {
        guard projectID > 0, iid > 0, self.projectID == nil || self.projectID == projectID,
              self.iid == nil || self.iid == iid else { return nil }
        let requiredCount: Int
        let remainingCount: Int
        if let required, let remaining, required >= 0, remaining >= 0, remaining <= required {
            requiredCount = required
            remainingCount = remaining
        } else if required == nil, remaining == nil, userCanApprove != nil, approvedBy != nil {
            // Community Edition exposes the approvers and eligibility but no required counts.
            requiredCount = 0
            remainingCount = 0
        } else { return nil }
        var result = MergeRequestApprovalProgress(completed: approverIDs?.count ?? requiredCount - remainingCount,
            required: requiredCount, approvedBy: (approvedBy ?? []).compactMap(\.user.author))
        result?.requirementsSatisfied = remainingCount == 0
        result?.currentApproverIDs = approverIDs
        result?.userCanApprove = userCanApprove
        for approver in approvedBy ?? [] {
            guard let date = MergeRequestReviewHistory.date(approver.approvedAt) else { continue }
            let previous = result?.approvalDates[approver.user.id] ?? .distantPast
            result?.approvalDates[approver.user.id] = max(previous, date)
        }
        return result
    }
}

enum PersonalMRApproval: Equatable {
    case approve, remove

    var title: LocalizedStringResource {
        self == .approve ? .Board.boardApprovalsApprove : .Board.boardApprovalsRemove
    }

    var confirmation: LocalizedStringResource {
        self == .approve ? .Board.boardApprovalsApproveHelp : .Board.boardApprovalsRemoveHelp
    }
}

struct GitLabAuthenticatedUser: Codable, Hashable, Sendable {
    let id: Int
    let username: String

    func account(on host: String) -> GitLabAccountIdentity {
        .init(host: host, username: username, userID: id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Evidence for the reviewer's own GitLab approval, used to present review progress.
struct ReviewApprovalBaseline: Codable, Equatable, Sendable {
    let reviewedTarget: ReviewTargetBinding
    let semanticContext: SemanticContextDigest
    let approvedAt: Date

    init?(request: GitLabMergeRequest, approvedAt: Date) {
        guard let reviewedTarget = ReviewTargetBinding(request) else { return nil }
        self.reviewedTarget = reviewedTarget
        self.semanticContext = request.semanticContextDigest
        self.approvedAt = approvedAt
    }

    func covers(_ request: GitLabMergeRequest) -> Bool {
        let current = request.evidenceContext()
        return reviewedTarget.evidenceContext.binds(to: current, policy: .approvalTarget)
            && EvidenceContext(semanticContext: semanticContext).binds(to: current, policy: .semanticText)
    }
}

struct GitLabMergeRequest: Codable, Sendable {
    let projectID: Int
    let iid: Int
    let author: Todo.Author
    let title: String
    let description: String?
    let webURL: URL
    let state: GitLabMergeRequestState
    let draft: Bool?
    let sha: String?
    let sourceProjectID: Int?
    let sourceBranch: String
    let targetProjectID: Int?
    let targetBranch: String
    let detailedMergeStatus: GitLabDetailedMergeStatus?
    let hasConflicts: Bool?
    let labels: [String]
    let blockingDiscussionsResolved: Bool?
    let mergeWhenPipelineSucceeds: Bool?
    let headPipeline: Pipeline?
    let reviewers: [Todo.Author]?
    let assignees: [Todo.Author]?
    private let user: UserPermissions?
    /// Present on single-MR reads only. Approval proof binds the reviewed diff to its base.
    var diffRefs: DiffRefs? = nil
    // Derived live evidence is deliberately excluded from the persisted REST payload.
    var mergeTrainConflict: MergeTrainPreparationConflict? = nil
    var mergeTrainEvidenceUnavailable = false

    var mergeRequestID: GitLabMergeRequestID { .init(projectID: projectID, iid: iid) }
    var isOpen: Bool { state == .opened }
    var isDraft: Bool { isDraft(fallback: false) }

    var displayAssignees: [Todo.Author] {
        guard let assignees, assignees.contains(where: { $0.id != author.id }) else { return [] }
        return assignees
    }

    var assigneeIdentities: Set<GitLabAuthenticatedUser> {
        Set((assignees ?? []).filter { $0.id > 0 }.map { .init(id: $0.id, username: $0.username) })
    }

    func isOwned(by userID: Int, includingAssignee: Bool) -> Bool {
        guard userID > 0 else { return false }
        if includingAssignee, let assignees, !assignees.isEmpty { return assignees.contains { $0.id == userID } }
        return author.id == userID
    }

    func isOwned(by username: String, includingAssignee: Bool) -> Bool {
        ownerID(for: username, includingAssignee: includingAssignee) != nil
    }

    func ownerID(for username: String, includingAssignee: Bool) -> Int? {
        guard !username.isEmpty else { return nil }
        if includingAssignee, let assignees, !assignees.isEmpty {
            return assignees.first { $0.id > 0 && $0.username == username }?.id
        }
        return author.username == username ? author.id : nil
    }

    func hasOtherAssignees(than username: String) -> Bool {
        assignees?.contains { $0.username != username } == true
    }

    func isDraft(fallback: Bool) -> Bool {
        detailedMergeStatus == .draftStatus || (draft ?? fallback)
    }

    var canMerge: Bool? { user?.canMerge }

    /// Semantic feedback checks depend on MR text as well as code and discussions.
    var semanticContextDigest: SemanticContextDigest {
        let body = description ?? ""
        return .init(UserAttentionSnapshot.digest("\(title.utf8.count):\(title)\(body.utf8.count):\(body)"))
    }

    var semanticContextFingerprint: String { semanticContextDigest.rawValue }

    /// A target is usable when GitLab supplied diff refs for this exact source head.
    var evidenceTarget: EvidenceContext.Target? {
        guard let sha, !sha.isEmpty, let targetProjectID, targetProjectID > 0, !targetBranch.isEmpty,
              let diffRefs, diffRefs.headSHA == sha, let base = diffRefs.baseSHA, !base.isEmpty else { return nil }
        return .init(projectID: targetProjectID, branch: targetBranch, base: base)
    }

    func evidenceContext(discussionContent: DiscussionContentDigest? = nil) -> EvidenceContext {
        .init(mergeRequestID: mergeRequestID, head: sha, target: evidenceTarget, discussionContent: discussionContent,
              semanticContext: semanticContextDigest)
    }

    struct DiffRefs: Codable, Equatable, Sendable {
        let baseSHA: String?
        let headSHA: String?
        let startSHA: String?

        enum CodingKeys: String, CodingKey {
            case baseSHA = "base_sha"
            case headSHA = "head_sha"
            case startSHA = "start_sha"
        }
    }

    struct Pipeline: Codable, Sendable {
        let id: Int?
        let projectID: Int?
        let status: GitLabPipelineStatus
        let sha: String?
        var ref: String? = nil

        enum CodingKeys: String, CodingKey {
            case id, status, sha, ref
            case projectID = "project_id"
        }
    }

    private struct UserPermissions: Codable, Sendable {
        let canMerge: Bool?

        enum CodingKeys: String, CodingKey {
            case canMerge = "can_merge"
        }
    }

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case iid, author, title, description
        case webURL = "web_url"
        case state, draft, sha
        case sourceProjectID = "source_project_id"
        case sourceBranch = "source_branch"
        case targetProjectID = "target_project_id"
        case targetBranch = "target_branch"
        case detailedMergeStatus = "detailed_merge_status"
        case hasConflicts = "has_conflicts"
        case labels
        case blockingDiscussionsResolved = "blocking_discussions_resolved"
        case mergeWhenPipelineSucceeds = "merge_when_pipeline_succeeds"
        case headPipeline = "head_pipeline"
        case user, reviewers, assignees
        case diffRefs = "diff_refs"
    }
}

struct GitLabMergeRequestApprovalState: Decodable, Sendable {
    private let rules: [Rule]

    var allRequiredRulesApproved: Bool {
        rules.allSatisfy { $0.approvalsRequired == 0 || ($0.approvalsRequired > 0 && $0.approved == true) }
    }

    private struct Rule: Decodable, Sendable {
        let approvalsRequired: Int
        let approved: Bool?

        enum CodingKeys: String, CodingKey {
            case approvalsRequired = "approvals_required"
            case approved
        }
    }
}

/// One of the current user's unpublished (private) draft notes on a merge request.
struct GitLabDraftNote: Codable, Equatable, Sendable {
    let id: Int?
    let authorID: Int
    let note: String?
    let discussionID: String?
    var resolveDiscussion: Bool? = nil
    let position: Position?

    struct Position: Codable, Equatable, Sendable {
        let newPath: String?
        let newLine: Int?
        let oldPath: String?
        let oldLine: Int?
        var baseSHA: String? = nil
        var headSHA: String? = nil
        var positionType: String? = nil

        enum CodingKeys: String, CodingKey {
            case newPath = "new_path"
            case newLine = "new_line"
            case oldPath = "old_path"
            case oldLine = "old_line"
            case baseSHA = "base_sha"
            case headSHA = "head_sha"
            case positionType = "position_type"
        }

        var isAnchored: Bool { newPath != nil || oldPath != nil || newLine != nil || oldLine != nil }
        var location: String? {
            guard let path = newPath ?? oldPath else { return nil }
            return (newLine ?? oldLine).map { "\(path):\($0)" } ?? path
        }

        // The saved publication and provenance records compare line locations and may predate these preview fields.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.newPath == rhs.newPath && lhs.newLine == rhs.newLine
                && lhs.oldPath == rhs.oldPath && lhs.oldLine == rhs.oldLine
        }
    }

    enum Kind: Equatable {
        case line(String)
        case reply
        case general
    }

    var kind: Kind {
        if let location = position?.location { return .line(location) }
        return discussionID == nil ? .general : .reply
    }

    func replacingBody(_ body: String) -> Self {
        .init(id: id, authorID: authorID, note: body, discussionID: discussionID,
              resolveDiscussion: resolveDiscussion, position: position)
    }

    func matchesBodyUpdate(_ expected: Self) -> Bool {
        id == expected.id && authorID == expected.authorID && note == expected.note
            && discussionID == expected.discussionID && position == expected.position
            && (resolveDiscussion == true) == (expected.resolveDiscussion == true)
    }

    enum CodingKeys: String, CodingKey {
        case id, note, position
        case authorID = "author_id"
        case discussionID = "discussion_id"
        case resolveDiscussion = "resolve_discussion"
    }
}
