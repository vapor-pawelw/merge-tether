import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MacWakeAutomationTests {
    @Test func repeatedWakeDuringRefreshSchedulesOneAdditionalRead() async throws {
        let suite = "WakeRefresh.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "wake.example.test"
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "operator")
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.notificationsEnabled = false
        var reads = 0
        gitlab.handler = { request in
            if request.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if request.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as operator") }
            if request.arguments.contains("/todos?per_page=100&state=pending") {
                reads += 1
                if reads == 1 {
                    gitlab.write("reading")
                    try await gitlab.waitFor("release")
                }
                return InMemoryGitLab.output("[]")
            }
            return try gitlab.unexpected(request)
        }
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            assistantDependencies: AssistantDependencyMonitor(probe: { _ in .missingCLI }))
        monitor.restartTimer()
        defer { monitor.stopTimer() }
        let refresh = Task { await monitor.refreshNow() }
        try await gitlab.waitFor("reading")
        await monitor.refreshAfterSystemWake()
        await monitor.refreshAfterSystemWake()
        #expect(reads == 1)
        gitlab.write("release")
        await refresh.value
        #expect(reads == 2)

        monitor.stopTimer()
        await monitor.refreshAfterSystemWake()
        #expect(reads == 2)
    }

    @Test func powerAssertionTracksRunsPowerSourceAndPreference() {
        var onAC = true
        var acquisitions = 0
        var releases = 0
        let activity = AssistantPowerActivity(isOnExternalPower: { onAC }, acquire: {
            acquisitions += 1
            return { releases += 1 }
        })

        activity.beginRun()
        activity.beginRun()
        #expect(acquisitions == 1)
        activity.endRun()
        #expect(releases == 0)

        onAC = false
        activity.powerSourceChanged()
        #expect(releases == 1)
        onAC = true
        activity.powerSourceChanged()
        #expect(acquisitions == 2)

        activity.setEnabled(false)
        #expect(releases == 2)
        activity.setEnabled(true)
        #expect(acquisitions == 3)
        activity.endRun()
        activity.powerSourceChanged()
        #expect(releases == 3 && acquisitions == 3)
    }

    @Test func explicitPowerPreferenceSurvivesRestartAndProfileChanges() throws {
        let suite = "WakePreference.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.keepMacAwakeDuringAgentTasks)
        settings.keepMacAwakeDuringAgentTasks = false
        settings.automation.applyPreset(.full, for: .codex)
        settings.save()
        #expect(!SettingsManager(defaults: defaults).keepMacAwakeDuringAgentTasks)
    }

    @Test func cancelledRunReleasesTheLastAssertion() async {
        var assertions = 0
        let activity = AssistantPowerActivity(isOnExternalPower: { true }, acquire: {
            assertions += 1
            return { assertions -= 1 }
        })
        do {
            try await activity.track { throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(assertions == 0)
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }
    }
}
