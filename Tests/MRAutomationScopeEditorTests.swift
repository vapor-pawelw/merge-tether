import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("MR automation popover editor")
struct MRAutomationScopeEditorTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 42)

    @Test func toggleOnReadyMRPausesItPersistsAndAnnouncesWithoutConfirmation() async throws {
        // given
        let (defaults, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        var asked = false
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target, projectPath: "group/app",
                                             confirm: { _ in asked = true; return true })
        #expect(editor.summary == .init(active: true, source: .global, choice: .inherit))

        // when
        await editor.toggle()

        // then
        #expect(!asked)
        #expect(editor.summary == .init(active: false, source: .mergeRequest, choice: .paused))
        #expect(SettingsManager(defaults: defaults).automation.scope.manualChoice(for: target) == .paused)
        #expect(settings.automation.scope.repositoryLabel(for: target) == "group/app")
        #expect(monitor.automationToggleNotices.current?.kind == .mergeRequest(iid: 42, projectPath: "group/app", active: false))
    }

    @Test func enablingDraftAsksAndDecliningLeavesScopeAndNoticeUntouched() async throws {
        // given
        let (defaults, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        var asked = 0
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target, projectPath: "group/app", isDraft: true,
                                             confirm: { _ in asked += 1; return false })
        #expect(editor.summary == .init(active: false, source: .draft, choice: .inherit))

        // when
        await editor.toggle()

        // then
        #expect(asked == 1)
        #expect(editor.summary == .init(active: false, source: .draft, choice: .inherit))
        #expect(settings.automation.scope.manualChoice(for: target) == .inherit)
        #expect(SettingsManager(defaults: defaults).automation.scope.manualChoice(for: target) == .inherit)
        #expect(monitor.automationToggleNotices.current == nil)
    }

    @Test func enablingDraftAfterConfirmationForcesItOnAndAnnounces() async throws {
        // given
        let (_, _, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target, isDraft: true, confirm: { _ in true })

        // when
        await editor.toggle()

        // then
        #expect(editor.summary == .init(active: true, source: .mergeRequest, choice: .forceOn))
        #expect(monitor.automationToggleNotices.current?.kind == .mergeRequest(iid: 42, projectPath: nil, active: true))
    }

    @Test func choosingAutoReturnsToDefaultsAndChoosingAlwaysOnForDraftNeedsConfirmation() async throws {
        // given
        let (_, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        settings.automation.scope.setManualChoice(.paused, for: target)
        settings.save()
        var asked = 0
        let ready = MRAutomationScopeEditor(monitor: monitor, target: target, confirm: { _ in asked += 1; return true })
        let draft = MRAutomationScopeEditor(monitor: monitor, target: target, isDraft: true,
                                            confirm: { _ in asked += 1; return false })

        // when
        await ready.choose(.inherit)

        // then
        #expect(asked == 0)
        #expect(ready.summary == .init(active: true, source: .global, choice: .inherit))
        #expect(monitor.automationToggleNotices.current == nil)

        // when
        await draft.choose(.forceOn)

        // then
        #expect(asked == 1)
        #expect(settings.automation.scope.manualChoice(for: target) == .inherit)
    }

    @Test func repositoryDefaultThatEnablesDraftsAsksAndFollowingGeneralScopeClearsIt() async throws {
        // given
        let (_, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        settings.automation.scope.mode = .selected
        settings.automation.scope.pauseDraftsByDefault = false
        settings.save()
        var asked = 0
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target, projectPath: "group/app",
                                             confirm: { _ in asked += 1; return true })
        #expect(!editor.repositoryDefaultActive && !editor.repositoryHasOverride)

        // when
        await editor.setRepositoryDefault(true)

        // then
        #expect(asked == 1)
        #expect(editor.repositoryDefaultActive && editor.repositoryHasOverride)
        #expect(editor.summary == .init(active: true, source: .repository, choice: .inherit))

        // when
        await editor.followGeneralScope()

        // then
        #expect(asked == 1)
        #expect(!editor.repositoryDefaultActive && !editor.repositoryHasOverride)
    }

    @Test func globalSwitchOffStillShowsAndEditsSavedChoice() async throws {
        // given
        let (_, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        #expect(settings.setAutomationGloballyEnabled(false))
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target, confirm: { _ in true })
        #expect(editor.globallySuspended)
        #expect(editor.summary.active)

        // when
        await editor.toggle()

        // then
        #expect(settings.configuredAutomation.scope.manualChoice(for: target) == .paused)
        #expect(!settings.automation.scope.resolve(target).active)
    }

    private func makeMonitor() throws -> (UserDefaults, SettingsManager, TodoMonitorService) {
        let suiteName = "MRAutomationScopeEditor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        settings.automation.applyPreset(.full, for: .codex)
        #expect(settings.save())
        return (defaults, settings, TodoMonitorService(settings: settings, glab: GlabService()))
    }
}
