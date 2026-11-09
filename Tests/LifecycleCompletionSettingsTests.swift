import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("Lifecycle completion migration")
struct LifecycleCompletionSettingsTests {
    @Test(arguments: [false, true])
    func legacyFiltersDoNotHideReceiptsOrChangeAutomation(_ oldPreference: Bool) throws {
        // given
        let suite = "LifecycleCompletionSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        let fixture = MRDependencyPresentationTests()
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try fixture.request(2, project: 1), for: target, now: Date(timeIntervalSince1970: 1))
        ledger.record(try fixture.request(2, project: 1, state: "closed"), for: target, now: Date(timeIntervalSince1970: 2))
        let receipt = try #require(ledger.unreadCompletions(host: target.host, username: target.username, showMerged: true, showClosed: true).first)
        defaults.set(try JSONEncoder().encode(ledger), forKey: "mrLifecycleLedger")
        for key in ["autoRemoveFinishedMRs", "showMergedMRCompletions", "showClosedMRCompletions"] {
            defaults.set(oldPreference, forKey: key)
        }
        var automation = AutomationSettings()
        automation.applyPreset(.full, for: .codex)
        automation.autoMergeEnabled = false
        automation.allowFollowUpPush = false
        defaults.set(try JSONEncoder().encode(automation), forKey: "automation")
        // when
        let settings = SettingsManager(defaults: defaults)
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        // then
        #expect(reloaded.mrLifecycleLedger.isSuppressed(target))
        #expect(reloaded.mrLifecycleLedger.unreadCompletions(host: target.host, username: target.username, showMerged: true, showClosed: true).map(\.id) == [receipt.id])
        #expect(reloaded.automation == automation)
        #expect(defaults.object(forKey: "showClosedMRCompletions") == nil)
    }
}
