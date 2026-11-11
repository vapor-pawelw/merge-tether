import Foundation

struct MergeRequestApprovalProgress: Equatable, Sendable {
    let completed: Int
    let required: Int
    let approvedBy: [Todo.Author]
    var requirementsSatisfied: Bool? = nil
    var reviewHistory = MergeRequestReviewHistory()
    var approvalDates: [Int: Date] = [:]
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
    }
    func progress(projectID: Int, iid: Int) -> MergeRequestApprovalProgress? {
        guard projectID > 0, iid > 0, self.projectID == nil || self.projectID == projectID,
              self.iid == nil || self.iid == iid, let required, let remaining,
              required >= 0, remaining >= 0, remaining <= required else { return nil }
        let received = Set((approvedBy ?? []).map(\.user.id).filter { $0 > 0 }).count
        var result = MergeRequestApprovalProgress(completed: approvedBy == nil ? required - remaining : received, required: required,
                     approvedBy: (approvedBy ?? []).compactMap(\.user.author))
        result?.requirementsSatisfied = remaining == 0
        for approver in approvedBy ?? [] {
            guard let date = MergeRequestReviewHistory.date(approver.approvedAt) else { continue }
            let previous = result?.approvalDates[approver.user.id] ?? .distantPast
            result?.approvalDates[approver.user.id] = max(previous, date)
        }
        return result
    }
}

struct GitLabAuthenticatedUser: Codable, Equatable, Sendable {
    let id: Int
    let username: String
}

struct GitLabMergeRequest: Codable, Sendable {
    let projectID: Int
    let iid: Int
    let author: Todo.Author
    let title: String
    let description: String?
    let webURL: URL
    let state: String
    let draft: Bool?
    let sha: String?
    let sourceProjectID: Int?
    let sourceBranch: String
    let targetProjectID: Int?
    let targetBranch: String
    let detailedMergeStatus: String?
    let hasConflicts: Bool?
    let labels: [String]
    let blockingDiscussionsResolved: Bool?
    let mergeWhenPipelineSucceeds: Bool?
    let headPipeline: Pipeline?
    let reviewers: [Todo.Author]?
    private let user: UserPermissions?
    // Derived live evidence is deliberately excluded from the persisted REST payload.
    var mergeTrainConflict: MergeTrainPreparationConflict? = nil
    var mergeTrainEvidenceUnavailable = false

    var canMerge: Bool? { user?.canMerge }

    /// Semantic feedback checks depend on MR text as well as code and discussions.
    var semanticContextFingerprint: String {
        let body = description ?? ""
        return UserAttentionSnapshot.digest("\(title.utf8.count):\(title)\(body.utf8.count):\(body)")
    }

    struct Pipeline: Codable, Sendable {
        let id: Int?
        let projectID: Int?
        let status: String
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
        case user, reviewers
    }
}

struct GitLabMergeRequestApprovalState: Decodable, Sendable {
    private let rules: [Rule]

    var hasRequiredRules: Bool {
        rules.contains { $0.approvalsRequired > 0 }
    }

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

        enum CodingKeys: String, CodingKey {
            case newPath = "new_path"
            case newLine = "new_line"
            case oldPath = "old_path"
            case oldLine = "old_line"
        }
    }

    enum Kind: Equatable {
        case line(String)
        case reply
        case general
    }

    var kind: Kind {
        if let path = position?.newPath ?? position?.oldPath {
            let line = position?.newLine ?? position?.oldLine
            return .line(line.map { "\(path):\($0)" } ?? path)
        }
        return discussionID == nil ? .general : .reply
    }

    enum CodingKeys: String, CodingKey {
        case id, note, position
        case authorID = "author_id"
        case discussionID = "discussion_id"
        case resolveDiscussion = "resolve_discussion"
    }
}
