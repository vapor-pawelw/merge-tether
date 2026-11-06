import CryptoKit
import Foundation

extension GlabService {
    func fetchAuthenticatedUser(host: String, expectedUsername: String) async throws -> GitLabAuthenticatedUser {
        let user: GitLabAuthenticatedUser = try await mergeRequestAPI("/user", host: host)
        guard user.id > 0, user.username == expectedUsername else { throw GlabError.notAuthenticated }
        return user
    }

    func fetchAuthoredMergeRequests(host: String) async throws -> [GitLabMergeRequest] {
        try await mergeRequestAPI(
            "/merge_requests?scope=created_by_me&state=opened&with_merge_status_recheck=true&per_page=100",
            host: host,
            arguments: ["--paginate"],
            timeout: 45,
            decode: { try GlabPaginatedJSON.decode(GitLabMergeRequest.self, from: $0) }
        )
    }

    func fetchMergeRequestStackSnapshot(projectID: Int, host: String) async throws -> MergeRequestStackSnapshot {
        async let requests: [GitLabMergeRequest] = fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests?state=opened&scope=all&per_page=100", host: host
        )
        async let branch = fetchProjectDefaultBranch(projectID: projectID, host: host)
        let (open, defaultBranch) = try await (requests, branch)
        guard let defaultBranch, !defaultBranch.isEmpty else {
            throw GlabError.decoding("GitLab did not provide the project's default branch")
        }
        return MergeRequestStackSnapshot(requests: open.filter { $0.projectID == projectID }, defaultBranch: defaultBranch)
    }

    func stackPosition(for work: AssistantAutomationRunner.MergeRequestWork) async -> String? {
        try? await fetchMergeRequestStackSnapshot(projectID: work.projectID, host: work.host).positions[work.iid]
    }

    func fetchMergeRequest(projectID: Int, iid: Int, host: String) async throws -> GitLabMergeRequest {
        let request: GitLabMergeRequest = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)",
            host: host
        )
        guard request.projectID == projectID, request.iid == iid else {
            throw GlabError.decoding("GitLab returned a different merge request")
        }
        return request
    }

    func fetchFileSHA256(projectID: Int, path: String, ref: String, host: String) async throws -> String {
        struct File: Decodable {
            let filePath: String
            let encoding: String
            let content: String
            enum CodingKeys: String, CodingKey { case filePath = "file_path"; case encoding, content }
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              Self.isFullGitSHA(ref), let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("Invalid remote source evidence")
        }
        let file: File = try await mergeRequestAPI("/projects/\(projectID)/repository/files/\(encoded)?ref=\(ref)", host: host)
        let base64 = file.content.components(separatedBy: .whitespacesAndNewlines).joined()
        guard file.filePath == path, file.encoding == "base64", let bytes = Data(base64Encoded: base64) else {
            throw GlabError.decoding("Could not verify the remote source file")
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func fetchMergeRequestApprovalState(
        projectID: Int,
        iid: Int,
        host: String
    ) async throws -> GitLabMergeRequestApprovalState {
        try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/approval_state", host: host)
    }

    func projectRequiresResolvedDiscussions(projectID: Int, host: String) async throws -> Bool {
        struct Project: Decodable {
            let onlyAllowMergeIfAllDiscussionsAreResolved: Bool

            enum CodingKeys: String, CodingKey {
                case onlyAllowMergeIfAllDiscussionsAreResolved = "only_allow_merge_if_all_discussions_are_resolved"
            }
        }

        let project: Project = try await mergeRequestAPI("/projects/\(projectID)", host: host)
        return project.onlyAllowMergeIfAllDiscussionsAreResolved
    }

    func projectResetsApprovalsOnPush(projectID: Int, host: String) async throws -> Bool {
        struct ApprovalConfiguration: Decodable {
            let resetApprovalsOnPush: Bool

            enum CodingKeys: String, CodingKey {
                case resetApprovalsOnPush = "reset_approvals_on_push"
            }
        }
        let config: ApprovalConfiguration = try await mergeRequestAPI("/projects/\(projectID)/approvals", host: host)
        return config.resetApprovalsOnPush
    }

    func mergeRequestDiscussionsAreResolved(projectID: Int, iid: Int, host: String) async throws -> Bool {
        let discussions = try await fetchMergeRequestDiscussions(projectID: projectID, iid: iid, host: host)
        return discussions.allSatisfy { discussion in
            !discussion.notes.isEmpty && discussion.notes.allSatisfy {
                $0.resolvable == false || ($0.resolvable == true && $0.resolved == true)
            }
        }
    }

    func fetchOwnDraftNotes(projectID: Int, iid: Int, host: String, userID: Int) async throws -> [GitLabDraftNote] {
        let drafts: [GitLabDraftNote] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes?per_page=100", host: host
        )
        return drafts.filter { $0.authorID == userID }
    }

    func fetchOwnDraftNoteCount(projectID: Int, iid: Int, host: String, userID: Int) async throws -> Int {
        try await fetchOwnDraftNotes(projectID: projectID, iid: iid, host: host, userID: userID).count
    }

    /// Publishes all of the current user's draft notes on the merge request.
    func publishDraftNotes(projectID: Int, iid: Int, host: String) async throws {
        struct NoContent: Decodable {}
        let _: NoContent = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes/bulk_publish",
            host: host,
            arguments: ["--method", "POST"],
            timeout: 30,
            decode: { _ in NoContent() }
        )
    }

    /// Selective publication avoids sending unrelated human replies in the same review.
    func publishDraftNote(projectID: Int, iid: Int, draftID: Int, host: String) async throws {
        struct NoContent: Decodable {}
        let _: NoContent = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes/\(draftID)/publish",
            host: host, arguments: ["--method", "PUT"], timeout: 30, decode: { _ in NoContent() }
        )
    }

    func isGitLabDuo(userID: Int, host: String) async throws -> Bool {
        struct User: Decodable { let id: Int; let username: String; let bot: Bool? }
        let user: User = try await mergeRequestAPI("/users/\(userID)", host: host)
        return user.id == userID && user.bot == true && user.username.lowercased() == "gitlabduo"
    }

    /// Approves the merge request only if its head is still `headSHA`.
    func approveMergeRequest(projectID: Int, iid: Int, headSHA: String, host: String, userID: Int) async throws {
        struct Approval: Decodable {
            struct Approver: Decodable {
                struct User: Decodable { let id: Int }
                let user: User
            }
            let approvedBy: [Approver]?

            enum CodingKeys: String, CodingKey { case approvedBy = "approved_by" }
        }
        let currentUser: GitLabAuthenticatedUser = try await mergeRequestAPI("/user", host: host)
        guard currentUser.id == userID else { throw GlabError.notAuthenticated }
        let result: Approval = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/approve",
            host: host,
            arguments: ["--method", "POST", "--raw-field", "sha=\(headSHA)"],
            timeout: 30
        )
        guard result.approvedBy?.contains(where: { $0.user.id == userID }) == true else {
            throw GlabError.decoding("GitLab did not confirm the approval")
        }
    }

    func fetchMergeRequestDiscussions(
        projectID: Int, iid: Int, host: String
    ) async throws -> [GitLabMergeRequestDiscussion] {
        try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/discussions?per_page=100",
            host: host
        )
    }

    func fetchReviewAssignedMergeRequests(userID: Int, host: String) async throws -> [GitLabMergeRequest] {
        try await fetchMergeRequestPages(
            "/merge_requests?scope=all&state=opened&reviewer_id=\(userID)&per_page=100",
            host: host
        )
    }

    func fetchMergeRequestReviewers(projectID: Int, iid: Int, host: String) async throws -> [GitLabMergeRequestReviewer] {
        try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/reviewers?per_page=100",
            host: host
        )
    }

    func singleLinkedWorkItem(for request: GitLabMergeRequest, host: String) async throws -> URL? {
        struct Details: Decodable { let description: String? }
        let endpoint = "/projects/\(request.projectID)/merge_requests/\(request.iid)"
        let closing: [GitLabLinkedWorkItem] = try await fetchMergeRequestPages(endpoint + "/closes_issues?per_page=100", host: host)
        let candidates: Set<URL>
        if closing.isEmpty {
            async let related: [GitLabLinkedWorkItem] = fetchMergeRequestPages(endpoint + "/related_issues?per_page=100", host: host)
            async let details: Details = mergeRequestAPI(endpoint, host: host)
            let (items, mr) = try await (related, details)
            candidates = Set(items.filter { $0.isExplicitlyMentioned(in: request, description: mr.description) }
                .compactMap { $0.verifiedURL(for: request) })
        } else {
            candidates = Set(closing.compactMap { $0.verifiedURL(for: request) })
            guard candidates.count == closing.count else { return nil }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func activeHumanReviewerUsername(userID: Int, host: String) async throws -> String? {
        struct Reviewer: Decodable {
            let id: Int
            let username: String
            let bot: Bool?
            let state: String
        }
        let user: Reviewer = try await mergeRequestAPI("/users/\(userID)", host: host)
        guard user.id == userID, user.bot == false, user.state == "active", !user.username.isEmpty else { return nil }
        return user.username
    }

    func requestReview(of request: GitLabMergeRequest, userID: Int, username: String,
                       alreadyAssigned: Bool, host: String) async throws {
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Request: Decodable { let iid: String }
                let mergeRequest: Request?
                let errors: [String]
            }
            struct Data: Decodable {
                let mergeRequestReviewerRereview: Payload?
                let mergeRequestSetReviewers: Payload?
            }
            struct Failure: Decodable { let message: String }
            let data: Data?
            let errors: [Failure]?
        }
        let query = alreadyAssigned ? """
            mutation($projectPath: ID!, $iid: String!, $userId: UserID!) {
              mergeRequestReviewerRereview(input: {projectPath: $projectPath, iid: $iid, userId: $userId}) {
                mergeRequest { iid } errors
              }
            }
            """ : """
            mutation($projectPath: ID!, $iid: String!, $username: String!) {
              mergeRequestSetReviewers(input: {
                projectPath: $projectPath, iid: $iid, reviewerUsernames: [$username], operationMode: APPEND
              }) { mergeRequest { iid } errors }
            }
            """
        let reviewer = alreadyAssigned ? "userId=gid://gitlab/User/\(userID)" : "username=\(username)"
        let result: Response = try await mergeRequestAPI(
            "graphql", host: host, arguments: [
                "--raw-field", "query=\(query)", "--raw-field", "projectPath=\(request.webURL.gitLabProjectPath)",
                "--raw-field", "iid=\(request.iid)", "--raw-field", reviewer
            ]
        )
        let payload = result.data?.mergeRequestReviewerRereview ?? result.data?.mergeRequestSetReviewers
        guard result.errors?.isEmpty != false, let payload, payload.errors.isEmpty,
              payload.mergeRequest?.iid == String(request.iid) else {
            throw GlabError.decoding("GitLab did not confirm the review request")
        }
    }

    func fetchPipelineFailedJobs(projectID: Int, pipelineID: Int, host: String) async throws -> [GitLabPipelineJob] {
        try await fetchMergeRequestPages(
            "/projects/\(projectID)/pipelines/\(pipelineID)/jobs?scope=failed&per_page=100",
            host: host
        )
    }

    func fetchActiveMergeTrainIIDs(projectID: Int, host: String) async throws -> Set<Int> {
        struct TrainEntry: Decodable {
            struct Request: Decodable {
                let iid: Int
                let projectID: Int

                enum CodingKeys: String, CodingKey {
                    case iid
                    case projectID = "project_id"
                }
            }

            let mergeRequest: Request

            enum CodingKeys: String, CodingKey {
                case mergeRequest = "merge_request"
            }
        }

        let entries: [TrainEntry] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_trains?scope=active&per_page=100",
            host: host
        )
        return Set(entries.compactMap { $0.mergeRequest.projectID == projectID ? $0.mergeRequest.iid : nil })
    }

    func fetchMergeRequestDependencies(projectID: Int, iid: Int, host: String) async throws -> [GitLabMergeRequest] {
        struct Dependency: Decodable {
            let blockingMergeRequest: GitLabMergeRequest?

            enum CodingKeys: String, CodingKey {
                case blockingMergeRequest = "blocking_merge_request"
            }
        }

        let dependencies: [Dependency] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/blocks?per_page=100",
            host: host
        )
        return dependencies.compactMap(\.blockingMergeRequest)
    }

    func fetchProjectDefaultBranch(projectID: Int, host: String) async throws -> String? {
        struct Project: Decodable {
            let defaultBranch: String?

            enum CodingKeys: String, CodingKey {
                case defaultBranch = "default_branch"
            }
        }

        let project: Project = try await mergeRequestAPI("/projects/\(projectID)", host: host)
        return project.defaultBranch
    }

    func resolveAutomationProject(path: String, host: String) async throws -> Int {
        struct Project: Decodable {
            let id: Int
            let path: String
            enum CodingKeys: String, CodingKey { case id; case path = "path_with_namespace" }
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed), !escaped.isEmpty else {
            throw GlabError.decoding("Invalid GitLab project path")
        }
        let project: Project = try await mergeRequestAPI("/projects/\(escaped)", host: host)
        guard project.id > 0, project.path == path else { throw GlabError.decoding("GitLab returned a different project") }
        return project.id
    }

    func fetchBranchHeadSHA(projectID: Int, branch: String, host: String) async throws -> String {
        struct Branch: Decodable {
            struct Commit: Decodable {
                let id: String
            }

            let commit: Commit
        }

        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !branch.isEmpty, let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("GitLab did not provide a branch name")
        }
        let result: Branch = try await mergeRequestAPI(
            "/projects/\(projectID)/repository/branches/\(encodedBranch)",
            host: host
        )
        guard Self.isFullGitSHA(result.commit.id) else {
            throw GlabError.decoding("GitLab did not provide a full branch SHA")
        }
        return result.commit.id
    }

    func mergeMergeRequest(
        projectID: Int,
        iid: Int,
        headSHA: String,
        host: String,
        expectedUser: GitLabAuthenticatedUser,
        expectedDiscussionFingerprint: String? = nil,
        shouldProceed: @MainActor () -> Bool = { true }
    ) async throws {
        struct MergeResult: Decodable {
            let projectID: Int
            let iid: Int
            let state: String

            enum CodingKeys: String, CodingKey {
                case projectID = "project_id"
                case iid, state
            }
        }

        guard Self.isFullGitSHA(headSHA) else {
            throw GlabError.decoding("GitLab did not provide a full source SHA")
        }
        guard let executable = glabPath else { throw GlabError.glabNotInstalled }
        if let expectedDiscussionFingerprint {
            async let request = fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            async let discussions = fetchMergeRequestDiscussions(projectID: projectID, iid: iid, host: host)
            async let drafts = fetchOwnDraftNoteCount(projectID: projectID, iid: iid, host: host, userID: expectedUser.id)
            let (live, threads, pending) = try await (request, discussions, drafts)
            guard live.author.id == expectedUser.id, live.state == "opened", live.draft == false,
                  live.sha == headSHA, live.webURL.isGitLabMergeRequest(host: host, iid: iid), pending == 0,
                  ReviewVerdict.fingerprint(threads) == expectedDiscussionFingerprint else {
                throw CancellationError()
            }
        }
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: expectedUser.username)
        guard user == expectedUser, glabPath == executable else { throw GlabError.notAuthenticated }
        try Task.checkCancellation()
        guard shouldProceed() else { throw CancellationError() }

        let result: MergeResult = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/merge",
            host: host,
            arguments: ["--method", "PUT", "--raw-field", "sha=\(headSHA)"],
            timeout: 30
        )
        guard result.projectID == projectID, result.iid == iid, result.state == "merged" else {
            throw GlabError.decoding("GitLab did not confirm the merge")
        }
    }

    private static func isFullGitSHA(_ sha: String) -> Bool {
        (sha.utf8.count == 40 || sha.utf8.count == 64) && sha.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private func fetchMergeRequestPages<Item: Decodable>(_ endpoint: String, host: String) async throws -> [Item] {
        try await mergeRequestAPI(
            endpoint,
            host: host,
            arguments: ["--paginate"],
            timeout: 45,
            decode: { try GlabPaginatedJSON.decode(Item.self, from: $0) }
        )
    }

    func mergeRequestAPI<Value: Decodable>(
        _ endpoint: String,
        host: String,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        decode: (Data) throws -> Value = { try JSONDecoder().decode(Value.self, from: $0) }
    ) async throws -> Value {
        guard let glabPath else { throw GlabError.glabNotInstalled }
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                glabPath,
                arguments: ["api", endpoint, "--hostname", host] + arguments,
                environment: Self.shellEnvironment,
                timeout: timeout
            )
        } catch ProcessRunner.RunError.timedOut {
            throw GlabError.timedOut
        }

        guard output.exitCode == 0 else {
            throw GlabError.classify(exitCode: output.exitCode, stderr: output.stderr)
        }
        do {
            return try decode(output.stdout)
        } catch {
            throw GlabError.decoding(error.localizedDescription)
        }
    }
}
