import Foundation
import MergeTetherRemote

@MainActor extension TodoMonitorService {
    func makeIssueCoordinator() -> MRIssueCoordinator {
        let file = InstallationStorage.current.root.appending(path: "Merge Request Issues/cache.json")
        return MRIssueCoordinator(file: file, isCurrentAccount: { [weak self] target, revision in
            self?.isCurrentIssueAccount(target, revision: revision) == true
        }, readClosing: { [glab] target in
            guard let iid = target.iid else { throw CancellationError() }
            return try await glab.fetchClosingIssues(projectID: target.projectID, iid: iid, host: target.host)
        }, assess: { [weak self] request, target in
            guard let self else { return nil }
            let configuration = settings.automation, revision = glab.accountRevision
            let canAssess: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return isCurrentIssueAccount(target, revision: revision) && settings.automation == configuration
                    && settings.automaticWritesAllowed
                    && configuration.scope.permits(request, host: target.host, username: target.username)
            }
            guard canAssess(), !Task.isCancelled else { return nil }
            let status: AssistantDependencyStatus
            if let known = assistantDependencies.statuses[configuration.assistant], known.isReady { status = known }
            else { status = await assistantDependencies.check(configuration.assistant) }
            guard case .ready(let executable) = status, canAssess(), !Task.isCancelled else { return nil }
            let issues = try await MRIssueAssessor.run(request: request, target: target, configuration: configuration,
                executable: executable, shouldProceed: canAssess)
            guard canAssess(), !Task.isCancelled else { return nil }
            return issues
        })
    }

    func issueTags(for request: GitLabMergeRequest?) -> [RemoteMRIssue] {
        guard let mergeRequestIssues, let request,
              let target = scopeTarget(projectID: request.projectID, iid: request.iid, url: request.webURL)
        else { return [] }
        return mergeRequestIssues.issues(for: request, target: target, revision: glab.accountRevision)
    }

    func requestIssueAssessment(for request: GitLabMergeRequest?) {
        guard let request, let target = scopeTarget(projectID: request.projectID, iid: request.iid, url: request.webURL)
        else { return }
        mergeRequestIssues?.requestAssessment(for: request, target: target, revision: glab.accountRevision)
    }

    func refreshIssueMetadata(projectID: Int, iid: Int, host: String, username: String) async {
        guard let mergeRequestIssues else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        let revision = glab.accountRevision
        guard isCurrentIssueAccount(target, revision: revision) else { return }
        let startedAt = Date()
        guard let request = try? await glab.fetchMergeRequest(projectID: projectID, iid: iid, host: host),
              !Task.isCancelled, isCurrentIssueAccount(target, revision: revision) else { return }
        recordBoardDisplayRequest(request, for: target, url: request.webURL, accountRevision: revision, readStartedAt: startedAt)
        mergeRequestIssues.observe(request, target: target, revision: revision, at: startedAt, assessExternal: true, refreshClosing: true)
    }

    private func isCurrentIssueAccount(_ target: MRAutomationScope.Target, revision: UInt64) -> Bool {
        glab.accountRevision == revision && glab.resolvedHost == target.host && glab.currentUsername == target.username
            && !settings.ignoredMergeRequests.contains(target)
    }
}
