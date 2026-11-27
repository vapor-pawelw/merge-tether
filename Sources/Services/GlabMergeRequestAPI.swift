import CryptoKit
import Foundation
import MergeTetherRemote

extension GlabService {
    func fetchMergeRequestApprovalProgress(projectID: Int, iid: Int, host: String) async throws -> MergeRequestApprovalProgress? {
        let counts = try await fetchMergeRequestApprovalCounts(projectID: projectID, iid: iid, host: host)
        return counts.progress(projectID: projectID, iid: iid)
    }

    func fetchMergeRequestApprovalCounts(projectID: Int, iid: Int, host: String, timeout: TimeInterval = 15) async throws -> GitLabMergeRequestApprovalCounts {
        try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/approvals", host: host, timeout: timeout)
    }

    func fetchAuthenticatedUser(host: String, expectedUsername: String, expectedUserID: Int? = nil) async throws -> GitLabAuthenticatedUser {
        let revision = accountRevision
        let isDefaultAccount = resolvedHost == host && currentUsername == expectedUsername
        let user = try await readAuthenticatedUser(host: host)
        guard user.username == expectedUsername else { throw GlabError.notAuthenticated }
        guard expectedUserID == nil || user.id == expectedUserID else { throw CancellationError() }
        if isDefaultAccount, !confirmAuthenticatedAccount(user.account(on: host), revision: revision) {
            // A login switch during the read makes this evidence stale rather than unauthenticated.
            if accountRevision != revision || resolvedHost != host || currentUsername != expectedUsername || Task.isCancelled {
                throw CancellationError()
            }
            throw GlabError.notAuthenticated
        }
        return user
    }

    /// Refresh the login name from GitLab before an inbox pass captures a new session.
    func refreshAuthenticatedAccount() async throws -> GitLabAuthenticatedUser {
        let session = evidenceAccountContext
        guard let account = session.account else { throw GlabError.notAuthenticated }
        let user = try await readAuthenticatedUser(host: account.host)
        guard !Task.isCancelled, session.binds(to: evidenceAccountContext, policy: .accountSession) else {
            throw GlabError.notAuthenticated
        }
        if user.username != account.username {
            currentUsername = user.username
        } else if let currentID = authenticatedUserID, currentID != user.id {
            resetAccountIdentity()
        }
        guard confirmAuthenticatedAccount(user.account(on: account.host), revision: accountRevision) else {
            throw GlabError.notAuthenticated
        }
        return user
    }

