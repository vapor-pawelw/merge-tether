import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("Lifecycle completion settings")
struct LifecycleCompletionSettingsTests {
    @Test func completionDisplayFiltersDefaultOnAndPersistIndependentlyFromBannersAndNotifications() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showMergedMRCompletions)
        #expect(settings.showClosedMRCompletions)
        settings.showMergedMRCompletions = false
        settings.showClosedMRCompletions = true
        settings.autoHandledEventBannersEnabled = false
        settings.notificationsEnabled = false
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(!reloaded.showMergedMRCompletions)
        #expect(reloaded.showClosedMRCompletions)
        #expect(!reloaded.autoHandledEventBannersEnabled && !reloaded.notificationsEnabled)
        reloaded.showMergedMRCompletions = true
        reloaded.showClosedMRCompletions = false
        reloaded.save()
        let again = SettingsManager(defaults: defaults)
        #expect(again.showMergedMRCompletions && !again.showClosedMRCompletions)
    }

    @Test func explicitFullCleanupDefaultsChangeNoAutomationPermissionsOrPublicationMode() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        settings.automation.publicationMode = .aiReplies
        settings.automation.autoMergeEnabled = false
        settings.automation.allowFollowUpPush = false
        settings.showMergedMRCompletions = false
        let before = settings.automation
        settings.applyCompletionDefaults(for: .full)
        #expect(settings.autoRemoveFinishedMRs)
        #expect(settings.automation == before)
        #expect(!settings.showMergedMRCompletions)
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.autoRemoveFinishedMRs)
        #expect(reloaded.automation == before)
    }

    @Test(arguments: [AutomationPreset.manual, .checkpoints], [false, true])
    func otherProfilesPreserveCleanupAndReceiptPreferences(_ preset: AutomationPreset, _ cleanup: Bool) {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.autoRemoveFinishedMRs = cleanup
        settings.showClosedMRCompletions = false
        settings.applyCompletionDefaults(for: preset)
        #expect(settings.autoRemoveFinishedMRs == cleanup)
        #expect(!settings.showClosedMRCompletions)
    }

    @Test(arguments: [false, true])
    func loadingLegacyFullPreservesStoredCleanupAndAllCustomPermissions(_ cleanup: Bool) throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var automation = AutomationSettings()
        automation.applyPreset(.full, for: .codex)
        automation.publicationMode = .aiReplies
        automation.autoMergeEnabled = false
        defaults.set(try JSONEncoder().encode(automation), forKey: "automation")
        defaults.set(cleanup, forKey: "autoRemoveFinishedMRs")
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.autoRemoveFinishedMRs == cleanup)
        #expect(settings.automation == automation)
        #expect(settings.showMergedMRCompletions && settings.showClosedMRCompletions)
        settings.save()
        #expect(SettingsManager(defaults: defaults).automation == automation)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "LifecycleCompletionSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
