import Foundation

struct StalePipelineTarget: Sendable {
    let request: GitLabMergeRequest
    let pipeline: GitLabMergeRequest.Pipeline
    let user: GitLabAuthenticatedUser
    let targetHeadSHA: String
    let accountRevision: UInt64
}

enum GitLabPipelineEvidenceError: Error {
    case staleTarget(StalePipelineTarget)
}

extension GlabService {
    func verifiedFailedPipeline(
        for request: GitLabMergeRequest, host: String, expectedUser: GitLabAuthenticatedUser? = nil
    ) async throws -> GitLabMergeRequest.Pipeline {
        try await verifiedPipeline(for: request, host: host, expectedStatus: "failed", expectedUser: expectedUser)
    }

    func verifiedSuccessfulPipeline(
        for request: GitLabMergeRequest, host: String, expectedUser: GitLabAuthenticatedUser? = nil
    ) async throws -> GitLabMergeRequest.Pipeline {
        try await verifiedPipeline(for: request, host: host, expectedStatus: "success", expectedUser: expectedUser)
    }

    /// A merge-result SHA belongs to GitLab's synthetic merge commit, not the
    /// source branch. Bind the immutable pipeline commit to both live parents;
    /// GitLab can regenerate the merge ref without replacing head_pipeline.
    private func verifiedPipeline(
        for request: GitLabMergeRequest, host: String, expectedStatus: String,
        expectedUser: GitLabAuthenticatedUser?
    ) async throws -> GitLabMergeRequest.Pipeline {
        let revision = accountRevision
        guard resolvedHost == host, let username = currentUsername,
              request.state == "opened", request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              let source = request.sha, Self.isFullGitSHA(source),
              let sourceProject = request.sourceProjectID, sourceProject > 0,
              let targetProject = request.targetProjectID, targetProject == request.projectID,
              let head = request.headPipeline, head.status == expectedStatus,
              let id = head.id, id > 0, let project = head.projectID, project > 0,
              let sha = head.sha, Self.isFullGitSHA(sha)
        else { throw CancellationError() }
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: username)
        guard expectedUser == nil || expectedUser == user else { throw CancellationError() }
        let path = "/projects/\(project)/pipelines/\(id)"
        let pipeline: GitLabMergeRequest.Pipeline = try await mergeRequestAPI(path, host: host)
        guard pipeline.id == id, pipeline.projectID == project, pipeline.sha == sha,
              pipeline.status == expectedStatus, let ref = pipeline.ref,
              head.ref == nil || head.ref == ref
        else { throw CancellationError() }

        let mergeRef = "refs/merge-requests/\(request.iid)/merge"
        let headRef = "refs/merge-requests/\(request.iid)/head"
        let mergedResult = ref == mergeRef
        if mergedResult {
            guard project == targetProject else { throw CancellationError() }
        } else {
            guard sha == source,
                  (ref == request.sourceBranch && project == sourceProject)
                    || (ref == headRef && (project == sourceProject || project == targetProject))
            else { throw CancellationError() }
        }
        let sourceHead = try await fetchBranchHeadSHA(projectID: sourceProject, branch: request.sourceBranch, host: host)
        guard sourceHead == source else { throw CancellationError() }
        var targetHead: String?
        var hasStaleTarget = false
        if mergedResult {
            struct Commit: Decodable {
                let id: String
                let parentIDs: [String]
                enum CodingKeys: String, CodingKey { case id; case parentIDs = "parent_ids" }
            }
            let target = try await fetchBranchHeadSHA(projectID: targetProject, branch: request.targetBranch, host: host)
            let commit: Commit = try await mergeRequestAPI(
                "/projects/\(targetProject)/repository/commits/\(sha)", host: host
            )
            guard commit.id == sha, commit.parentIDs.count == 2,
                  commit.parentIDs.contains(source), Set(commit.parentIDs).count == 2,
                  commit.parentIDs.allSatisfy(Self.isFullGitSHA), source != target
            else { throw CancellationError() }
            hasStaleTarget = Set(commit.parentIDs) != Set([source, target])
            targetHead = target
        }

        let current = try await fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        guard current.state == request.state, current.author.id == request.author.id, current.sha == source,
              current.sourceProjectID == sourceProject, current.sourceBranch == request.sourceBranch,
              current.targetProjectID == targetProject, current.targetBranch == request.targetBranch,
              current.headPipeline?.id == id, current.headPipeline?.projectID == project,
              current.headPipeline?.sha == sha, current.headPipeline?.status == expectedStatus,
              current.headPipeline?.ref == nil || current.headPipeline?.ref == ref
        else { throw CancellationError() }
        let finalSource = try await fetchBranchHeadSHA(projectID: sourceProject, branch: request.sourceBranch, host: host)
        guard finalSource == source else { throw CancellationError() }
        if let targetHead {
            let finalTarget = try await fetchBranchHeadSHA(projectID: targetProject, branch: request.targetBranch, host: host)
            guard finalTarget == targetHead else { throw CancellationError() }
        }
        let finalPipeline: GitLabMergeRequest.Pipeline = try await mergeRequestAPI(path, host: host)
        let finalUser = try await fetchAuthenticatedUser(host: host, expectedUsername: username)
        guard finalPipeline.id == id, finalPipeline.projectID == project, finalPipeline.sha == sha,
              finalPipeline.status == expectedStatus, finalPipeline.ref == ref,
              finalUser == user, accountRevision == revision,
              resolvedHost == host, currentUsername == username, !Task.isCancelled
        else { throw CancellationError() }
        if hasStaleTarget, let targetHead {
            throw GitLabPipelineEvidenceError.staleTarget(.init(
                request: current, pipeline: pipeline, user: user, targetHeadSHA: targetHead, accountRevision: revision
            ))
        }
        return pipeline
    }
}
