import Foundation

extension TodoMonitorService {
    func setAutoMergePreference(_ preference: MRAutoMergePreference, for target: MRAutomationScope.Target) async {
        guard target.iid != nil, settings.autoMergePreference(for: target) != preference else { return }
        settings.setAutoMergePreference(preference, for: target)
        guard settings.save(), preference != .off, settings.automaticPublicWritesAllowed,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
        await authoredMergeRequests.resumeAutomaticMerge(for: target)
    }

    /// Restoring inheritance immediately checks this action under automatic permissions.
    /// Proof completion still emits a normal refresh event; independently enabled
    /// background work continues without using the manual publication bypass.
    func setAutomaticAction(_ action: MRAutomaticAction, enabled: Bool,
                            for target: MRAutomationScope.Target) async {
        if action == .merge {
            await setAutoMergePreference(enabled ? .default : .off, for: target)
            return
        }
        let changed = settings.actionIsAutomatic(action, for: target) != enabled
        settings.setActionAutomatic(action, enabled: enabled, for: target)
        settings.save()
        guard settings.automaticWritesAllowed, changed, enabled,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
        await attention.resumeAutomaticAction(action, for: target)
    }
}
