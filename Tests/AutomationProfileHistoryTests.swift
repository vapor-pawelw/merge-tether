import Foundation
import SwiftUI
import Testing
@testable import GitLabTodos

@MainActor
struct AutomationProfileHistoryTests {
    private func fixture(faults: Bool = false, _ body: (UserDefaults, SettingsManager) throws -> Void) throws {
        let suite = "AutomationProfileHistoryTests.\(UUID())"
        let defaults: UserDefaults = try #require(faults ? PersistenceFaultDefaults(suiteName: suite) : UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, SettingsManager(defaults: defaults))
    }

    private func customSettings() -> AutomationSettings {
        var configuration = AutomationSettings()
        configuration.applyPreset(.trusted, for: .codex)
        configuration.allowFollowUpPush = false
        return configuration
    }

    @Test func savedCustomSurvivesChoosingAnotherProfileAndRestoresAfterReload() throws {
        try fixture { defaults, settings in
            settings.automation = customSettings()
            let custom = try #require(AutomationProfileSnapshot.custom(from: settings.automation))
            #expect(settings.save())
            #expect(settings.automationProfileHistory.save(custom))
            settings.automation.applyPreset(.full, for: .codex)
            #expect(settings.save())
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.automation.matchingPreset == .full)
            #expect(restored.automationProfileHistory.lastGood == custom)
            var draft = restored.automation
            var history = restored.automationProfileHistory.available(for: draft)
            let selection = AutomationSettingsProfilePicker.selection(for: Binding(get: { draft }, set: { draft = $0 }),
                lastCustom: Binding(get: { history }, set: { history = $0 }))
            selection.wrappedValue = .custom
            #expect(selection.wrappedValue == .custom && !draft.allowFollowUpPush && draft.autoApproveEnabled)
            #expect(draft.baselinePreset == .full && restored.automation.matchingPreset == .full)
            #expect(restored.automationProfileHistory.lastGood == custom)
        }
    }

    @Test func unsavedCustomCanBeRecoveredInTheFormWithoutPersistingOrReplacingLaterParameters() throws {
        try fixture { defaults, settings in
            settings.automation.applyPreset(.manual, for: .codex)
            #expect(settings.save())
            var draft = customSettings()
            let custom = try #require(AutomationProfileSnapshot.custom(from: draft))
            var history: AutomationProfileSnapshot?
            let selection = AutomationSettingsProfilePicker.selection(for: Binding(get: { draft }, set: { draft = $0 }),
                lastCustom: Binding(get: { history }, set: { history = $0 }))
            selection.wrappedValue = .preset(.full)
            #expect(history == custom && selection.wrappedValue == .preset(.full))
            draft.codexReviewModel = .terra
            draft.authorFeedback.promptTemplate = "Later custom instructions"
            draft.scope.mode = .selected
            draft.publicationRestrictions.repositories = [.init(host: "gitlab.example.test", entityID: 7, label: "Later repository")]
            draft.workflowRules[.pipelineFailure].projects = "later/pipeline"
            selection.wrappedValue = .custom
            #expect(!draft.allowFollowUpPush && draft.autoApproveEnabled)
            #expect(draft.codexReviewModel == .terra && draft.authorFeedback.promptTemplate == "Later custom instructions")
            #expect(draft.scope.mode == .selected && draft.publicationRestrictions.repositories.first?.entityID == 7)
            #expect(draft.workflowRules[.pipelineFailure].projects == "later/pipeline")
            #expect(defaults.object(forKey: AutomationProfileHistoryStore.key) == nil)
            let reopened = SettingsManager(defaults: defaults)
            #expect(reopened.automation.matchingPreset == .manual)
            #expect(reopened.automationProfileHistory.available(for: reopened.automation) == nil)
        }
    }

    @Test func aPublicMatchWinsOverCustomHistoryAndChangingHistoryDoesNotNotifyRuntimePolicy() throws {
        try fixture { _, settings in
            settings.automation.applyPreset(.full, for: .codex)
            #expect(settings.save())
            let custom = try #require(AutomationProfileSnapshot.custom(from: customSettings()))
            var policyChanges = 0
            settings.onAutomationChanged = { _ in policyChanges += 1 }
            #expect(settings.automationProfileHistory.save(custom))
            #expect(settings.save())
            #expect(policyChanges == 0 && settings.automation.matchingPreset == .full)
            var draft = customSettings()
            var history: AutomationProfileSnapshot? = custom
            let selection = AutomationSettingsProfilePicker.selection(for: Binding(get: { draft }, set: { draft = $0 }),
                lastCustom: Binding(get: { history }, set: { history = $0 }))
            draft.allowFollowUpPush = true
            #expect(selection.wrappedValue == .preset(.trusted))
            #expect(history == custom)
        }
    }

    @Test func currentSavedCustomIsAnInMemorySeedAndTakesPriorityOverAnOlderSnapshot() throws {
        try fixture { defaults, settings in
            let old = try #require(AutomationProfileSnapshot.custom(from: customSettings()))
            #expect(settings.automationProfileHistory.save(old))
            settings.automation = customSettings()
            settings.automation.autoApproveEnabled = false
            #expect(settings.save())
            let current = try #require(AutomationProfileSnapshot.custom(from: settings.automation))
            let reopened = SettingsManager(defaults: defaults)
            #expect(reopened.automationProfileHistory.lastGood == old)
            #expect(reopened.automationProfileHistory.available(for: reopened.automation) == current)
            #expect(reopened.automationProfileHistory.lastGood == old)
        }
    }

    @Test func corruptOptionalHistoryLeavesLivePermissionsAndTheirJournalUnchanged() throws {
        try fixture { defaults, settings in
            settings.automation.applyPreset(.full, for: .codex)
            #expect(settings.save())
            let before = defaults.data(forKey: "automation")
            defaults.set(Data("corrupt history".utf8), forKey: AutomationProfileHistoryStore.key)
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.automationProfileHistory.lastGood == nil && restored.automationProfileHistory.failure == .read)
            #expect(restored.automation.matchingPreset == .full && restored.automaticPublicWritesAllowed)
            #expect(restored.persistenceDegraded.isEmpty && defaults.data(forKey: "automation") == before)
        }
    }

    @Test func anUnrelatedSafetyHoldDoesNotMisreportASuccessfulConfigurationAndHistorySave() throws {
        try fixture { defaults, initial in
            initial.automation.applyPreset(.safe, for: .codex)
            #expect(initial.save())
            defaults.set(Data("corrupt safety journal".utf8), forKey: "reReviewReceipts")
            let held = SettingsManager(defaults: defaults)
            #expect(held.acceptedAutomation.matchingPreset == .safe)
            held.automation.applyPreset(.trusted, for: .codex)
            #expect(!held.automaticActionsAllowed)
            #expect(held.save())
            #expect(held.acceptedAutomation == held.automation)
            #expect(held.acceptedAutomation.matchingPreset == .trusted)
            let custom = try #require(AutomationProfileSnapshot.custom(from: customSettings()))
            #expect(held.automationProfileHistory.save(custom))
            #expect(held.automationProfileHistory.lastGood == custom)
            #expect(!held.automaticPublicWritesAllowed && held.persistenceDegraded.contains("reReviewReceipts"))
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.automation == held.automation && restored.automationProfileHistory.lastGood == custom)
            #expect(!restored.automaticActionsAllowed)
        }
    }

    @Test(arguments: [false, true])
    func failedOptionalHistoryWriteOrSyncRetainsTheLastGoodSnapshotWithoutAPermissionHold(_ syncFailure: Bool) throws {
        try fixture(faults: true) { defaults, settings in
            let faults = try #require(defaults as? PersistenceFaultDefaults)
            settings.automation.applyPreset(.full, for: .codex)
            #expect(settings.save())
            let first = try #require(AutomationProfileSnapshot.custom(from: customSettings()))
            #expect(settings.automationProfileHistory.save(first))
            var nextConfiguration = customSettings()
            nextConfiguration.autoApproveEnabled = false
            let next = try #require(AutomationProfileSnapshot.custom(from: nextConfiguration))
            let previous = defaults.data(forKey: AutomationProfileHistoryStore.key)
            if syncFailure { faults.synchronizationFails = true }
            else { faults.rejectedKey = AutomationProfileHistoryStore.key }
            #expect(!settings.automationProfileHistory.save(next))
            #expect(settings.automationProfileHistory.lastGood == first)
            #expect(defaults.data(forKey: AutomationProfileHistoryStore.key) == previous)
            #expect(settings.automaticPublicWritesAllowed && settings.persistenceDegraded.isEmpty)
            faults.synchronizationFails = false
            faults.rejectedKey = nil
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.automationProfileHistory.lastGood == first && restored.automation.matchingPreset == .full)
            #expect(settings.automationProfileHistory.save(next))
            #expect(settings.automationProfileHistory.lastGood == next)
        }
    }

    @Test func failedRuntimeSaveThenRevertUsesTheLastAcceptedProfileAndKeepsRetryAvailable() throws {
        try fixture(faults: true) { defaults, settings in
            let faults = try #require(defaults as? PersistenceFaultDefaults)
            settings.automation.applyPreset(.safe, for: .codex)
            #expect(settings.save())
            let accepted = settings.acceptedAutomation
            var state = AutomationSettingsSaveState(accepted: accepted)
            var draft = accepted
            draft.applyPreset(.trusted, for: .codex)
            state.begin()
            settings.automation = draft
            faults.synchronizationFails = true
            let saved = settings.save()
            state.runtimeSaved(settings.automation, succeeded: saved)
            #expect(!saved && settings.acceptedAutomation == accepted)
            #expect(settings.automation.matchingPreset == .trusted)
            draft = state.revert()
            #expect(draft.matchingPreset == .safe && state.failed)
            #expect(state.canApply(draft: draft, custom: nil, savedCustom: nil))
            #expect(settings.automationProfileHistory.available(for: settings.acceptedAutomation) == nil)
            #expect(defaults.object(forKey: AutomationProfileHistoryStore.key) == nil)
            let reopenedState = AutomationSettingsSaveState(accepted: settings.acceptedAutomation,
                runtimeSavePending: settings.acceptedAutomation != settings.automation)
            #expect(reopenedState.runtimeSavePending && reopenedState.failed)
            faults.synchronizationFails = false
        }
    }

    @Test func historyFailureAllowsRetryWhenRuntimeIsAlreadySavedAndRevertOnlyDropsPendingHistory() {
        var accepted = AutomationSettings()
        accepted.applyPreset(.full, for: .codex)
        var state = AutomationSettingsSaveState(accepted: accepted)
        state.begin()
        state.runtimeSaved(accepted, succeeded: true)
        state.historySaved(succeeded: false)
        #expect(state.canApply(draft: accepted, custom: nil, savedCustom: nil))
        #expect(!state.runtimeSavePending && state.failed)
        let reverted = state.revert()
        #expect(reverted == accepted && !state.failed)
        #expect(!state.canApply(draft: reverted, custom: nil, savedCustom: nil))
    }
}
