import Foundation

extension GlabService {
    struct ReviewDiffRefs: Decodable {
        let base: String
        let start: String
        let head: String
        enum CodingKeys: String, CodingKey { case base = "base_sha", start = "start_sha", head = "head_sha" }
    }

    func reviewDiffRefs(projectID: Int, iid: Int, host: String) async throws -> ReviewDiffRefs {
        struct Details: Decodable {
            let diff_refs: ReviewDiffRefs
        }
        let details: Details = try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)", host: host)
        return details.diff_refs
    }

    func reviewDiffs(projectID: Int, iid: Int, host: String) async throws -> [GitLabReviewDiff] {
        try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/diffs?per_page=100", host: host,
            arguments: ["--paginate"], timeout: 45, decode: { try GlabPaginatedJSON.decode(GitLabReviewDiff.self, from: $0) })
    }

    func createReviewDraft(_ draft: ReadOnlyReviewResult.Draft, position: GitLabReviewDiff?, refs: ReviewDiffRefs?,
                           target: GitLabMergeRequest, userID: Int, host: String, temporaryDirectory: URL,
                           shouldProceed: @escaping @MainActor @Sendable () -> Bool) async throws -> GitLabDraftNote {
        guard draft.isValid else { throw CancellationError() }
        if let discussionID = draft.discussionID {
            return try await createDraftReply(projectID: target.projectID, iid: target.iid, host: host, userID: userID,
                discussionID: discussionID, body: draft.body, shouldProceed: shouldProceed)
        }
        var payload: [String: Any] = ["note": draft.body, "resolve_discussion": false]
        if let line = draft.line {
            guard let position, let refs, position.newPath == draft.path, position.containsNewLine(line),
                  refs.head == target.sha, [refs.base, refs.start, refs.head].allSatisfy(Self.isFullGitSHA) else { throw CancellationError() }
            payload["position"] = ["position_type": "text", "old_path": position.oldPath, "new_path": position.newPath,
                "new_line": line, "base_sha": refs.base, "start_sha": refs.start, "head_sha": refs.head]
        }
        let body = temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: body) }
        try JSONSerialization.data(withJSONObject: payload).write(to: body, options: .atomic)
        let arguments = ["--method", "POST", "--header", "Content-Type: application/json", "--input", body.path]
        let saved: GitLabDraftNote = try await mergeRequestWriteAPI("/projects/\(target.projectID)/merge_requests/\(target.iid)/draft_notes",
            host: host, arguments: arguments, timeout: 30, shouldProceed: shouldProceed)
        guard (saved.id ?? 0) > 0, saved.authorID == userID, saved.note == draft.body,
              saved.discussionID == nil, saved.position?.newLine == draft.line,
              saved.position?.newPath == draft.path, AutomaticPublicationPolicy.safeForAutomaticPublication(saved) else {
            throw GlabError.decoding("GitLab did not confirm the requested private review draft")
        }
        return saved
    }
}
