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
        return query.isEmpty ? matches.filter { $0.id != request.author.id } : matches
    }

    func changeReviewers(_ changes: [ReviewerChange], of displayed: GitLabMergeRequest,
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
            try await glab.changeMergeRequestReviewers(changes, of: displayed, host: host,
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
        guard projectID > 0, query.utf8.count <= 128 else { return [] }
        struct Member: Decodable {
            let id: Int
            let name: String
            let username: String
            let state: String
            let avatarURL: URL?
            enum CodingKeys: String, CodingKey {
                case id, name, username, state
                case avatarURL = "avatar_url"
            }
        }
        var queryParts = URLComponents()
        queryParts.queryItems = query.isEmpty ? [.init(name: "per_page", value: "100")] :
            [.init(name: "search", value: query), .init(name: "per_page", value: "30")]
        let encoded = queryParts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        async let activity = projectReviewerActivity(projectID: projectID, host: host)
        let people: [Member] = try await mergeRequestAPI("/projects/\(projectID)/users?\(encoded)", host: host)
        let ranks = await activity
        try Task.checkCancellation()
        let candidates = people.filter { $0.id > 0 && $0.state == "active" && !$0.username.isEmpty }
            .sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        return candidates.prefix(30).map { .init(id: $0.id, name: $0.name, username: $0.username, avatarURL: $0.avatarURL) }
    }

    private func projectReviewerActivity(projectID: Int, host: String) async -> [Int: Int] {
        if Task.isCancelled { return [:] }
        if let cached = reviewerActivity[projectID], cached.host == host, cached.expiresAt > Date() {
            return await cached.ranks.value
        }
        struct Event: Decodable {
            let authorID: Int?
            enum CodingKeys: String, CodingKey { case authorID = "author_id" }
        }
        reviewerActivity[projectID]?.ranks.cancel()
        let ranks = Task { [weak self] in
            guard let self, let events: [Event] = try? await mergeRequestAPI(
                "/projects/\(projectID)/events?sort=desc&per_page=100", host: host, timeout: 4
            ) else { return [Int: Int]() }
            var result: [Int: Int] = [:]
            for (index, event) in events.enumerated() {
                if let id = event.authorID, result[id] == nil { result[id] = index }
            }
            return result
        }
        reviewerActivity[projectID] = (host, Date().addingTimeInterval(300), ranks)
        if reviewerActivity.count > 16, let oldest = reviewerActivity.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            reviewerActivity.removeValue(forKey: oldest.key)?.ranks.cancel()
        }
        return await ranks.value
    }

    func changeMergeRequestReviewers(_ changes: [ReviewerChange], of displayed: GitLabMergeRequest, host: String,
                                     username: String, willSubmit: () -> Void = {},
                                     shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard let first = changes.first, first.reviewerID > 0, !first.username.isEmpty,
              changes.count == 1 || ReviewerChange.Batch(changes) != nil else { throw CancellationError() }
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: username)
        let live = try await fetchMergeRequest(projectID: displayed.projectID, iid: displayed.iid, host: host)
        guard shouldProceed(), live.projectID == displayed.projectID, live.iid == displayed.iid,
              live.webURL.isGitLabMergeRequest(host: host, iid: live.iid),
              live.webURL.gitLabProjectPath == displayed.webURL.gitLabProjectPath,
              live.state == "opened", live.author.id == user.id, let reviewers = live.reviewers else {
            throw CancellationError()
        }

        let adding = first.operation == .add
        let currentIDs = Set(reviewers.map(\.id))
        let pending = changes.filter { currentIDs.contains($0.reviewerID) != adding }
        guard !pending.isEmpty else { return }
        if adding {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for change in pending {
                    group.addTask { try await self.validateReviewer(change, host: host) }
                }
                try await group.waitForAll()
            }
        } else {
            guard reviewers.contains(where: { $0.id == first.reviewerID && $0.username == first.username }) else {
                throw CancellationError()
            }
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
        let variables = pending.count == 1 ? ["username"] : pending.indices.map { "username\($0)" }
        let declarations = variables.map { "$\($0): String!" }.joined(separator: ", ")
        let usernames = variables.map { "$\($0)" }.joined(separator: ", ")
        let query = """
            mutation($projectPath: ID!, $iid: String!, \(declarations), $mode: MutationOperationMode!) {
              mergeRequestSetReviewers(input: {projectPath: $projectPath, iid: $iid, reviewerUsernames: [\(usernames)], operationMode: $mode}) {
                mergeRequest { iid } errors
              }
            }
            """
        guard shouldProceed() else { throw CancellationError() }
        let fields = zip(variables, pending).flatMap { ["--raw-field", "\($0.0)=\($0.1.username)"] }
        willSubmit()
        let result: Response = try await mergeRequestWriteAPI("graphql", host: host, arguments: [
            "--raw-field", "query=\(query)", "--raw-field", "projectPath=\(live.webURL.gitLabProjectPath)",
            "--raw-field", "iid=\(live.iid)"
        ] + fields + ["--raw-field", "mode=\(adding ? "APPEND" : "REMOVE")"], shouldProceed: shouldProceed)
        guard result.errors?.isEmpty != false, let payload = result.data?.mergeRequestSetReviewers,
              payload.errors.isEmpty, payload.mergeRequest?.iid == String(live.iid) else {
            throw GlabError.decoding("GitLab did not confirm the reviewer change")
        }
        let confirmed = try await fetchMergeRequest(projectID: live.projectID, iid: live.iid, host: host)
        guard let assignedIDs = confirmed.reviewers.map({ Set($0.map(\.id)) }),
              changes.allSatisfy({ assignedIDs.contains($0.reviewerID) == adding }) else {
            throw GlabError.decoding("GitLab did not return the requested reviewer assignment")
        }
    }

    private func validateReviewer(_ change: ReviewerChange, host: String) async throws {
        struct Account: Decodable { let id: Int; let username: String; let state: String }
        let target: Account = try await mergeRequestAPI("/users/\(change.reviewerID)", host: host)
        guard target.id == change.reviewerID, target.state == "active", target.username == change.username else {
            throw CancellationError()
        }
    }
}
