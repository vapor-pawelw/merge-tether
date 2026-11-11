import Foundation

struct PendingDraftRead: Sendable {
    let drafts: [GitLabDraftNote]?
    let request: GitLabMergeRequest?
    let discussions: [GitLabMergeRequestDiscussion]?
}

extension GlabService {
    /// Poll preparation only; authorization and every publication decision stay on MainActor.
    func fetchPendingDraftRead(projectID: Int, iid: Int, host: String, userID: Int) async -> PendingDraftRead {
        let endpoint = "/projects/\(projectID)/merge_requests/\(iid)"
        async let drafts: [GitLabDraftNote]? = try? pendingDraftPages(endpoint + "/draft_notes?per_page=100", host: host)
        async let discussions: [GitLabMergeRequestDiscussion]? = try? pendingDraftPages(endpoint + "/discussions?per_page=100", host: host)
        async let request = try? pendingDraftRequest(endpoint, projectID: projectID, iid: iid, host: host)
        let (ownDrafts, liveRequest, liveDiscussions) = await (drafts, request, discussions)
        return .init(drafts: ownDrafts?.filter { $0.authorID == userID }, request: liveRequest, discussions: liveDiscussions)
    }

    private func pendingDraftPages<Value: Decodable & Sendable>(_ endpoint: String, host: String) async throws -> [Value] {
        let data = try await pendingDraftData(endpoint, host: host, paginated: true)
        let result = try await Task.detached(priority: .utility) {
            try GlabPaginatedJSON.decode(Value.self, from: data)
        }.value
        try Task.checkCancellation()
        return result
    }

    private func pendingDraftRequest(_ endpoint: String, projectID: Int, iid: Int, host: String) async throws -> GitLabMergeRequest {
        let data = try await pendingDraftData(endpoint, host: host, paginated: false)
        let request = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(GitLabMergeRequest.self, from: data)
        }.value
        try Task.checkCancellation()
        guard request.projectID == projectID, request.iid == iid else {
            throw GlabError.decoding("GitLab returned a different merge request")
        }
        return request
    }

    private func pendingDraftData(_ endpoint: String, host: String, paginated: Bool) async throws -> Data {
        try Task.checkCancellation()
        return try await mergeRequestAPI(endpoint, host: host,
            arguments: paginated ? ["--paginate"] : [], timeout: paginated ? 45 : 15, decode: { $0 })
    }
}
