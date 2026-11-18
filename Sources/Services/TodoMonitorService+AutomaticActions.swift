import Foundation

extension TodoMonitorService {
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

    func setAutomaticActionPreference(_ preference: MRAutomationPreference, for action: MRAutomaticAction,
                                      target: MRAutomationScope.Target) async {
        guard target.iid != nil, settings.storedActionPreference(action, for: target) != preference else { return }
        settings.setActionPreference(preference, for: action, target: target)
        guard settings.save(), preference != .off, settings.automaticPublicWritesAllowed,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
        if action == .merge { await authoredMergeRequests.resumeAutomaticMerge(for: target) }
        else { await attention.resumeAutomaticAction(action, for: target) }
    }
}
