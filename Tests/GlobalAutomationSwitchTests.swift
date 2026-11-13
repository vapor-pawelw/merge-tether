import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("Global automation switch")
struct GlobalAutomationSwitchTests {
    private let host = "gitlab.example.test"

    @Test func switchingOffOverridesPresetAndMRChoicesWithoutChangingThem() throws {
        // given
        let defaults = try makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let forced = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 42)
        settings.automation.scope.setManualChoice(.forceOn, for: forced)
        #expect(settings.save())
        let configured = settings.automation
        #expect(settings.automationGloballyActive)

        // when
        #expect(settings.setAutomationGloballyEnabled(false))

        // then
        #expect(!settings.automation.hasAutomaticActionConsent)
        #expect(!settings.automation.hasEnabledAutomation)
        #expect(!settings.automation.scope.resolve(forced).active)
        #expect(!settings.automaticWritesAllowed && !settings.automaticPublicWritesAllowed)
        #expect(settings.automation.matchingPreset == .full)
        #expect(settings.automation.scope.manualChoice(for: forced) == .forceOn)
        #expect(settings.acceptedAutomation == configured)
        #expect(!settings.acceptedAutomation.isGloballySuspended)
        let stored = try JSONDecoder().decode(AutomationSettings.self, from: try #require(defaults.data(forKey: "automation")))
        #expect(stored == configured && !stored.isGloballySuspended)
        #expect(settings.configuredAutomationAvailable && !settings.automationGloballyActive)
    }

    @Test func switchSurvivesRestartAndResumesConfiguredAutomation() throws {
        // given
        let defaults = try makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.trusted, for: .claude)
        settings.save()
        settings.setAutomationGloballyEnabled(false)

        // when
        let restored = SettingsManager(defaults: defaults)

        // then
        #expect(!restored.automationGloballyEnabled && restored.automation.isGloballySuspended)
        #expect(!restored.automation.hasAutomaticActionConsent && restored.automation.matchingPreset == .trusted)

        // when
        restored.setAutomationGloballyEnabled(true)

        // then
        #expect(restored.automationGloballyActive && restored.automation.hasAutomaticActionConsent)
        #expect(SettingsManager(defaults: defaults).automationGloballyActive)
    }

    @Test func applyingSettingsWhileSwitchedOffKeepsTheOverride() throws {
        // given
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.automation.applyPreset(.full, for: .codex)
        settings.save()
        settings.setAutomationGloballyEnabled(false)
        var edited = settings.acceptedAutomation
        edited.autoMergeEnabled = false

        // when
        settings.automation = edited.preservingScope(from: settings.automation)
        settings.save()

        // then
        #expect(settings.automation.isGloballySuspended && !settings.automation.hasAutomaticActionConsent)
        #expect(!settings.acceptedAutomation.autoMergeEnabled && !settings.acceptedAutomation.isGloballySuspended)
    }

    @Test func manualPresetLeavesNothingToSwitch() throws {
        // given
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        settings.automation.applyPreset(.manual, for: .codex)
        settings.save()
        let monitor = TodoMonitorService(settings: settings, glab: GlabService())
        defer { monitor.stopTimer() }

        // when
        monitor.setAutomationGloballyEnabled(false)

        // then
        #expect(!settings.configuredAutomationAvailable && !settings.automationGloballyActive)
        #expect(settings.automationGloballyEnabled)
        #expect(monitor.automationToggleNotices.current == nil)
    }

    @Test func switchingOffCancelsAutomaticWorkKeepsManualWorkAndAnnounces() throws {
        // given
        let settings = SettingsManager(defaults: try makeDefaults())
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        settings.resolvedHost = host
        settings.automation.applyPreset(.full, for: .codex)
        settings.save()
        let glab = GlabService()
        glab.resolvedHost = host
        glab.currentUsername = "me"
        var cancelled: [UUID] = []
        let monitor = TodoMonitorService(settings: settings, glab: glab, cancelPolicyJob: { id, _ in cancelled.append(id) })
        defer { monitor.stopTimer() }
        let autoID = UUID(), manualID = UUID()
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 42)
        settings.assistantHandoffs = [(autoID, false), (manualID, true)].map { id, manual in
            .init(id: id, key: .init(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead),
                  title: "Fixture", prompt: "", createdAt: Date(), allowsPush: false,
                  execution: .init(state: .running), manual: manual)
        }

        // when
        monitor.setAutomationGloballyEnabled(false)

        // then
        #expect(cancelled == [autoID])
        #expect(monitor.automationToggleNotices.current?.kind == .global(active: false))

        // when
        monitor.setAutomationGloballyEnabled(true)

        // then
        #expect(monitor.automationToggleNotices.current?.kind == .global(active: true))
        #expect(settings.automationGloballyActive)
    }

    @Test func latestNoticeReplacesPreviousAndStaleDismissalIsIgnored() throws {
        // given
        let center = AutomationToggleNoticeCenter()
        center.post(.global(active: false))
        let stale = try #require(center.current)

        // when
        center.post(.mergeRequest(iid: 42, projectPath: "group/repo", active: true))
        center.dismiss(stale.id)

        // then
        let current = try #require(center.current)
        #expect(current.kind == .mergeRequest(iid: 42, projectPath: "group/repo", active: true))

        // when
        center.dismiss(current.id)

        // then
        #expect(center.current == nil)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "GlobalAutomationSwitch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
