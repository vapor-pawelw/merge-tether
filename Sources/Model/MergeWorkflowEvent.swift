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
}

struct GitLabMergeRequestReviewer: Decodable, Sendable {
    let user: GitLabWorkflowUser
    let state: String
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

    func replyRecipients(excluding userID: Int) -> String? {
        var seen: Set<String> = []
        let handles = notes.compactMap { note -> String? in
            guard note.system != true, let author = note.author, author.id != userID,
                  let username = author.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !username.isEmpty, seen.insert(username.lowercased()).inserted else { return nil }
            return "@\(username)"
        }
        return handles.isEmpty ? nil : handles.joined(separator: ", ")
    }

    static func unresolvedFeedback(in discussions: [Self], excluding userID: Int) -> [Note] {
        discussions.flatMap(\.notes).filter {
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
                previouslyApproved: reviewer.state == "unapproved" || reviewer.state == "approved",
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

    func covers(noteID: Int, headSHA: String) -> Bool {
        // Older uncertain writes have no recorded head; keep their existing replay fence.
        (self.headSHA == headSHA || (self.headSHA == nil && unconfirmed)) && self.noteID >= noteID
    }
}

struct GitLabPipelineJob: Decodable, Sendable {
    let id: Int
    let status: String
    let allowFailure: Bool?
    let failureReason: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case allowFailure = "allow_failure"
        case failureReason = "failure_reason"
    }
}
