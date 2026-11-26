import Foundation
import SwiftUI
import Testing
@testable import MergeTether

@MainActor
@Suite("MR automation popover editor")
struct MRAutomationScopeEditorTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 42)

    @Test func defaultAndOffSuspendSavedActionsUntilAutomationIsTurnedBackOn() async throws {
        let (defaults, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        settings.automation.autoMergeEnabled = false
        settings.automation.scope.setManualChoice(.forceOn, for: target)
        settings.setAutoMergePreference(.on, for: target)
        settings.setActionAutomatic(.commentPublication, enabled: false, for: target)
        settings.save()
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target)

        await editor.choose(.inherit)
        let inherited = SettingsManager(defaults: defaults)
        #expect(editor.choice == .default)
        #expect(editor.displayedPreference(for: .merge) == .default)
        #expect(editor.displayedPreference(for: .approval) == .default)
        #expect(editor.displayedPreference(for: .commentPublication) == .on)
        await editor.choose(.off, for: .merge)
        #expect(inherited.autoMergePreference(for: target) == .default)
        #expect(inherited.actionIsAutomatic(.commentPublication, for: target))

        await editor.choose(.paused)
        let paused = SettingsManager(defaults: defaults)
        #expect(editor.choice == .off)
        #expect(MRAutomaticAction.allCases.allSatisfy { editor.displayedPreference(for: $0) == .off })
        #expect(MRAutomaticAction.allCases.allSatisfy { !paused.actionIsAutomatic($0, for: target) })

        await editor.choose(.forceOn)
        let restored = SettingsManager(defaults: defaults)
        #expect(editor.choice == .on)
        #expect(editor.displayedPreference(for: .merge) == .on)
        #expect(editor.displayedPreference(for: .commentPublication) == .off)
        #expect(restored.autoMergePreference(for: target) == .on)
        #expect(!restored.actionIsAutomatic(.commentPublication, for: target))
    }

    @Test func legacyActionOverrideStaysActiveUntilChoosingDefault() async throws {
        let (defaults, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        settings.setActionAutomatic(.approval, enabled: false, for: target)
        settings.save()
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target)

        #expect(editor.summary.choice == .inherit)
        #expect(editor.choice == .on)
        #expect(editor.displayedPreference(for: .approval) == .off)
        #expect(!SettingsManager(defaults: defaults).actionIsAutomatic(.approval, for: target))

        await editor.choose(.inherit)
        settings.automation.scope.adoptAutomatically(target)
        settings.save()

        #expect(editor.choice == .default)
        #expect(SettingsManager(defaults: defaults).actionIsAutomatic(.approval, for: target))
    }

    @Test func followingRepositoryClearsAnIndividualOptInAcrossRestart() async throws {
        let (defaults, settings, monitor) = try makeMonitor()
        defer { monitor.stopTimer() }
        settings.automation.scope[target.repository] = .paused
        settings.automation.scope[target] = .active
        settings.save()
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target)
        #expect(editor.summary == .init(active: true, source: .mergeRequest, choice: .active))

        await editor.choose(.inherit)

        #expect(editor.summary == .init(active: false, source: .repository, choice: .inherit))
        #expect(SettingsManager(defaults: defaults).automation.scope[target] == .inherit)
    }

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

    @Test func choosingDefaultRestoresScopeAndChoosingAlwaysOnForDraftNeedsConfirmation() async throws {
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

    @Test func ownMRCanExposeAutoMergeWithGlobalFeaturesOffUsingCachedOwnership() throws {
        let name = "MRAutomationScopeEditor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.manual, for: .codex)
        settings.automation.packageDecision = .enabled
        settings.automation.allowAutomaticPublicActions = true
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = target.host
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        let editor = MRAutomationScopeEditor(monitor: monitor, target: target)
        #expect(!settings.configuredAutomation.hasEnabledAutomation && !editor.isAvailable)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":7,"iid":42,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature",
        "web_url":"https://gitlab.example.test/group/app/-/merge_requests/42","state":"opened","draft":false,
        "source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
        monitor.recordBoardDisplayRequest(request, for: target, url: request.webURL,
            accountRevision: glab.accountRevision, readStartedAt: Date())

        #expect(editor.isAvailable && editor.applicableActions == [.commentPublication, .merge])
        let view = NSHostingView(rootView: MRAutomationPopover(editor: editor))
        #expect(view.fittingSize.height > 0 && gitlab.requests.isEmpty)
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
