import Foundation

extension TodoMonitorService {
    func changePersonalApproval(_ change: PersonalMRApproval, for request: GitLabMergeRequest,
                                accountRevision: UInt64) async -> MergeRequestAttentionMonitor.PersonalApprovalResult {
        let result = await attention.changePersonalApproval(change, for: request, accountRevision: accountRevision)
        if result == .completed, glab.accountRevision == accountRevision,
           let target = scopeTarget(projectID: request.projectID, iid: request.iid, url: request.webURL) {
            automationToggleNotices.post(.approvalChanged(target: target, removed: change == .remove))
        }
        return result
    }

    func setAutoMergePreference(_ preference: MRAutomationPreference, for target: MRAutomationScope.Target) async {
        await setAutomaticActionPreference(preference, for: .merge, target: target)
    }

    /// Restoring inheritance immediately checks this action under automatic permissions.
    /// Proof completion still emits a normal refresh event; independently enabled
    /// background work continues without using the manual publication bypass.
    func setAutomaticAction(_ action: MRAutomaticAction, enabled: Bool,
                            for target: MRAutomationScope.Target) async {
        await setAutomaticActionPreference(enabled ? .default : .off, for: action, target: target)
    }

    @discardableResult
    func setAutomaticActionPreference(_ preference: MRAutomationPreference, for action: MRAutomaticAction,
                                      target: MRAutomationScope.Target) async -> Bool {
        guard target.iid != nil else { return false }
        guard settings.storedActionPreference(action, for: target) != preference else { return true }
        settings.setActionPreference(preference, for: action, target: target)
        guard settings.save() else { return false }
        guard preference != .off, settings.automaticPublicWritesAllowed,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else { return true }
        if action == .merge { await authoredMergeRequests.resumeAutomaticMerge(for: target) }
        else { await attention.resumeAutomaticAction(action, for: target) }
        return true
    }
}
