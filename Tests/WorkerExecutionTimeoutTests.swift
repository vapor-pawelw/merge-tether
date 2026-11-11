import Foundation
import SwiftUI
import Testing
@testable import GitLabTodos

struct WorkerExecutionTimeoutTests {
    @Test(arguments: [1, 30, 90, 1_440])
    func validMinutesBecomeTheExactProcessBudget(_ minutes: Int) throws {
        let limit = WorkerExecutionTimeout.Limit(minutes: minutes)
        #expect(limit.minutes == minutes)
        #expect(limit.seconds == TimeInterval(minutes * 60))
        #expect(try JSONDecoder().decode(WorkerExecutionTimeout.Limit.self, from: JSONEncoder().encode(limit)) == limit)
    }

    @Test(arguments: ["0", "-1", "1441", "999999999999999999999999", "null", "true", "30.5", "\"120\"", "{}"])
    func invalidMinutesFallBackToThirtyRatherThanAnUnlimitedOrClampedBudget(_ json: String) throws {
        let limit = try JSONDecoder().decode(WorkerExecutionTimeout.Limit.self, from: Data(json.utf8))
        #expect(limit.minutes == 30 && limit.seconds == 1_800)
    }

    @Test func projectOverridesMatchTheExactHostAndProjectID() {
        let policy = WorkerExecutionTimeout(defaultLimit: .init(minutes: 60), projectOverrides: [
            .init(host: " GitLab.Example.Test ", projectID: 7, limit: .init(minutes: 120)),
            .init(host: "other.example.test", projectID: 7, limit: .init(minutes: 90))
        ])
        #expect(!policy.hasInvalidOverrides)
        #expect(policy.limit(host: "gitlab.example.test", projectID: 7).minutes == 120)
        #expect(policy.limit(host: "other.example.test", projectID: 7).minutes == 90)
        #expect(policy.limit(host: "gitlab.example.test", projectID: 70).minutes == 60)
        #expect(policy.limit(host: "sub.gitlab.example.test", projectID: 7).minutes == 60)
        #expect(policy.limit(host: "third.example.test", projectID: 7).minutes == 60)
    }

    @MainActor @Test func repositoryChooserKeepsHostsSeparateAndExcludesAlreadyConfiguredProjects() {
        let configured = PublicationIdentity(host: "gitlab.example.test", entityID: 7, label: "team/old-name")
        let otherHost = PublicationIdentity(host: "other.example.test", entityID: 7, label: "team/repo")
        let otherProject = PublicationIdentity(host: "gitlab.example.test", entityID: 8, label: "team/other")
        let invalid = PublicationIdentity(host: "", entityID: 9, label: "team/unknown")
        let policy = WorkerExecutionTimeout(projectOverrides: [
            .init(host: configured.host, projectID: configured.entityID, projectPath: "team/renamed", limit: .init(minutes: 120))
        ])
        let chooser = WorkerExecutionTimeoutSettingsView(policy: .constant(policy),
            repositories: [configured, otherHost, otherProject, invalid])
        #expect(chooser.availableRepositories == [otherHost, otherProject])
        #expect(policy.limit(host: configured.host, projectID: configured.entityID).minutes == 120)
    }

    @MainActor @Test(arguments: ["gitlab.example.test:8443", "[2001:db8::1]:8443"])
    func repositorySelectionPreservesTheAuthorityUsedByTheWorker(_ authority: String) throws {
        let url = try #require(URL(string: "https://\(authority)/team/repo/-/merge_requests/11"))
        let repository = try #require(WorkerExecutionTimeoutSettingsView.repositoryChoice(projectID: 7, url: url))
        #expect(repository.host == authority && repository.label == "team/repo")
        var configuration = AutomationSettings()
        let chooser = WorkerExecutionTimeoutSettingsView(policy: .constant(configuration.workerExecutionTimeout), repositories: [repository])
        let selected = try #require(chooser.availableRepositories.first)
        configuration.workerExecutionTimeout.projectOverrides.append(.init(host: selected.host, projectID: selected.entityID,
            projectPath: selected.label, limit: .init(minutes: 120)))
        let handoff = job(assistant: .codex, manual: true, configuration: configuration, host: authority)
        #expect(AssistantJobExecutor.workerExecutionTimeout(for: handoff).minutes == 120)
        #expect(configuration.workerExecutionTimeout.limit(host: authority.replacingOccurrences(of: ":8443", with: ""), projectID: 7).minutes == 30)
        #expect(configuration.workerExecutionTimeout.limit(host: authority.replacingOccurrences(of: ":8443", with: ":9443"), projectID: 7).minutes == 30)
    }

    @Test(arguments: ["", "*.example.test", "https://gitlab.example.test", "gitlab.example.test/team/repo", "gitlab example.test"])
    func invalidProjectKeysNeverSelectAnOverride(_ host: String) {
        let policy = WorkerExecutionTimeout(projectOverrides: [
            .init(host: host, projectID: 7, limit: .init(minutes: 120))
        ])
        #expect(policy.hasInvalidOverrides)
        #expect(policy.limit(host: host, projectID: 7).minutes == 30)
    }

