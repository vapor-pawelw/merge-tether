import Foundation

extension GlabService {
    func mergeWorkflowEvidence(
        projectID: Int, iid: Int, host: String, noteIDs: [Int] = [], jobID: Int? = nil
    ) async -> String {
        struct Diff: Decodable {
            let newPath: String
            let diff: String?

            enum CodingKeys: String, CodingKey {
                case newPath = "new_path"
                case diff
            }
        }
        let endpoint = "/projects/\(projectID)/merge_requests/\(iid)"
        async let changes: [Diff]? = try? mergeRequestAPI("\(endpoint)/diffs?per_page=10", host: host)
        async let discussions: [GitLabMergeRequestDiscussion]? = noteIDs.isEmpty ? nil
            : try? mergeRequestAPI("\(endpoint)/discussions?per_page=100", host: host, arguments: ["--paginate"],
                                   decode: { try GlabPaginatedJSON.decode(GitLabMergeRequestDiscussion.self, from: $0) })
        let (diffs, threads) = await (changes, discussions)
        let snippets = (diffs ?? []).map { "\($0.newPath)\n\($0.diff?.prefix(1600) ?? "")" }
        let notes = GitLabMergeRequestDiscussion.activeForReview(threads ?? []).flatMap(\.notes).compactMap { note -> String? in
            guard let id = note.id, noteIDs.contains(id), note.system == false, let body = note.body else { return nil }
            return "Note \(id): \(body.prefix(900))"
        }

        var evidence = ["Evidence is bounded to the first ten changed files and excerpts from selected discussion notes."]
        if !noteIDs.isEmpty {
            evidence += ["Selected discussion notes:", notes.isEmpty ? "Requested notes unavailable." : notes.joined(separator: "\n")]
        }
        evidence += ["Diff excerpts:", snippets.isEmpty ? "Diff evidence unavailable." : snippets.joined(separator: "\n")]
        if let jobID {
            evidence.append("GitLab CI job ID: \(jobID). Job logs were excluded. Use the supplied evidence to distinguish a hypothesis from a verified cause.")
        }
        return String(Self.redactWorkflowEvidence(evidence.joined(separator: "\n")).prefix(22_000))
    }

    nonisolated static func redactWorkflowEvidence(_ input: String) -> String {
        let tokenPattern = #"(?i)\b(?:glpat-|gloas-|glrt-|glcbt-|sk-[A-Za-z0-9_-]*-)[A-Za-z0-9_-]{8,}\b"#
        let valuePattern = #"(?im)(\b(?:authorization|password|secret|[a-z0-9_]*token|[a-z0-9_]*api_key)\s*[:=]\s*)[^\r\n]+"#
        let privateKeyPattern = #"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#
        return input
            .replacingOccurrences(of: tokenPattern, with: "[redacted]", options: .regularExpression)
            .replacingOccurrences(of: valuePattern, with: "$1[redacted]", options: .regularExpression)
            .replacingOccurrences(of: privateKeyPattern, with: "[redacted private key]", options: .regularExpression)
    }

    func retryVerifiedInfrastructureJob(
        _ jobID: Int, pipelineID: Int, projectID: Int, host: String,
        beforeRetry: @MainActor () async throws -> Void = {},
        shouldProceed: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        struct Job: Decodable {
            struct Pipeline: Decodable { let id: Int }
            let id: Int
            let status: GitLabPipelineStatus
            let allow_failure: Bool?
            let failure_reason: String?
            let pipeline: Pipeline
        }

        let path = "/projects/\(projectID)/jobs/\(jobID)"
        let job: Job = try await mergeRequestAPI(path, host: host)
        guard job.id == jobID, job.pipeline.id == pipelineID, job.status == .failed,
              job.failure_reason == "runner_system_failure", job.allow_failure == false,
              shouldProceed()
        else { throw CancellationError() }
        try await beforeRetry()
        guard shouldProceed() else { throw CancellationError() }
        struct Replacement: Decodable {
            let id: Int
            let pipeline: Job.Pipeline?
        }
        let replacement: Replacement = try await mergeRequestWriteAPI("\(path)/retry", host: host,
            arguments: ["--method", "POST"], shouldProceed: shouldProceed)
        guard replacement.id > 0, replacement.id != jobID,
              replacement.pipeline.map({ $0.id == pipelineID }) != false else {
            throw GlabError.decoding("GitLab did not confirm a replacement for the retried job")
        }
    }
}
