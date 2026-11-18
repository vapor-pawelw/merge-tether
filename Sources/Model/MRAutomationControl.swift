import Foundation

/// Pure scope decisions behind the per-MR automation popover and menu; callers persist with an explicit `save()`.
enum MRAutomationControl {
    struct Summary: Equatable {
        let active: Bool
        let source: MRAutomationScope.Source
        let choice: MRAutomationScope.Choice
    }

    static func summary(_ scope: MRAutomationScope, target: MRAutomationScope.Target, isDraft: Bool) -> Summary {
        let status = scope.resolve(target, isDraft: isDraft)
        return .init(active: status.active, source: status.source, choice: target.iid == nil ? scope.manualChoice(for: target) : scope[target])
    }

    static func sourceLabel(_ source: MRAutomationScope.Source) -> LocalizedStringResource {
        switch source {
        case .global: .Menu.menuScopeSourceGlobal
        case .repository: .Menu.menuScopeSourceRepo
        case .mergeRequest: .Menu.menuScopeSourceMR
        case .draft: .Menu.menuScopeSourceDraft
        }
    }

    /// Enabling a Draft, directly or through a repository default that no longer pauses Drafts, needs confirmation.
    static func requiresDraftConfirmation(from current: MRAutomationScope, to proposed: MRAutomationScope,
                                          changing key: MRAutomationScope.Target,
                                          target: MRAutomationScope.Target, isDraft: Bool) -> Bool {
        let enablesThisDraft = isDraft && !current.resolve(target, isDraft: true).active
            && proposed.resolve(target, isDraft: true).active
        let enablesRepositoryDrafts = key.iid == nil && !proposed.pauseDraftsByDefault
            && !current.resolve(key).active && proposed.resolve(key).active
        return enablesThisDraft || enablesRepositoryDrafts
    }
}
