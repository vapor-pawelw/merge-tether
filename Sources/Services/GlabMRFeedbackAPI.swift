import Foundation

extension GlabService {
    private struct FeedbackAward: Decodable {
        let id: Int
        let name: String
        let user: GitLabWorkflowUser?
    }

    func hasOwnThumbsUp(projectID: Int, iid: Int, noteID: Int, host: String, userID: Int) async throws -> Bool {
        guard projectID > 0, iid > 0, noteID > 0, userID > 0 else {
            throw GlabError.decoding("Missing feedback reaction identity")
        }
        let awards: [FeedbackAward] = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/notes/\(noteID)/award_emoji?per_page=100",
            host: host, arguments: ["--paginate"],
            decode: { try GlabPaginatedJSON.decode(FeedbackAward.self, from: $0) })
        return awards.contains { $0.id > 0 && $0.name == "thumbsup" && $0.user?.id == userID }
    }

    /// The caller has just rechecked the live account, head, complete thread and policy.
    /// Never replay a failed POST; a later deliberate attempt starts by reading awards again.
    func addOwnThumbsUp(projectID: Int, iid: Int, noteID: Int, host: String, userID: Int, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        let result: FeedbackAward = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/notes/\(noteID)/award_emoji", host: host,
            arguments: ["--method", "POST", "--field", "name=thumbsup"], shouldProceed: shouldProceed)
        guard result.id > 0, result.name == "thumbsup", result.user?.id == userID,
              try await hasOwnThumbsUp(projectID: projectID, iid: iid, noteID: noteID, host: host, userID: userID) else {
            throw GlabError.decoding("GitLab did not confirm the account's thumbs-up reaction")
        }
    }
}