    @Test func invalidProjectIDsAndAmbiguousOverridesAreConservative() {
        var policy = WorkerExecutionTimeout(defaultLimit: .init(minutes: 120), projectOverrides: [
            .init(host: "gitlab.example.test", projectID: 7, limit: .init(minutes: 60)),
            .init(host: "GITLAB.EXAMPLE.TEST", projectID: 7, limit: .init(minutes: 180))
        ])
        #expect(policy.hasInvalidOverrides)
        #expect(policy.limit(host: "gitlab.example.test", projectID: 7).minutes == 30)
        policy.projectOverrides = [.init(host: "gitlab.example.test", projectID: 0, limit: .init(minutes: 180))]
        #expect(policy.hasInvalidOverrides)
        #expect(policy.limit(host: "gitlab.example.test", projectID: 0).minutes == 30)
    }

    @Test(arguments: ["{}", #"{"workerExecutionTimeout":null}"#, #"{"workerExecutionTimeout":"120"}"#,
                     #"{"workerExecutionTimeout":{"defaultLimit":120,"projectOverrides":"broken"}}"#])
    func missingOrMalformedSettingsKeepTheLegacyThirtyMinuteDefault(_ json: String) throws {
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        #expect(settings.workerExecutionTimeout == WorkerExecutionTimeout())
    }

    @Test func corruptOverrideMinutesDoNotInheritAnExtendedDefault() throws {
        let json = #"{"workerExecutionTimeout":{"defaultLimit":120,"projectOverrides":[{"host":"gitlab.example.test","projectID":7,"limit":0}]}}"#
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        #expect(settings.workerExecutionTimeout.defaultLimit.minutes == 120)
        #expect(settings.workerExecutionTimeout.limit(host: "gitlab.example.test", projectID: 7).minutes == 30)
    }

    @MainActor @Test func settingsRoundTripAndPolicyChangeKeepExistingSaveSemantics() throws {
        let suite = "WorkerExecutionTimeoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.automation.workerExecutionTimeout.defaultLimit.minutes == 30)
        #expect(settings.save())
        var changes = 0
        settings.onAutomationChanged = { _ in changes += 1 }
        settings.automation.workerExecutionTimeout = extendedPolicy
        #expect(changes == 0)
        #expect(settings.save())
        #expect(changes == 1)
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.automation.workerExecutionTimeout == extendedPolicy)
    }

    @Test(arguments: AutomationPreset.allCases)
    func profilePermissionsNeverReplaceTheTaskTimeout(_ preset: AutomationPreset) throws {
        var settings = AutomationSettings()
        settings.applyPreset(.trusted, for: .codex)
        settings.allowFollowUpPush = false
        let custom = try #require(AutomationProfileSnapshot.custom(from: settings))
        settings.workerExecutionTimeout = extendedPolicy
        settings.applyPreset(preset, for: .claude)
        #expect(settings.workerExecutionTimeout == extendedPolicy)
        #expect(settings.matchingPreset == preset)
        custom.apply(to: &settings)
        #expect(settings.workerExecutionTimeout == extendedPolicy)
        #expect(!settings.allowFollowUpPush)
    }

    @MainActor @Test(arguments: AutomationAssistant.allCases, [false, true])
    func eachRunUsesItsOwnSnapshotForEitherCLI(_ assistant: AutomationAssistant, _ manual: Bool) throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(.trusted, for: assistant)
        configuration.workerExecutionTimeout = extendedPolicy
        var handoff = job(assistant: assistant, manual: manual, configuration: configuration)
        let captured = AssistantJobExecutor.workerExecutionTimeout(for: handoff)
        configuration.workerExecutionTimeout.defaultLimit = .init(minutes: 240)
        configuration.workerExecutionTimeout.projectOverrides.removeAll()
        #expect(captured.minutes == 120)
        #expect(AssistantJobExecutor.workerExecutionTimeout(for: handoff) == captured)
        if !manual {
            #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
                try AssistantJobExecutor.validateConfiguration(handoff, automation: configuration)
            }
        }
        handoff.configurationSnapshot = nil
        #expect(AssistantJobExecutor.workerExecutionTimeout(for: handoff).minutes == 30)
    }

    @MainActor @Test func aTimedOutWorkerIsFailedWithoutAnAutomaticRestart() async throws {
        let suite = "WorkerTimeoutFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.trusted, for: .codex)
        var handoff = job(assistant: .codex, manual: true, configuration: settings.automation)
        handoff.execution = .init(state: .queued)
        settings.assistantHandoffs = [handoff]
        var attempts = 0
        let coordinator = AssistantJobCoordinator(healthStore: AssistantCLIHealthStore(defaults: defaults, persists: false), execute: { _, _ in
            attempts += 1
            throw ProcessRunner.RunError.timedOut
        })
        #expect(coordinator.schedule(handoff, settings: settings))
        await coordinator.waitForTermination()
        coordinator.resumePendingJobs()
        #expect(attempts == 1)
        #expect(settings.assistantHandoffs.first?.execution?.state == .failed)
        #expect(!coordinator.isRunning(handoff.id))
    }

    private let extendedPolicy = WorkerExecutionTimeout(defaultLimit: .init(minutes: 60), projectOverrides: [
        .init(host: "gitlab.example.test", projectID: 7, projectPath: "team/repo", limit: .init(minutes: 120))
    ])

    @MainActor
    private func job(assistant: AutomationAssistant, manual: Bool, configuration: AutomationSettings,
                     host: String = "gitlab.example.test") -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: assistant,
            work: .init(host: host, projectID: 7, iid: 11), username: "me", workspace: "", access: .gitLabRead),
            title: "Assigned task", prompt: "Verify assigned work", createdAt: Date(), allowsPush: false,
            manual: manual, configurationSnapshot: configuration)
    }
}
