import Foundation
import MergeTetherRemote

extension TodoMonitorService {
    func canEditReviewers(of request: GitLabMergeRequest) -> Bool {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return false }
        return request.state == "opened" && request.author.username == username
            && request.webURL.isGitLabMergeRequest(host: host, iid: request.iid)
    }

    func searchReviewers(of request: GitLabMergeRequest, query: String, accountRevision: UInt64) async throws -> [ReviewerCandidate] {
        guard canEditReviewers(of: request), let host = glab.resolvedHost, accountRevision == glab.accountRevision else {
            throw CancellationError()
        }
        let matches = try await glab.searchProjectReviewers(projectID: request.projectID, query: query, host: host)
        guard canEditReviewers(of: request), accountRevision == glab.accountRevision else { throw CancellationError() }
        return matches
    }

    func changeReviewer(_ change: ReviewerChange, of displayed: GitLabMergeRequest,
                        accountRevision: UInt64) async -> RemoteCommandResult.Status {
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: displayed.projectID, iid: displayed.iid)
        guard let host = glab.resolvedHost, let username = glab.currentUsername, canEditReviewers(of: displayed),
              accountRevision == glab.accountRevision, reviewerEdits.insert(id).inserted else { return .changed }
        defer { reviewerEdits.remove(id) }

        let authorized: @MainActor @Sendable () -> Bool = {
            !Task.isCancelled && self.glab.accountRevision == accountRevision
                && self.glab.currentUsername == username && self.glab.resolvedHost == host
        }
        var submitted = false
        do {
            try await glab.changeMergeRequestReviewer(change, of: displayed, host: host,
                username: username, willSubmit: { submitted = true }, shouldProceed: authorized)
        } catch is CancellationError {
            return submitted ? .uncertain : .changed
        } catch GlabError.notAuthenticated {
            return .changed
        } catch {
            if authorized() { await refreshFromGitLab(for: id) }
            return submitted ? .uncertain : .failed
        }
        guard authorized() else { return .uncertain }
        await refreshFromGitLab(for: id)
        return .completed
    }
}

extension GlabService {
    func searchProjectReviewers(projectID: Int, query: String, host: String) async throws -> [ReviewerCandidate] {
        guard projectID > 0, !query.isEmpty, query.utf8.count <= 128 else { return [] }
        struct Member: Decodable {
            let id: Int
            let name: String
            let username: String
            let state: String
        }
        var queryParts = URLComponents()
        queryParts.queryItems = [.init(name: "search", value: query), .init(name: "per_page", value: "30")]
        let encoded = queryParts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        let people: [Member] = try await mergeRequestAPI("/projects/\(projectID)/users?\(encoded)", host: host)
        return people.filter { $0.id > 0 && $0.state == "active" && !$0.username.isEmpty }
            .map { .init(id: $0.id, name: $0.name, username: $0.username) }
    }

    func changeMergeRequestReviewer(_ change: ReviewerChange, of displayed: GitLabMergeRequest, host: String,
                                    username: String, willSubmit: () -> Void = {},
                                    shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: username)
        let live = try await fetchMergeRequest(projectID: displayed.projectID, iid: displayed.iid, host: host)
        guard shouldProceed(), live.projectID == displayed.projectID, live.iid == displayed.iid,
              live.webURL.isGitLabMergeRequest(host: host, iid: live.iid),
              live.webURL.gitLabProjectPath == displayed.webURL.gitLabProjectPath,
              live.state == "opened", live.author.id == user.id, let reviewers = live.reviewers else {
            throw CancellationError()
        }

        let current = reviewers.first { $0.id == change.reviewerID }
        let adding = change.operation == .add
        if (current != nil) == adding { return }
        let reviewer: String
        if adding {
            struct Account: Decodable { let id: Int; let username: String; let state: String }
            let target: Account = try await mergeRequestAPI("/users/\(change.reviewerID)", host: host)
            guard target.id == change.reviewerID, target.state == "active", target.username == change.username else {
                throw CancellationError()
            }
            reviewer = target.username
        } else {
            guard let current, current.username == change.username else { throw CancellationError() }
            reviewer = current.username
        }

        struct Response: Decodable {
            struct Payload: Decodable {
                struct Request: Decodable { let iid: String }
                let mergeRequest: Request?
                let errors: [String]
            }
            struct Data: Decodable { let mergeRequestSetReviewers: Payload? }
            struct Failure: Decodable { let message: String }
            let data: Data?
            let errors: [Failure]?
        }
        let query = """
            mutation($projectPath: ID!, $iid: String!, $username: String!, $mode: MutationOperationMode!) {
              mergeRequestSetReviewers(input: {projectPath: $projectPath, iid: $iid, reviewerUsernames: [$username], operationMode: $mode}) {
                mergeRequest { iid } errors
              }
            }
            """
        guard shouldProceed() else { throw CancellationError() }
        willSubmit()
        let result: Response = try await mergeRequestWriteAPI("graphql", host: host, arguments: [
            "--raw-field", "query=\(query)", "--raw-field", "projectPath=\(live.webURL.gitLabProjectPath)",
            "--raw-field", "iid=\(live.iid)", "--raw-field", "username=\(reviewer)",
            "--raw-field", "mode=\(adding ? "APPEND" : "REMOVE")"
        ], shouldProceed: shouldProceed)
        guard result.errors?.isEmpty != false, let payload = result.data?.mergeRequestSetReviewers,
              payload.errors.isEmpty, payload.mergeRequest?.iid == String(live.iid) else {
            throw GlabError.decoding("GitLab did not confirm the reviewer change")
        }
        let confirmed = try await fetchMergeRequest(projectID: live.projectID, iid: live.iid, host: host)
        guard let assigned = confirmed.reviewers, assigned.contains(where: { $0.id == change.reviewerID }) == adding else {
            throw GlabError.decoding("GitLab did not return the requested reviewer assignment")
        }
    }
}
