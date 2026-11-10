import Foundation

extension TodoMonitorService {
    /// Restoring inheritance immediately checks this action under automatic permissions.
    /// Proof completion still emits a normal refresh event; independently enabled
    /// background work continues without using the manual publication bypass.
    func setAutomaticAction(_ action: MRAutomaticAction, enabled: Bool,
                            for target: MRAutomationScope.Target) async {
        let changed = settings.actionIsAutomatic(action, for: target) != enabled
        settings.setActionAutomatic(action, enabled: enabled, for: target)
        settings.save()
        guard settings.automaticWritesAllowed, changed, enabled,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
        switch action {
        case .commentPublication, .approval: await attention.resumeAutomaticAction(action, for: target)
        case .merge: await authoredMergeRequests.resumeAutomaticMerge(for: target)
        }
    }
}