    private func readAuthenticatedUser(host: String) async throws -> GitLabAuthenticatedUser {
        let user: GitLabAuthenticatedUser = try await mergeRequestAPI("/user", host: host)
        guard user.id > 0, !user.username.isEmpty else { throw GlabError.notAuthenticated }
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

    func fetchOwnedMergeRequests(userID: Int, host: String) async throws -> [GitLabMergeRequest] {
        async let authored = fetchAuthoredMergeRequests(host: host)
        async let assigned = fetchAssignedMergeRequests(userID: userID, host: host)
        let (authoredRequests, delegated) = try await (authored, assigned)
        let created = authoredRequests.filter { $0.author.id == userID && owns($0, userID: userID) }
        let createdIDs = Set(created.map(\.mergeRequestID))
        return created + delegated.filter { !createdIDs.contains($0.mergeRequestID) && owns($0, userID: userID) }
    }

    private func fetchAssignedMergeRequests(userID: Int, host: String) async -> [GitLabMergeRequest] {
        guard userID > 0, ownershipSettings?.treatAssignedMergeRequestsAsOwn == true else { return [] }
        do {
            let assigned: [GitLabMergeRequest] = try await fetchMergeRequestPages(
                "/merge_requests?scope=all&state=opened&assignee_id=\(userID)&with_merge_status_recheck=true&per_page=100",
                host: host)
            return assigned.filter { $0.assignees?.contains { $0.id == userID } == true }
        } catch {
            Log.monitor.error("Assigned merge request catalog refresh failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    func markMergeRequestReady(
        projectID: Int, iid: Int, headSHA: String, host: String,
        expectedUser: GitLabAuthenticatedUser, shouldProceed: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> GitLabMergeRequest {
        guard projectID > 0, iid > 0, Self.isFullGitSHA(headSHA) else {
            throw GlabError.decoding("Invalid merge request identity or source SHA")
        }
        guard let executable = glabPath else { throw GlabError.glabNotInstalled }
        let revision = accountRevision
        func checkSession() throws {
            guard EvidenceContext.sameAccountRevision(revision, accountRevision), glabPath == executable,
                  resolvedHost == host, currentUsername == expectedUser.username else {
                throw GlabError.notAuthenticated
            }
            try Task.checkCancellation()
            guard shouldProceed() else { throw CancellationError() }
        }
        try checkSession()
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: expectedUser.username)
        guard user == expectedUser else { throw GlabError.notAuthenticated }
        try checkSession()
        let current = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
        try checkSession()
        guard owns(current, userID: expectedUser.id), current.state == .opened, EvidenceContext.sameHead(headSHA, current.sha),
              current.webURL.isGitLabMergeRequest(host: host, iid: iid), let draft = current.draft else {
            throw CancellationError()
        }
        if !draft { return current }

        var repository = URLComponents(url: current.webURL, resolvingAgainstBaseURL: false)
        repository?.path = "/" + current.webURL.gitLabProjectPath
        repository?.query = nil
        repository?.fragment = nil
        guard let repositoryURL = repository?.url, !current.webURL.gitLabProjectPath.isEmpty else {
            throw GlabError.decoding("GitLab did not provide the merge request repository")
        }
        let finalUser = try await fetchAuthenticatedUser(host: host, expectedUsername: expectedUser.username)
        guard finalUser == expectedUser else { throw GlabError.notAuthenticated }
        try checkSession()
        let readyRequest = if ownershipSettings?.treatAssignedMergeRequestsAsOwn != true, current.author.id == expectedUser.id { current }
            else { try await fetchMergeRequest(projectID: projectID, iid: iid, host: host) }
        guard readyRequest.isOpen, readyRequest.sha == headSHA, readyRequest.draft == true,
              readyRequest.webURL == current.webURL, owns(readyRequest, userID: expectedUser.id) else { throw CancellationError() }
        let output: ProcessRunner.Output
        do {
            output = try await runWriteCommand(
                executable,
                arguments: ["mr", "update", String(iid), "--ready", "--yes", "--repo", repositoryURL.absoluteString],
                environment: Self.shellEnvironment,
                timeout: 30, shouldProceed: { self.owns(readyRequest, userID: expectedUser.id) && shouldProceed() }
            )
        } catch ProcessRunner.RunError.timedOut {
            throw GlabError.timedOut
        }
        guard output.exitCode == 0 else {
            throw GlabError.classify(exitCode: output.exitCode, stderr: output.stderr)
        }
        try checkSession()
        let updated = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
        try checkSession()
        guard owns(updated, userID: expectedUser.id), updated.isOpen, EvidenceContext.sameHead(headSHA, updated.sha),
              updated.webURL == current.webURL, updated.draft == false else {
            throw GlabError.decoding("GitLab did not confirm the merge request is ready")
        }
        return updated
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

    func fetchCurrentDiffVersionDate(for request: GitLabMergeRequest, host: String) async throws -> Date? {
        struct Version: Decodable {
            let head: String
            let base: String
            let start: String?
            let createdAt: String

            enum CodingKeys: String, CodingKey {
                case head = "head_commit_sha", base = "base_commit_sha", start = "start_commit_sha", createdAt = "created_at"
            }
        }

        guard let target = request.evidenceTarget else { return nil }
        let versions: [Version] = try await mergeRequestAPI(
            "/projects/\(request.projectID)/merge_requests/\(request.iid)/versions?per_page=1", host: host)
        guard let latest = versions.first, EvidenceContext.sameHead(request.sha, latest.head), latest.base == target.base,
              request.diffRefs?.startSHA.map({ $0 == latest.start }) != false else { return nil }
        return MergeRequestReviewHistory.date(latest.createdAt)
    }

    func fetchClosingIssues(projectID: Int, iid: Int, host: String) async throws -> [RemoteMRIssue] {
        guard projectID > 0, iid > 0 else { throw GlabError.decoding("Invalid merge request identity") }
        let issues: [GitLabClosingIssue] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/closes_issues", host: host)
        return issues.compactMap(\.displayIssue)
    }

    func fetchReviewSourceFile(projectID: Int, path: String, head: String, host: String) async throws -> Data {
        guard projectID > 0 else { throw CancellationError() }
        let encoded = try Self.encodeRepositoryFilePath(path, ref: head)
        return try await mergeRequestAPI("/projects/\(projectID)/repository/files/\(encoded)/raw?ref=\(head)",
            host: host, decode: { $0 })
    }

    func fetchIssueCandidates(for request: GitLabMergeRequest, host: String) async throws -> [MRIssueCandidate] {
        guard request.projectID > 0, request.iid > 0, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid)
        else { throw GlabError.decoding("Invalid merge request identity") }
        if let relations = try? await fetchWorkItemRelations(for: request, host: host) {
            return relations
        }
        try Task.checkCancellation()
        let endpoint = "/projects/\(request.projectID)/merge_requests/\(request.iid)"
        async let closing = fetchLegacyIssueCandidates("\(endpoint)/closes_issues", request: request, host: host, relation: .closing)
        async let related = fetchLegacyIssueCandidates("\(endpoint)/related_issues", request: request, host: host, relation: .related)
        let (closingIssues, relatedIssues) = try await (closing, related)
        return closingIssues + relatedIssues
    }

    func resolveIssueLinks(_ issues: [RemoteMRIssue], for request: GitLabMergeRequest, host: String) async -> [RemoteMRIssue] {
        guard issues.contains(where: { $0.linkURL == nil }), request.projectID > 0, request.iid > 0,
              resolvedHost == host, request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) else { return issues }
        let revision = accountRevision
        let source = MRIssueAssessor.Input(request: request)
        let text = source.title + "\n" + source.description
        let references = text.matches(of: /(?:^|[^\w.\/#\\%-])(((?:[\w.-]+\/)*[\w.-]*)#([1-9][0-9]*))(?![\w\/#-]|\.\w|\]\()/)
        var resolved = issues
        for (index, issue) in issues.enumerated() where issue.linkURL == nil {
            guard !Task.isCancelled, revision == accountRevision else { return issues }
            guard let match = references.first(where: { $0.output.1 == issue.reference })?.output,
                  let iid = Int(match.3),
                  let project = Self.issueProject(match.2, in: request) else { continue }
            do {
                let response: GitLabClosingIssue = try await mergeRequestAPI("/projects/\(project.id)/issues/\(iid)",
                    host: host, timeout: 8)
                guard !Task.isCancelled, revision == accountRevision else { return issues }
                guard response.iid == iid, let projectID = response.projectID, projectID > 0,
                      Int(project.id).map({ $0 == projectID }) ?? true,
                      let url = response.displayIssue?.linkURL,
                      Self.matchesIssueLink(url, projectPath: project.path, iid: iid, mergeRequest: request.webURL) else { continue }
                resolved[index] = .init(reference: issue.reference, title: issue.title, url: url)
            } catch let GlabError.nonZeroExit(_, diagnostic) where
                GlabError.hasHTTPStatus(403, in: diagnostic) || GlabError.hasHTTPStatus(404, in: diagnostic) {
                continue
            } catch {
                break
            }
        }
        return !Task.isCancelled && revision == accountRevision ? resolved : issues
    }

    private static func issueProject(_ qualifier: Substring, in request: GitLabMergeRequest) -> (id: String, path: String)? {
        let mergeRequestProject = request.webURL.gitLabProjectPath
        guard !mergeRequestProject.isEmpty else { return nil }
        if qualifier.isEmpty { return (String(request.projectID), mergeRequestProject) }
        let path = qualifier.contains("/") ? String(qualifier)
            : (mergeRequestProject.split(separator: "/").dropLast() + [qualifier]).joined(separator: "/")
        guard path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        if path == mergeRequestProject { return (String(request.projectID), path) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return path.addingPercentEncoding(withAllowedCharacters: allowed).map { ($0, path) }
    }

    private static func matchesIssueLink(_ url: URL, projectPath: String, iid: Int, mergeRequest: URL) -> Bool {
        let defaultPort = mergeRequest.scheme == "https" ? 443 : 80
        guard url.scheme == mergeRequest.scheme, url.host?.lowercased() == mergeRequest.host?.lowercased(),
              (url.port ?? defaultPort) == (mergeRequest.port ?? defaultPort),
              let issue = url.path.wholeMatch(of: /\/(.+?)\/(?:-\/)?(?:issues|work_items)\/([1-9][0-9]*)\/?/),
              Int(issue.2) == iid else { return false }
        return issue.1 == projectPath || issue.1.hasSuffix("/\(projectPath)")
    }

    func fetchIssueReferencedMergeRequests(for request: GitLabMergeRequest, host: String) async throws -> [GitLabMergeRequest] {
        // A local !123 reference stays in the MR's project. Ignore qualified references and deduplicate before fetching.
        let text = String(request.title.prefix(300)) + "\n" + String((request.description ?? "").prefix(6_000))
        let matches = text.matches(of: /(?:^|[^\w\/!])!([1-9][0-9]*)\b/)
        var seen = Set([request.iid])
        let ids = matches.compactMap { Int($0.1) }.filter { seen.insert($0).inserted }.prefix(2)
        var results: [GitLabMergeRequest] = []
        for iid in ids {
            try Task.checkCancellation()
            do {
                let related = try await fetchMergeRequest(projectID: request.projectID, iid: iid, host: host)
                if related.webURL.isGitLabMergeRequest(host: host, iid: iid) { results.append(related) }
            } catch let GlabError.nonZeroExit(_, diagnostic) where
                GlabError.hasHTTPStatus(403, in: diagnostic) || GlabError.hasHTTPStatus(404, in: diagnostic) {
                continue
            }
        }
        return results
    }

    private func fetchLegacyIssueCandidates(_ endpoint: String, request: GitLabMergeRequest, host: String,
                                            relation: MRIssueCandidate.Relation) async throws -> [MRIssueCandidate] {
        let data = try await readMergeRequestAPIResponse(endpoint, host: host, arguments: ["--paginate"], timeout: 15,
                                                         authorizeLaunch: nil)
        return try await Self.decodeLegacyIssueCandidates(data, request: request, relation: relation)
    }

    private nonisolated static func decodeLegacyIssueCandidates(_ data: Data, request: GitLabMergeRequest,
                                                               relation: MRIssueCandidate.Relation) async throws -> [MRIssueCandidate] {
        try GlabPaginatedJSON.decode(GitLabClosingIssue.self, from: data).compactMap { $0.candidate(in: request, relation: relation) }
    }

    private func fetchWorkItemRelations(for request: GitLabMergeRequest, host: String) async throws -> [MRIssueCandidate]? {
        let query = """
        query MergeTetherWorkItems($projectPath: ID!, $iid: String!) {
          project(fullPath: $projectPath) {
            mergeRequest(iid: $iid) {
              workItemRelations(first: 100) {
                nodes { linkType workItem { iid title webUrl description } }
              }
            }
          }
        }
        """
        // Fixed query with variables. This path can only read work item relations.
        let data = try await readMergeRequestAPIResponse("graphql", host: host,
            arguments: ["--raw-field", "query=\(query)", "--raw-field", "projectPath=\(request.webURL.gitLabProjectPath)",
                        "--raw-field", "iid=\(request.iid)"], timeout: 15, authorizeLaunch: nil)
        return try await Self.decodeWorkItemRelations(data)
    }

    private nonisolated static func decodeWorkItemRelations(_ data: Data) async throws -> [MRIssueCandidate]? {
        struct Envelope: Decodable {
            let data: Data?
            struct Data: Decodable { let project: Project? }
            struct Project: Decodable { let mergeRequest: MergeRequest? }
            struct MergeRequest: Decodable { let workItemRelations: Connection? }
            struct Connection: Decodable { let nodes: [Node] }
            struct Node: Decodable {
                let linkType: String
                let workItem: WorkItem?
                struct WorkItem: Decodable {
                    let iid: String
                    let title: String
                    let webUrl: URL?
                    let description: String?
                }
            }
        }
        let response = try JSONDecoder().decode(Envelope.self, from: data)
        return response.data?.project?.mergeRequest?.workItemRelations?.nodes.compactMap { node in
            guard let item = node.workItem, let iid = Int(item.iid), iid > 0 else { return nil }
            let issue = RemoteMRIssue(reference: "#\(iid)", title: GitLabClosingIssue.singleLine(item.title, limit: 160), url: item.webUrl)
            let relation: MRIssueCandidate.Relation = switch node.linkType.uppercased() {
            case "CLOSES": .closing
            case "RELATED": .related
            default: .mentioned
            }
            return .init(issue: .init(reference: issue.reference, title: issue.title, url: issue.linkURL),
                         relation: relation, description: item.description)
        }
    }

    func fetchFileSHA256(projectID: Int, path: String, ref: String, host: String) async throws -> String {
        struct File: Decodable {
            let filePath: String
            let encoding: String
            let content: String
            enum CodingKeys: String, CodingKey { case filePath = "file_path"; case encoding, content }
        }
        let encoded = try Self.encodeRepositoryFilePath(path, ref: ref)
        let file: File = try await mergeRequestAPI("/projects/\(projectID)/repository/files/\(encoded)?ref=\(ref)", host: host)
        let base64 = file.content.components(separatedBy: .whitespacesAndNewlines).joined()
        guard file.filePath == path, file.encoding == "base64", let bytes = Data(base64Encoded: base64) else {
            throw GlabError.decoding("Could not verify the remote source file")
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func fetchDiscussionCode(_ anchor: MRDiscussionCodeAnchor, in projectID: Int,
                             for target: MRDiscussionTarget) async throws -> [MRDiscussionCodeAnchor.Line] {
        let revision = accountRevision
        guard projectID > 0, resolvedHost == target.host, currentUsername == target.username else {
            throw GlabError.notAuthenticated
        }
        let encoded = try Self.encodeRepositoryFilePath(anchor.path, ref: anchor.revision)
        let data: Data = try await mergeRequestAPI(
            "/projects/\(projectID)/repository/files/\(encoded)/raw?ref=\(anchor.revision)",
            host: target.host, decode: { $0 })
        try Task.checkCancellation()
        guard EvidenceContext.sameAccountRevision(revision, accountRevision) else { throw GlabError.notAuthenticated }
        return anchor.excerpt(from: data)
    }

    private static func encodeRepositoryFilePath(_ path: String, ref: String) throws -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              Self.isFullGitSHA(ref), let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("Invalid remote source evidence")
        }
        return encoded
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

    func createDraftReply(projectID: Int, iid: Int, host: String, userID: Int, discussionID: String, body: String,
                          shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> GitLabDraftNote {
        guard projectID > 0, iid > 0, userID > 0, !discussionID.isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !DraftPublicationRisk.hasQuickAction(in: body) else { throw CancellationError() }
        let draft: GitLabDraftNote = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes", host: host,
            arguments: ["--method", "POST", "--raw-field", "note=\(body)",
                "--raw-field", "in_reply_to_discussion_id=\(discussionID)", "--field", "resolve_discussion=false"],
            timeout: 30, shouldProceed: shouldProceed
        )
        guard (draft.id ?? 0) > 0, draft.authorID == userID, draft.discussionID == discussionID,
              draft.note == body, AutomaticPublicationPolicy.safeForAutomaticPublication(draft) else {
            throw GlabError.decoding("Unexpected private draft reply response")
        }
        return draft
    }

    /// Selective publication avoids sending unrelated human replies in the same review.
    func publishDraftNote(projectID: Int, iid: Int, draftID: Int, host: String, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        struct NoContent: Decodable {}
        let _: NoContent = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes/\(draftID)/publish",
            host: host, arguments: ["--method", "PUT"], timeout: 30, shouldProceed: shouldProceed, decode: { _ in NoContent() }
        )
    }

    func deleteDraftNote(projectID: Int, iid: Int, draftID: Int, host: String, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        struct NoContent: Decodable {}
        let _: NoContent = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes/\(draftID)",
            host: host, arguments: ["--method", "DELETE"], timeout: 30, shouldProceed: shouldProceed, decode: { _ in NoContent() }
        )
    }

    func updateDraftNote(_ draft: GitLabDraftNote, body: String, projectID: Int, iid: Int, host: String,
                         shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> GitLabDraftNote {
        guard projectID > 0, iid > 0, let draftID = draft.id, draftID > 0,
              DraftRegenerationGeneratedDraft.isValidBody(body) else { throw CancellationError() }
        let updated: GitLabDraftNote = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/draft_notes/\(draftID)",
            host: host, arguments: ["--method", "PUT", "--raw-field", "note=\(body)"],
            timeout: 30, shouldProceed: shouldProceed
        )
        guard updated.matchesBodyUpdate(draft.replacingBody(body)) else {
            throw GlabError.decoding("Unexpected private draft update response")
        }
        return updated
    }

    /// Read stable account metadata rather than inferring identity from names or AI-like prose.
    func feedbackAccountKind(userID: Int, host: String) async throws -> AuthorFeedbackPolicy.AccountKind {
        struct Account: Decodable {
            let id: Int
            let bot: Bool?
            let userType: String?
            enum CodingKeys: String, CodingKey { case id, bot; case userType = "user_type" }
        }
        guard userID > 0 else { return .unknown }
        let revision = accountRevision, username = currentUsername
        let account: Account = try await mergeRequestAPI("/users/\(userID)", host: host)
        guard account.id == userID, let username, resolvedHost == host, currentUsername == username,
              EvidenceContext.sameAccountRevision(revision, accountRevision), !Task.isCancelled else { return .unknown }
        let kind = AuthorFeedbackPolicy.AccountKind.classify(bot: account.bot, userType: account.userType)
        notifyFeedbackAccountKind(userID: userID, kind: kind, host: host, username: username, accountRevision: revision)
        return kind
    }

    func isGitLabDuo(userID: Int, host: String) async throws -> Bool {
        struct User: Decodable { let id: Int; let username: String; let bot: Bool? }
        let user: User = try await mergeRequestAPI("/users/\(userID)", host: host)
        return user.id == userID && user.bot == true && user.username.lowercased() == "gitlabduo"
    }

    /// Approves the merge request only if its head is still `headSHA`.
    @discardableResult
    func approveMergeRequest(projectID: Int, iid: Int, headSHA: String, host: String, userID: Int,
                             willSubmit: (() -> Void)? = nil,
                             shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> MergeRequestApprovalProgress? {
        try await submitMergeRequestApproval(projectID: projectID, iid: iid, host: host, userID: userID,
            headToApprove: headSHA, willSubmit: willSubmit, shouldProceed: shouldProceed)
    }

    func removeMergeRequestApproval(from expected: GitLabMergeRequest, host: String, userID: Int,
                                    willSubmit: @escaping () -> Void,
                                    shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> MergeRequestApprovalProgress? {
        try await submitMergeRequestApproval(projectID: expected.projectID, iid: expected.iid, host: host, userID: userID,
            headToApprove: nil, requestToUnapprove: expected, willSubmit: willSubmit, shouldProceed: shouldProceed)
    }

    private func submitMergeRequestApproval(projectID: Int, iid: Int, host: String, userID: Int,
                                            headToApprove: String?, requestToUnapprove: GitLabMergeRequest? = nil,
                                            willSubmit: (() -> Void)?,
                                            shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> MergeRequestApprovalProgress? {
        let currentUser: GitLabAuthenticatedUser = try await mergeRequestAPI("/user", host: host)
        guard currentUser.id == userID else { throw GlabError.notAuthenticated }
        if let requestToUnapprove {
            // GitLab accepts a SHA for approval only, so read the revision again before removal.
            let current = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            guard current.state == .opened, MRAttentionRecord.sameContext(current, requestToUnapprove) else {
                throw CancellationError()
            }
        }
        guard shouldProceed() else { throw CancellationError() }
        let operation = headToApprove == nil ? "unapprove" : "approve"
        var arguments = ["--method", "POST"]
        if let headToApprove { arguments += ["--raw-field", "sha=\(headToApprove)"] }
        willSubmit?()
        let result: GitLabMergeRequestApprovalCounts = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/\(operation)",
            host: host, arguments: arguments, timeout: 30, shouldProceed: shouldProceed)
        guard let approverIDs = result.approverIDs, approverIDs.contains(userID) == (headToApprove != nil) else {
            throw GlabError.decoding("GitLab did not confirm the approval change")
        }
        return result.progress(projectID: projectID, iid: iid)
    }

    func fetchMergeRequestDiscussions(
        projectID: Int, iid: Int, host: String, timeout: TimeInterval = 45
    ) async throws -> [GitLabMergeRequestDiscussion] {
        let revision = accountRevision, executable = glabPath, readAt = Date()
        let discussions: [GitLabMergeRequestDiscussion] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/discussions?per_page=100",
            host: host, timeout: timeout
        )
        if !Task.isCancelled, EvidenceContext.sameAccountRevision(revision, accountRevision), executable == glabPath, host == resolvedHost, currentUsername != nil {
            rememberDiscussions(discussions, projectID: projectID, iid: iid, readAt: readAt)
        }
        return discussions
    }

    func fetchReviewAssignedMergeRequests(userID: Int, host: String) async throws -> [GitLabMergeRequest] {
        try await fetchMergeRequestPages(
            "/merge_requests?scope=all&state=opened&reviewer_id=\(userID)&per_page=100",
            host: host
        )
    }

    /// Only a fresh, account-bound read can retire a selected follow-up without running an agent.
    func areFeedbackThreadsResolved(_ noteIDs: Set<Int>, request: GitLabMergeRequest,
                                    target: MRAutomationScope.Target) async -> Bool {
        let revision = accountRevision
        guard !Task.isCancelled, !noteIDs.isEmpty, request.isOpen,
              request.projectID == target.projectID, request.iid == target.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
              resolvedHost == target.host, currentUsername == target.username,
              let discussions = try? await fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: target.host),
              GitLabMergeRequestDiscussion.allResolved(noteIDs, in: discussions),
              let user = try? await fetchAuthenticatedUser(host: target.host, expectedUsername: target.username),
              owns(request, userID: user.id), !Task.isCancelled, EvidenceContext.sameAccountRevision(revision, accountRevision),
              resolvedHost == target.host, currentUsername == target.username else { return false }
        return true
    }

    func fetchMergeRequestReviewers(projectID: Int, iid: Int, host: String) async throws -> [GitLabMergeRequestReviewer] {
        try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/reviewers?per_page=100",
            host: host
        )
    }

    func activeHumanReviewerUsername(userID: Int, host: String) async throws -> String? {
        struct Reviewer: Decodable {
            let id: Int
            let username: String
            let bot: Bool?
            let state: String
            let userType: String?
            enum CodingKeys: String, CodingKey { case id, username, bot, state; case userType = "user_type" }
        }
        guard userID > 0, resolvedHost == host, let username = currentUsername else { return nil }
        let revision = accountRevision
        let user: Reviewer = try await mergeRequestAPI("/users/\(userID)", host: host)
        guard !Task.isCancelled, resolvedHost == host, currentUsername == username, EvidenceContext.sameAccountRevision(revision, accountRevision),
              user.id == userID, AuthorFeedbackPolicy.AccountKind.classify(bot: user.bot, userType: user.userType) == .regular,
              user.state == "active", !user.username.isEmpty else { return nil }
        return user.username
    }

    func requestReReview(of request: GitLabMergeRequest, userID: Int,
                         host: String, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws {
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Request: Decodable { let iid: String }
                let mergeRequest: Request?
                let errors: [String]
            }
            struct Data: Decodable {
                let mergeRequestReviewerRereview: Payload?
            }
            struct Failure: Decodable { let message: String }
            let data: Data?
            let errors: [Failure]?
        }
        let query = """
            mutation($projectPath: ID!, $iid: String!, $userId: UserID!) {
              mergeRequestReviewerRereview(input: {projectPath: $projectPath, iid: $iid, userId: $userId}) {
                mergeRequest { iid } errors
              }
            }
            """
        let result: Response = try await mergeRequestWriteAPI(
            "graphql", host: host, arguments: [
                "--raw-field", "query=\(query)", "--raw-field", "projectPath=\(request.webURL.gitLabProjectPath)",
                "--raw-field", "iid=\(request.iid)", "--raw-field", "userId=gid://gitlab/User/\(userID)"
            ], shouldProceed: shouldProceed
        )
        let payload = result.data?.mergeRequestReviewerRereview
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
        try await fetchMergeRequestDependencySnapshot(projectID: projectID, iid: iid, host: host).requests
    }

    func fetchMergeDependencyReadiness(for request: GitLabMergeRequest, host: String) async throws
        -> MergeRequestDependencySummary.MergeReadiness {
        async let stackRead = fetchMergeRequestStackSnapshot(projectID: request.projectID, host: host)
        async let dependencyRead = fetchMergeRequestDependencySnapshot(projectID: request.projectID, iid: request.iid, host: host)
        let (stack, dependencies) = try await (stackRead, dependencyRead)
        var targetBranchRequests: [GitLabMergeRequest]?
        if request.targetBranch != stack.defaultBranch {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let targetProject = request.targetProjectID, targetProject == request.projectID,
                  !request.targetBranch.isEmpty,
                  let branch = request.targetBranch.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return .unavailable
            }
            targetBranchRequests = try await fetchMergeRequestPages(
                "/projects/\(targetProject)/merge_requests?state=all&scope=all&source_branch=\(branch)&per_page=100", host: host)
        }
        return MergeRequestDependencySummary.mergeReadiness(request: request, stack: stack,
            dependencies: dependencies, targetBranchRequests: targetBranchRequests)
    }

    /// A dependency without its nested MR is inaccessible, rather than absent.
    func fetchMergeRequestDependencySnapshot(projectID: Int, iid: Int, host: String) async throws -> GitLabMRDependencySnapshot {
        struct Dependency: Decodable {
            let blockingMergeRequest: GitLabMergeRequest?
            enum CodingKeys: String, CodingKey { case blockingMergeRequest = "blocking_merge_request" }
        }
        let dependencies: [Dependency] = try await fetchMergeRequestPages(
            "/projects/\(projectID)/merge_requests/\(iid)/blocks?per_page=100", host: host
        )
        return .init(requests: dependencies.compactMap(\.blockingMergeRequest),
                     hasHiddenDependency: dependencies.contains { $0.blockingMergeRequest == nil })
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

    @discardableResult
    func mergeMergeRequest(
        projectID: Int,
        iid: Int,
        headSHA: String,
        host: String,
        expectedUser: GitLabAuthenticatedUser,
        expectedContext: MergeRequestDependencySummary.Context? = nil,
        expectedDiscussionFingerprint: String? = nil,
        expectedSemanticContextFingerprint: String? = nil,
        action: MergeSubmissionAction = .mergeNow,
        expectedPolicy: GitLabMergeActionPolicy? = nil,
        expectedTrainRecoveryNoteIDs: Set<Int>? = nil,
        expectedPromptDiscussionDigest: String? = nil,
        onRecoveryQueueObserved: @MainActor () -> Void = {},
        permitsRequest: @escaping @MainActor @Sendable (GitLabMergeRequest) -> Bool = { _ in true },
        beforeWrite: @MainActor (Int?) throws -> Void = { _ in },
        shouldProceed: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> MergeSubmissionState {
        struct MergeResult: Decodable {
            let projectID: Int
            let iid: Int
            let state: GitLabMergeRequestState

            enum CodingKeys: String, CodingKey {
                case projectID = "project_id"
                case iid, state
            }
        }

        guard Self.isFullGitSHA(headSHA), action != .enqueue || expectedPolicy?.action == .enqueue else {
            throw GlabError.decoding("GitLab did not provide a verified merge action and source SHA")
        }
        guard let executable = glabPath else { throw GlabError.glabNotInstalled }
        let revision = accountRevision
        // Authenticate before the final source snapshot. An auth read must not
        // leave a same-head title/description edit unchecked before the merge.
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: expectedUser.username)
        guard user == expectedUser, glabPath == executable else { throw GlabError.notAuthenticated }
        let current = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
        let context = MergeRequestDependencySummary.Context(current)
        guard current.projectID == projectID, current.iid == iid,
              owns(current, userID: expectedUser.id), EvidenceContext.sameHead(headSHA, current.sha),
              current.webURL.isGitLabMergeRequest(host: host, iid: iid),
              expectedContext == nil || expectedContext == context else { throw CancellationError() }
        let expectedEvidence = EvidenceContext(
            discussionContent: expectedDiscussionFingerprint.map(DiscussionContentDigest.init),
            semanticContext: expectedSemanticContextFingerprint.map(SemanticContextDigest.init)
        )
        func matchesSubmissionEvidence(_ live: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion]) -> Bool {
            let observed = EvidenceContext(
                discussionContent: expectedEvidence.discussionContent == nil ? nil : ReviewVerdict.discussionContentDigest(discussions),
                semanticContext: expectedEvidence.semanticContext == nil ? nil : live.semanticContextDigest
            )
            return expectedEvidence.binds(to: observed, policy: .mergeSubmissionEvidence)
                && (expectedPromptDiscussionDigest == nil
                    || AutomaticActionPromptVerifier.digest(discussions) == expectedPromptDiscussionDigest)
        }
        func checkedObservation(_ outcome: MergeSubmissionState, live: GitLabMergeRequest) throws -> MergeSubmissionState {
            guard glabPath == executable, EvidenceContext.sameAccountRevision(revision, accountRevision), resolvedHost == host,
                  currentUsername == expectedUser.username else { throw GlabError.notAuthenticated }
            let expectedText = EvidenceContext(semanticContext: expectedEvidence.semanticContext)
            guard MergeRequestDependencySummary.Context(live) == context, owns(live, userID: expectedUser.id),
                  expectedTrainRecoveryNoteIDs != nil || expectedEvidence.semanticContext == nil
                    || expectedText.binds(to: .init(semanticContext: live.semanticContextDigest), policy: .mergeSubmissionEvidence)
            else { throw CancellationError() }
            try Task.checkCancellation()
            return outcome
        }
        func rememberRecoveryQueue(_ outcome: MergeSubmissionState) {
            if expectedTrainRecoveryNoteIDs != nil, outcome.isDelegated, glabPath == executable,
               EvidenceContext.sameAccountRevision(revision, accountRevision), resolvedHost == host, currentUsername == expectedUser.username {
                onRecoveryQueueObserved()
            }
        }
        if expectedPolicy != nil {
            let observed = try await observedMergeSubmission(current, action: action, host: host, usesMergeTrain: expectedPolicy?.usesMergeTrain == true)
            if observed != .none {
                rememberRecoveryQueue(observed)
                // A user may enqueue during this preflight. Recheck the session
                // and context after the awaited train read before recording it.
                let live = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
                return try checkedObservation(observed, live: live)
            }
            let policy = try await fetchMergeActionPolicy(projectID: projectID, host: host, request: current)
            guard policy == expectedPolicy, policy.action == action else { throw CancellationError() }
        }
        guard permitsRequest(current) else { throw CancellationError() }
        if expectedPolicy != nil {
            let approvals = try await fetchMergeRequestApprovalState(projectID: projectID, iid: iid, host: host)
            guard approvals.allRequiredRulesApproved else { throw CancellationError() }
        }
        guard current.isReadyForMergeSubmission(action) else { throw CancellationError() }
        guard try await fetchMergeDependencyReadiness(for: current, host: host) == .ready else { throw CancellationError() }
        let trainPreparation = expectedPolicy?.usesMergeTrain == true
            ? try await fetchMergeTrainPreparation(current, host: host) : nil
        if let conflict = trainPreparation?.conflict { throw conflict }
        var recoveredPipeline: GitLabMergeRequest.Pipeline?
        if let expectedTrainRecoveryNoteIDs {
            let observed = try await observedMergeSubmission(current, action: action, host: host)
            if observed.isDelegated {
                rememberRecoveryQueue(observed)
                let live = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
                return try checkedObservation(observed, live: live)
            }
            guard trainPreparation?.latestNoteID == expectedTrainRecoveryNoteIDs.max() else { throw CancellationError() }
            recoveredPipeline = try await verifyReplacementPipeline(for: current, host: host)
        }
        // Re-read after dependency I/O so same-head retargets cannot reuse the
        // checked graph. GitLab's merge SHA precondition protects only the source.
        async let finalRequest = fetchMergeRequest(projectID: projectID, iid: iid, host: host)
        var replacementContext: GitLabMergeRequest?
        if let expectedTrainRecoveryNoteIDs {
            async let drafts = fetchOwnDraftNoteCount(projectID: projectID, iid: iid, host: host, userID: expectedUser.id)
            let live = try await finalRequest
            let observed = try await observedMergeSubmission(live, action: action, host: host)
            if observed != .none {
                rememberRecoveryQueue(observed)
                return try checkedObservation(observed, live: live)
            }
            let pending = try await drafts
            let threads = try await fetchMergeRequestDiscussions(projectID: projectID, iid: iid, host: host)
            guard let sourceProject = context.sourceProjectID else { throw CancellationError() }
            async let replacement = fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            async let activeTrain = fetchActiveMergeTrainIIDs(projectID: projectID, host: host).contains(iid)
            async let source = fetchBranchHeadSHA(projectID: sourceProject, branch: context.source, host: host)
            let inTrain = try await activeTrain
            if inTrain { rememberRecoveryQueue(.inTrain) }
            let checked = try await replacement
            if inTrain { return try checkedObservation(.inTrain, live: checked) }
            if checked.hasQueuedMerge {
                rememberRecoveryQueue(.queued)
                return try checkedObservation(.queued, live: checked)
            }
            guard pending == 0,
                  try await EvidenceContext.sameHead(headSHA, source),
                  matchesSubmissionEvidence(checked, discussions: threads),
                  Set(threads.flatMap(\.notes).compactMap(\.id)) == expectedTrainRecoveryNoteIDs else { throw CancellationError() }
            replacementContext = checked
        } else if expectedDiscussionFingerprint != nil || expectedSemanticContextFingerprint != nil || expectedPromptDiscussionDigest != nil {
            async let discussions = fetchMergeRequestDiscussions(projectID: projectID, iid: iid, host: host)
            async let drafts = fetchOwnDraftNoteCount(projectID: projectID, iid: iid, host: host, userID: expectedUser.id)
            let (live, threads, pending) = try await (finalRequest, discussions, drafts)
            guard pending == 0, matchesSubmissionEvidence(live, discussions: threads) else {
                throw CancellationError()
            }
        }
        let final = if let replacementContext { replacementContext } else { try await finalRequest }
        guard MergeRequestDependencySummary.Context(final) == context, final.isReadyForMergeSubmission(action),
              owns(final, userID: expectedUser.id), permitsRequest(final) else { throw CancellationError() }
        // Outside merge trains, a successful pipeline changes the offered action to Merge now.
        if action == .enqueue, expectedPolicy?.usesMergeTrain == false, final.isReadyForMergeSubmission(.mergeNow) {
            throw CancellationError()
        }
        guard glabPath == executable, EvidenceContext.sameAccountRevision(revision, accountRevision), resolvedHost == host,
              currentUsername == expectedUser.username else { throw GlabError.notAuthenticated }
        try Task.checkCancellation()
        guard shouldProceed() else { throw CancellationError() }
        if let recoveredPipeline {
            guard let headPipeline = final.headPipeline, headPipeline.status == .success,
                  headPipeline.id == recoveredPipeline.id, headPipeline.projectID == recoveredPipeline.projectID,
                  EvidenceContext.sameHead(recoveredPipeline.sha, headPipeline.sha),
                  headPipeline.ref == nil || headPipeline.ref == recoveredPipeline.ref else { throw CancellationError() }
        }

        try beforeWrite(trainPreparation?.latestNoteID)
        let permitsWrite: @MainActor @Sendable () -> Bool = {
            self.owns(final, userID: expectedUser.id) && permitsRequest(final) && shouldProceed()
        }
        if action == .enqueue {
            let usesTrain = expectedPolicy?.usesMergeTrain == true
            let endpoint = usesTrain ? "/projects/\(projectID)/merge_trains/merge_requests/\(iid)"
                : "/projects/\(projectID)/merge_requests/\(iid)/merge"
            let _: Data = try await mergeRequestWriteAPI(endpoint, host: host,
                arguments: ["--method", usesTrain ? "POST" : "PUT", "--raw-field", "sha=\(headSHA)", "--field", "auto_merge=true"],
                timeout: 30, shouldProceed: permitsWrite, decode: { $0 })
            let updated = try await fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            guard updated.projectID == projectID, updated.iid == iid, EvidenceContext.sameHead(headSHA, updated.sha),
                  updated.webURL == current.webURL, updated.sourceBranch == current.sourceBranch,
                  updated.targetBranch == current.targetBranch, updated.sourceProjectID == current.sourceProjectID,
                  updated.targetProjectID == current.targetProjectID else {
                throw GlabError.decoding("GitLab merge queue context changed")
            }
            let outcome = try await observedMergeSubmission(updated, action: action, host: host, usesMergeTrain: usesTrain)
            if outcome == .none, usesTrain,
               let conflict = try await fetchMergeTrainPreparationConflict(updated, host: host) { throw conflict }
            guard outcome == .merged || outcome.isDelegated else {
                throw GlabError.decoding("GitLab did not confirm the merge queue request")
            }
            return outcome
        }
        let result: MergeResult = try await mergeRequestWriteAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/merge",
            host: host,
            arguments: ["--method", "PUT", "--raw-field", "sha=\(headSHA)"],
            timeout: 30, shouldProceed: permitsWrite
        )
        guard result.projectID == projectID, result.iid == iid, result.state == .merged else {
            throw GlabError.decoding("GitLab did not confirm the merge")
        }
        return .merged
    }

    nonisolated static func isFullGitSHA(_ sha: String) -> Bool {
        (sha.utf8.count == 40 || sha.utf8.count == 64) && sha.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private func fetchMergeRequestPages<Item: Decodable>(_ endpoint: String, host: String, timeout: TimeInterval = 45) async throws -> [Item] {
        try await mergeRequestAPI(
            endpoint,
            host: host,
            arguments: ["--paginate"],
            timeout: timeout,
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
        // Current reads use only pagination. Fields can implicitly turn glab api into POST.
        guard endpoint != "graphql", arguments.isEmpty || arguments == ["--paginate"] else { throw CancellationError() }
        return try await performMergeRequestAPI(endpoint, host: host, arguments: arguments, timeout: timeout,
                                               authorizeLaunch: nil, decode: decode)
    }

    func mergeRequestWriteAPI<Value: Decodable>(
        _ endpoint: String, host: String, arguments: [String], timeout: TimeInterval = 15,
        shouldProceed: @escaping @MainActor @Sendable () -> Bool,
        decode: (Data) throws -> Value = { try JSONDecoder().decode(Value.self, from: $0) }
    ) async throws -> Value {
        try await performMergeRequestAPI(endpoint, host: host, arguments: arguments, timeout: timeout,
                                        authorizeLaunch: shouldProceed, decode: decode)
    }

    private func performMergeRequestAPI<Value: Decodable>(
        _ endpoint: String, host: String, arguments: [String], timeout: TimeInterval,
        authorizeLaunch: (@MainActor @Sendable () -> Bool)?, decode: (Data) throws -> Value
    ) async throws -> Value {
        let data = try await readMergeRequestAPIResponse(endpoint, host: host, arguments: arguments,
                                                         timeout: timeout, authorizeLaunch: authorizeLaunch)
        do {
            return try decode(data)
        } catch {
            throw GlabError.decoding(error.localizedDescription)
        }
    }

    private func readMergeRequestAPIResponse(
        _ endpoint: String, host: String, arguments: [String], timeout: TimeInterval,
        authorizeLaunch: (@MainActor @Sendable () -> Bool)?
    ) async throws -> Data {
        guard let glabPath else { throw GlabError.glabNotInstalled }
        let output: ProcessRunner.Output
        do {
            if let authorizeLaunch {
                output = try await runWriteCommand(glabPath,
                    arguments: ["api", endpoint, "--hostname", host] + arguments,
                    environment: Self.shellEnvironment, timeout: timeout, shouldProceed: authorizeLaunch)
            } else {
                output = try await runCommand(glabPath,
                    arguments: ["api", endpoint, "--hostname", host] + arguments,
                    environment: Self.shellEnvironment, timeout: timeout)
            }
        } catch ProcessRunner.RunError.timedOut {
            throw GlabError.timedOut
        }

        guard output.exitCode == 0 else {
            throw GlabError.classify(exitCode: output.exitCode, stderr: output.stderr)
        }
        return output.stdout
    }
}
