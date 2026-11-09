import Foundation

extension SettingsManager {
    /// The user's two-state MR preference only; callers must still check global permission,
    /// whole-MR scope and current action evidence before performing an automatic write.
    func actionIsAutomatic(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) -> Bool {
        switch action {
        case .commentPublication: !autoPublishOptOuts.contains(target)
        case .merge: !autoMergeOptOuts.contains(target)
        case .approval: !autoApproveOptOuts.contains(target)
        }
    }

    func setActionAutomatic(_ action: MRAutomaticAction, enabled: Bool, for target: MRAutomationScope.Target) {
        guard target.iid != nil else { return }
        switch action {
        case .commentPublication:
            if enabled { autoPublishOptOuts.remove(target) } else { autoPublishOptOuts.insert(target) }
        case .merge:
            if enabled { autoMergeOptOuts.remove(target) } else { autoMergeOptOuts.insert(target) }
        case .approval:
            if enabled { autoApproveOptOuts.remove(target) } else { autoApproveOptOuts.insert(target) }
        }
    }

    /// Policy admission only. Action executors retain their current fresh evidence checks.
    func permitsAutomaticAction(_ action: MRAutomaticAction, for request: GitLabMergeRequest,
                                target: MRAutomationScope.Target) -> Bool {
        guard request.projectID == target.projectID, request.iid == target.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
              actionIsAutomatic(action, for: target),
              automation.scope.permits(request, host: target.host, username: target.username) else { return false }
        return switch action {
        case .commentPublication: automation.publicationMode != .manual
        case .merge: automation.permitsAutoMerge(project: request.webURL.gitLabProjectPath)
        case .approval: automation.autoApproveEnabled
        }
    }
}
