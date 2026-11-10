import Foundation

struct PipelineRefreshAttempt: Codable, Hashable {
    let target: MRAutomationScope.Target
    let userID: Int
    let oldPipelineID: Int
    let sourceProjectID: Int
    let sourceBranch: String
    let sourceSHA: String
    let targetProjectID: Int
    let targetBranch: String
    let targetSHA: String
    var createdPipelineID: Int? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.userID == rhs.userID && lhs.oldPipelineID == rhs.oldPipelineID
            && lhs.sourceProjectID == rhs.sourceProjectID && lhs.sourceBranch == rhs.sourceBranch
            && lhs.sourceSHA == rhs.sourceSHA && lhs.targetProjectID == rhs.targetProjectID
            && lhs.targetBranch == rhs.targetBranch && lhs.targetSHA == rhs.targetSHA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(target)
        hasher.combine(userID)
        hasher.combine(oldPipelineID)
        hasher.combine(sourceProjectID)
        hasher.combine(sourceBranch)
        hasher.combine(sourceSHA)
        hasher.combine(targetProjectID)
        hasher.combine(targetBranch)
        hasher.combine(targetSHA)
    }
}

enum PipelineRefreshError: LocalizedError {
    case alreadyAttempted, ownershipReserved, unconfirmedResponse, persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyAttempted: String(localized: .PipelineAutomation.pipelineRefreshAlreadyAttempted)
        case .ownershipReserved: String(localized: .PipelineAutomation.pipelineRefreshOwnershipReserved)
        case .unconfirmedResponse: String(localized: .PipelineAutomation.pipelineRefreshUnconfirmedResponse)
        case .persistenceUnavailable: String(localized: .PipelineAutomation.pipelineRefreshPersistenceUnavailable)
        }
    }
}

