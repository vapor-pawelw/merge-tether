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

        enum CodingKeys: String, CodingKey {
            case id, author, system, resolvable, resolved, body
            case resolvedBy = "resolved_by"
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
