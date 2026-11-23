import Foundation
import MergeTetherRemote

@MainActor extension TodoMonitorService {
    func makeIssueCoordinator() -> MRIssueCoordinator {
        let file = InstallationStorage.current.root.appending(path: "Merge Request Issues/cache.json")
        return MRIssueCoordinator(file: file, isCurrentAccount: { [weak self] target, revision in
            self?.isCurrentIssueAccount(target, revision: revision) == true
        }, isEligible: { [weak self] request, target in
            self?.permitsIssueAssessment(for: request, target: target) == true
        }, readCandidates: { [glab] request, target in
            try await glab.fetchIssueCandidates(for: request, host: target.host)
        }, readReferencedRequests: { [glab] request, target in
            try await glab.fetchIssueReferencedMergeRequests(for: request, host: target.host)
        }, assess: { [weak self] requests in
            guard let self else { return nil }
            let configuration = settings.automation, revision = glab.accountRevision
            let canAssess: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return settings.automation == configuration && requests.allSatisfy {
                    isCurrentIssueAccount($0.target, revision: revision)
                        && permitsIssueAssessment(for: $0.request, target: $0.target)
                }
            }
            guard canAssess(), !Task.isCancelled else { return nil }
            let status: AssistantDependencyStatus
            if let known = assistantDependencies.statuses[configuration.assistant], known.isReady { status = known }
            else { status = await assistantDependencies.check(configuration.assistant) }
            guard case .ready(let executable) = status, canAssess(), !Task.isCancelled else { return nil }
            let issues = try await MRIssueAssessor.run(requests, configuration: configuration,
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

    func markBoardIssueRefresh() {
        if mergeRequestIssues != nil { forcedIssueBoardRevision = glab.accountRevision }
    }

    func assessCatalogIssues(_ requests: [GitLabMergeRequest]) {
        guard let mergeRequestIssues else { return }
        let revision = glab.accountRevision
        let force = forcedIssueBoardRevision == revision
        forcedIssueBoardRevision = nil
        guard force || issueDetailsRefreshes == 0 else { return }
        let targets = requests.compactMap { scopeTarget(projectID: $0.projectID, iid: $0.iid, url: $0.webURL) }
        mergeRequestIssues.requestBoardAssessment(for: targets, revision: revision, force: force)
    }

    func enqueueIssueMetadataRefresh(projectID: Int, iid: Int, host: String, username: String) {
        guard mergeRequestIssues != nil else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        let revision = glab.accountRevision
        Task(priority: .utility) { [weak self] in
            guard let self, let mergeRequestIssues, isCurrentIssueAccount(target, revision: revision) else { return }
            let startedAt = Date()
            guard let request = try? await glab.fetchMergeRequest(projectID: projectID, iid: iid, host: host),
                  !Task.isCancelled, isCurrentIssueAccount(target, revision: revision) else { return }
            recordBoardDisplayRequest(request, for: target, url: request.webURL, accountRevision: revision, readStartedAt: startedAt)
            mergeRequestIssues.requestAssessment(for: request, target: target, revision: revision, force: true)
        }
    }

    private func permitsIssueAssessment(for request: GitLabMergeRequest, target: MRAutomationScope.Target) -> Bool {
        // Draft action restrictions do not apply to read-only board metadata.
        request.state == "opened" && settings.automaticWritesAllowed && settings.automation.scope.resolve(target).active
    }

    private func isCurrentIssueAccount(_ target: MRAutomationScope.Target, revision: UInt64) -> Bool {
        glab.accountRevision == revision && glab.resolvedHost == target.host && glab.currentUsername == target.username
            && !settings.ignoredMergeRequests.contains(target)
    }
}
