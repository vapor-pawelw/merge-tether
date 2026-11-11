import Foundation

struct AutomationSettingsSaveState {
    private(set) var accepted: AutomationSettings
    private(set) var runtimeSavePending = false
    private(set) var failed = false

    init(accepted: AutomationSettings, runtimeSavePending: Bool = false) {
        self.accepted = accepted
        self.runtimeSavePending = runtimeSavePending
        failed = runtimeSavePending
    }

    mutating func begin() { runtimeSavePending = true }

    mutating func runtimeSaved(_ configuration: AutomationSettings, succeeded: Bool) {
        failed = !succeeded
        guard succeeded else { return }
        accepted = configuration
        runtimeSavePending = false
    }

    mutating func historySaved(succeeded: Bool) { failed = !succeeded }

    mutating func updateSavedScope(_ scope: MRAutomationScope) { accepted.scope = scope }

    mutating func revert() -> AutomationSettings {
        failed = runtimeSavePending
        return accepted
    }

    func canApply(draft: AutomationSettings, custom: AutomationProfileSnapshot?, savedCustom: AutomationProfileSnapshot?) -> Bool {
        runtimeSavePending || failed || draft != accepted || custom != savedCustom
    }
}
