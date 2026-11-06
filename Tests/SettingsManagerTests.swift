import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("SettingsManager")
struct SettingsManagerTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "GitLabTodosTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("registers sensible defaults on first init")
    func registersDefaults() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.refreshInterval == .fiveMinutes)
        #expect(settings.unreadReminderInterval == .fiveMinutes)
        #expect(settings.unreadReminderSound == .off)
        #expect(settings.notificationsEnabled == true)
        #expect(settings.onboardingCompleted == false)
        #expect(settings.launchAtLoginPreference == true)
        #expect(settings.lastSeenTodoIDs.isEmpty)
        #expect(settings.glabPath == nil)
        #expect(settings.resolvedHost == nil)
        #expect(settings.isFirstLaunch == true)
    }

    @Test("round-trips mutated state through save/reload")
    func roundTrip() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.refreshInterval = .fifteenMinutes
        settings.unreadReminderInterval = .thirtyMinutes
        settings.unreadReminderSound = .ping
        settings.notificationsEnabled = false
        settings.onboardingCompleted = true
        settings.launchAtLoginPreference = false
        settings.lastSeenTodoIDs = [1, 2, 3, 42]
        settings.resolvedHost = "gitlab.corp.example.com"
        settings.glabPath = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
        settings.save()

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.refreshInterval == .fifteenMinutes)
        #expect(reloaded.unreadReminderInterval == .thirtyMinutes)
        #expect(reloaded.unreadReminderSound == .ping)
        #expect(reloaded.notificationsEnabled == false)
        #expect(reloaded.onboardingCompleted == true)
        #expect(reloaded.launchAtLoginPreference == false)
        #expect(reloaded.lastSeenTodoIDs == [1, 2, 3, 42])
        #expect(reloaded.resolvedHost == "gitlab.corp.example.com")
        #expect(reloaded.glabPath?.path == "/opt/homebrew/bin/glab")
    }

    @Test func ignoredMRsPersistPerHostAccountProjectAndNumber() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        let ignored = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 7, iid: 42)
        settings.ignoredMergeRequests.insert(ignored)
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.ignoredMergeRequests == [ignored])
        #expect(!reloaded.ignoredMergeRequests.contains(.init(host: "other.example.org", username: "me", projectID: 7, iid: 42)))
        #expect(!reloaded.ignoredMergeRequests.contains(.init(host: "gitlab.example.org", username: "other", projectID: 7, iid: 42)))
    }

    @Test("clearing optional fields removes them from defaults")
    func clearsOptionals() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.resolvedHost = "gitlab.com"
        settings.glabPath = URL(fileURLWithPath: "/usr/local/bin/glab")
        settings.save()

        settings.resolvedHost = nil
        settings.glabPath = nil
        settings.save()

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.resolvedHost == nil)
        #expect(reloaded.glabPath == nil)
    }

    @Test("markLaunched flips isFirstLaunch")
    func firstLaunchFlip() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.isFirstLaunch == true)
        settings.markLaunched()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.isFirstLaunch == false)
    }
    @MainActor @Test func explicitPolicySavesNotifySynchronouslyWithoutReentrantDuplicates() throws {
        let suite = "SettingsPolicyCallback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let previous = settings.automation
        var callbacks: [AutomationSettings] = []
        settings.onAutomationChanged = { old in
            callbacks.append(old)
            #expect(SettingsManager(defaults: defaults).automation == settings.automation)
            settings.save()
        }
        settings.notificationsEnabled.toggle()
        settings.save()
        #expect(callbacks.isEmpty)
        settings.automation.allowFollowUpPush.toggle()
        #expect(callbacks.isEmpty)
        settings.save()
        #expect(callbacks == [previous])

        let beforeScopeChange = settings.automation
        settings.automation.scope.mode = .selected
        settings.save()
        #expect(callbacks == [previous, beforeScopeChange])
        settings.onAutomationChanged = nil
    }

    @Test func scopeSaveCancelsOnlyItsPausedAutomaticJob() async throws {
        let suite = "ScopeCancellation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        let coordinator = AssistantJobCoordinator(maximumConcurrentJobs: 3, execute: { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init(result: .init(status: .succeeded, summary: "Fixture"), output: "")
        })
        let monitor = TodoMonitorService(settings: settings, cancelPolicyJob: { id, _ in coordinator.cancel(id) })
        defer { monitor.stopTimer() }
        let host = "scope.example.org"
        let jobs = [1, 2, 3].map { iid in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: host, projectID: 1, iid: iid), username: "me", workspace: "", access: .gitLabRead),
                title: "Fixture", prompt: "", createdAt: Date(), allowsPush: false,
                execution: .init(state: .queued), manual: iid == 3)
        }
        settings.assistantHandoffs = jobs
        for job in jobs { #expect(coordinator.schedule(job, settings: settings)) }
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 99)] = .paused
        settings.save()
        try await Task.sleep(for: .milliseconds(100))
        #expect(settings.assistantHandoffs.allSatisfy { $0.execution?.state.isActive == true })
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 1)] = .paused
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 3)] = .paused
        settings.save()
        try await Task.sleep(for: .milliseconds(100))
        #expect(settings.assistantHandoffs[0].execution?.state == .cancelled)
        #expect(settings.assistantHandoffs[1].execution?.state.isActive == true)
        #expect(settings.assistantHandoffs[2].execution?.state.isActive == true)
        for job in jobs { coordinator.cancel(job.id) }
        let deadline = ContinuousClock.now + .seconds(2)
        while jobs.contains(where: { coordinator.isRunning($0.id) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}
