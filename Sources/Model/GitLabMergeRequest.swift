import Foundation

struct MergeRequestApprovalProgress: Equatable, Sendable {
    let completed: Int
    let required: Int
    let approvedBy: [Todo.Author]
    var isSatisfied: Bool { completed > 0 && (required == 0 || completed == required) }
    init?(completed: Int, required: Int, approvedBy: [Todo.Author] = []) {
        guard required >= 0, completed >= 0, required == 0 || completed <= required else { return nil }
        self.completed = completed; self.required = required
        self.approvedBy = approvedBy
    }

    struct Participant: Identifiable {
        let author: Todo.Author
        let approved: Bool
        var id: Int { author.id }
    }

    func participants(reviewers: [Todo.Author]) -> [Participant] {
        Self.participants(approvedBy: approvedBy, reviewers: reviewers)
    }

    static func participants(approvedBy: [Todo.Author] = [], reviewers: [Todo.Author]) -> [Participant] {
        var seen: Set<Int> = []
        let people = approvedBy.map { Participant(author: $0, approved: true) }
            + reviewers.map { Participant(author: $0, approved: false) }
        return people.filter { $0.id > 0 && seen.insert($0.id).inserted }
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
        return .init(completed: required == 0 ? received : required - remaining, required: required,
                     approvedBy: (approvedBy ?? []).compactMap(\.user.author))
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
    let headPipeline: Pipeline?
    let reviewers: [Todo.Author]?
    private let user: UserPermissions?

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
        case headPipeline = "head_pipeline"
        case user, reviewers
    }
}

struct GitLabLinkedWorkItem: Decodable, Sendable {
    let iid: Int
    let projectID: Int?
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case iid
        case projectID = "project_id"
        case url = "web_url"
    }

    func verifiedURL(for request: GitLabMergeRequest) -> URL? {
        guard iid > 0, let url, url.host == request.webURL.host, url.port == request.webURL.port,
              url.scheme == request.webURL.scheme, url.user == nil, url.password == nil,
              url.path.hasSuffix("/-/work_items/\(iid)") || url.path.hasSuffix("/-/issues/\(iid)") else { return nil }
        return url
    }

    func isExplicitlyMentioned(in request: GitLabMergeRequest, description: String?) -> Bool {
        guard let url = verifiedURL(for: request) else { return false }
        let text = request.title + "\n" + (description ?? "")
        let canonical = url.absoluteString
        let workItemURL = canonical.replacingOccurrences(of: "/-/issues/", with: "/-/work_items/")
        let issueURL = canonical.replacingOccurrences(of: "/-/work_items/", with: "/-/issues/")
        if text.contains(workItemURL) || text.contains(issueURL) { return true }
        let project = url.path.components(separatedBy: "/-/").first?.dropFirst() ?? ""
        let fullReference = NSRegularExpression.escapedPattern(for: "\(project)#\(iid)")
        if text.range(of: "(?<![\\w/])\(fullReference)(?!\\d)", options: .regularExpression) != nil { return true }
        return projectID == request.projectID
            && text.range(of: "(?<![\\w/#])#\(iid)(?!\\d)", options: .regularExpression) != nil
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
struct GitLabDraftNote: Decodable, Equatable, Sendable {
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