extension GlabService {
    /// Refreshing CI is separate from repeating an earlier code worker. The
    /// durable attempt is written before POST, including when its reply is lost.
    func refreshStaleFailedPipeline(
        for request: GitLabMergeRequest, host: String, expectedUser: GitLabAuthenticatedUser,
        settings: SettingsManager, detector: ExistingPipelineWorkDetector = .init(),
        shouldProceed: @MainActor () -> Bool
    ) async throws -> Bool {
        let proof: StalePipelineTarget
        do {
            _ = try await verifiedFailedPipeline(for: request, host: host, expectedUser: expectedUser)
            return false
        } catch GitLabPipelineEvidenceError.staleTarget(let stale) { proof = stale }

        let configuration = settings.automation
        let target = MRAutomationScope.Target(host: host, username: expectedUser.username,
                                             projectID: request.projectID, iid: request.iid)
        func permitted() -> Bool {
            configuration == settings.automation && configuration.autoClaimPipelineFailures
                && configuration.workflowRules[.pipelineFailure].mode == .assistant
                && configuration.workflowRules[.pipelineFailure].includes(request)
                && configuration.scope.permits(request, host: host, username: expectedUser.username)
                && configuration.scope.permits(proof.request, host: host, username: expectedUser.username)
                && !settings.ignoredMergeRequests.contains(target)
                && request.author.id == expectedUser.id && request.hasConflicts == false
                && resolvedHost == host && currentUsername == expectedUser.username
                && accountRevision == proof.accountRevision && shouldProceed()
        }
        guard permitted(), let oldID = proof.pipeline.id, let sourceProject = request.sourceProjectID,
              let source = request.sha, let targetProject = request.targetProjectID else { throw CancellationError() }
        let attempt = PipelineRefreshAttempt(target: target, userID: expectedUser.id, oldPipelineID: oldID,
            sourceProjectID: sourceProject, sourceBranch: request.sourceBranch, sourceSHA: source,
            targetProjectID: targetProject, targetBranch: request.targetBranch, targetSHA: proof.targetHeadSHA)
        if let existing = settings.pipelineRefreshAttempts.first(where: { $0 == attempt }) {
            guard existing.createdPipelineID != nil else { throw PipelineRefreshError.alreadyAttempted }
            return true
        }
        let key = ExistingPipelineWorkDetector.Key(host: host, projectID: request.projectID,
                                                  mergeRequestIID: request.iid, pipelineID: oldID)
        guard let reservation = try detector.registerRun(for: key, explicitRetry: true) else {
            throw PipelineRefreshError.ownershipReserved
        }
        defer { try? detector.finishHandoff(for: reservation) }

        // Recheck after acquiring the lease; another route may have refreshed
        // the MR while the first evidence snapshot was being read.
        do {
            _ = try await verifiedFailedPipeline(for: request, host: host, expectedUser: expectedUser)
            throw CancellationError()
        } catch GitLabPipelineEvidenceError.staleTarget(let latest) {
            guard latest.targetHeadSHA == proof.targetHeadSHA, latest.user == proof.user,
                  configuration.scope.permits(latest.request, host: host, username: expectedUser.username)
            else { throw CancellationError() }
        }
        guard permitted(), !settings.pipelineRefreshAttempts.contains(attempt) else { throw CancellationError() }
        guard settings.savePipelineRefreshAttempt(attempt) else { throw PipelineRefreshError.persistenceUnavailable }
        guard permitted() else { throw CancellationError() }
        let created: GitLabMergeRequest.Pipeline = try await mergeRequestAPI(
            "/projects/\(request.projectID)/merge_requests/\(request.iid)/pipelines", host: host,
            arguments: ["--method", "POST"]
        )
        guard let id = created.id, id > 0, id != oldID,
              let sha = created.sha, Self.isFullGitSHA(sha) else { throw PipelineRefreshError.unconfirmedResponse }
        let confirmed: GitLabMergeRequest.Pipeline = try await mergeRequestAPI(
            "/projects/\(targetProject)/pipelines/\(id)", host: host
        )
        if confirmed.ref == "refs/merge-requests/\(request.iid)/merge" {
            struct Commit: Decodable {
                let id: String
                let parentIDs: [String]
                enum CodingKeys: String, CodingKey { case id; case parentIDs = "parent_ids" }
            }
            let commit: Commit = try await mergeRequestAPI(
                "/projects/\(targetProject)/repository/commits/\(sha)", host: host
            )
            guard commit.id == sha, commit.parentIDs.count == 2,
                  Set(commit.parentIDs) == Set([source, proof.targetHeadSHA])
            else { throw PipelineRefreshError.unconfirmedResponse }
        }
        let user = try await fetchAuthenticatedUser(host: host, expectedUsername: expectedUser.username)
        let current = try await fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
        let sourceHead = try await fetchBranchHeadSHA(projectID: sourceProject, branch: request.sourceBranch, host: host)
        let targetHead = try await fetchBranchHeadSHA(projectID: targetProject, branch: request.targetBranch, host: host)
        guard permitted(), user == expectedUser, sourceHead == source, targetHead == proof.targetHeadSHA,
              current.state == "opened", current.author.id == expectedUser.id, current.sha == source,
              configuration.scope.permits(current, host: host, username: expectedUser.username),
              current.hasConflicts == false,
              current.sourceProjectID == sourceProject, current.sourceBranch == request.sourceBranch,
              current.targetProjectID == targetProject, current.targetBranch == request.targetBranch,
              confirmed.id == id, confirmed.projectID == targetProject, confirmed.sha == sha,
              created.projectID == nil || created.projectID == targetProject, created.ref == confirmed.ref,
              confirmed.ref == "refs/merge-requests/\(request.iid)/merge"
                || (confirmed.ref == "refs/merge-requests/\(request.iid)/head" && sha == source)
        else { throw PipelineRefreshError.unconfirmedResponse }
        var completedAttempt = attempt
        completedAttempt.createdPipelineID = id
        settings.pipelineRefreshAttempts.update(with: completedAttempt)
        settings.save()
        return true
    }
}
