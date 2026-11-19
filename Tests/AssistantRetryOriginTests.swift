import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AssistantRetryOriginTests {
    @Test(arguments: ["review-on", "review-off", "blocker-on", "blocker-off", "local-conflict", "conflict-off", "conflict-tools-off", "conflict-push-off", "unknown-pruned-review", "routed-review-on", "routed-review-off", "preparation-conflict", "preparation-conflict-excluded"])
    func durableOriginGovernsRetryAfterDisplayHistoryIsPruned(_ scenario: String) throws {
        try withFixture(scenario) { monitor, settings, job, _ in
            #expect(settings.workflowActivity.isEmpty)
            #expect(monitor.canAutomaticallyRetry(job, assistantReady: true)
                == ["review-on", "blocker-on", "local-conflict", "routed-review-on", "preparation-conflict", "preparation-conflict-excluded"].contains(scenario))
            #expect(job.allowsPush == (scenario == "conflict-push-off"))
        }
    }

    @Test(arguments: [false, true])
    func matchingLegacyActivityIsMigratedBeforeHistoryCanDisappear(_ foreignAccount: Bool) throws {
        try withFixture("legacy", foreignAccount: foreignAccount) { monitor, settings, job, defaults in
            let migrated = try #require(settings.assistantHandoffs.first)
            #expect(migrated.workflowEventKind == (foreignAccount ? nil : .blockerChange))
            #expect(migrated.workflowOriginKnown == (foreignAccount ? nil : true))
            settings.workflowActivity = []
            settings.save()
            #expect(monitor.canAutomaticallyRetry(migrated, assistantReady: true) == !foreignAccount)
            #expect(SettingsManager(defaults: defaults).assistantHandoffs.first?.workflowEventKind == migrated.workflowEventKind)
            #expect(migrated.id == job.id)
        }
    }

    @Test func anExactLocalConflictReceiptMigratesItsIntentWithoutGrantingPush() throws {
        try withFixture("legacy-conflict") { monitor, settings, _, defaults in
            let job = try #require(settings.assistantHandoffs.first)
            #expect(job.taskIntent == .conflictResolution && !job.allowsPush && job.workflowOriginKnown == true)
            settings.conflictReceipts = []
            settings.save()
            #expect(monitor.canAutomaticallyRetry(job, assistantReady: true))
            #expect(SettingsManager(defaults: defaults).assistantHandoffs.first?.taskIntent == .conflictResolution)
        }
    }

    private func withFixture(_ scenario: String, foreignAccount: Bool = false,
        body: (TodoMonitorService, SettingsManager, AssistantAutomationRunner.Handoff, UserDefaults) throws -> Void) throws {
        let suite = "AssistantRetryOriginTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.trusted, for: .codex)
        settings.automation.conflictTasksEnabled = scenario != "conflict-off"
        settings.automation.allowConflictPush = false
        if scenario == "conflict-tools-off" || scenario == "preparation-conflict" { settings.automation.allowAssistantTools = false }
        if scenario == "preparation-conflict-excluded" { settings.automation.assistantToolProjects = "other/project" }
        if scenario.hasPrefix("routed-review-") {
            settings.automation.reviewRequested.isEnabled = scenario == "routed-review-on"
            settings.automation.autoReReviewEnabled = true
        }
        settings.automation.workflowRules[.reviewUpdate].mode = scenario == "review-off" ? .off : .assistant
        settings.automation.workflowRules[.blockerChange].mode = scenario == "blocker-off" ? .off : .assistant
        let conflict = scenario.contains("conflict")
        let host = "gitlab.example.test"
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: 1, iid: 2), username: "me", workspace: "", access: scenario.hasPrefix("preparation-conflict") ? .preparation : .configuredTools),
            title: "Task", prompt: "Task", createdAt: .now, allowsPush: scenario == "conflict-push-off",
            execution: .init(state: .failed, finishedAt: .now), taskPrompt: "Inspect current evidence",
            mergeRequestURL: URL(string: "https://\(host)/g/p/-/merge_requests/2"),
            workflow: scenario.hasPrefix("review-") || scenario.hasPrefix("routed-review-") || scenario == "unknown-pruned-review" ? .review : nil,
            expectedHeadSHA: String(repeating: "a", count: 40), taskIntent: conflict && scenario != "legacy-conflict" ? .conflictResolution : nil,
            workflowEventKind: scenario == "legacy" || conflict || scenario.hasPrefix("routed-review-") || scenario == "unknown-pruned-review" ? nil : (scenario.hasPrefix("review-") ? .reviewUpdate : .blockerChange),
            workflowOriginKnown: scenario.hasPrefix("legacy") || scenario == "unknown-pruned-review" ? nil : true)
        settings.assistantHandoffs = [job]
        if scenario == "legacy-conflict" {
            settings.conflictReceipts.insert(.init(host: host, userID: 7, projectID: 1, iid: 2,
                sourceSHA: String(repeating: "a", count: 40), targetSHA: String(repeating: "b", count: 40),
                allowsPush: false, jobID: job.id))
        }
        if scenario == "legacy" {
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"me","name":"Me"},"title":"MR","web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"source_branch":"feature","target_branch":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","labels":[]}"#.utf8))
            var entry = MergeWorkflowActivityEntry(id: "legacy", event: .init(kind: .blockerChange, mergeRequest: request,
                identity: "legacy", context: "Changed"), createdAt: .now, host: host,
                user: .init(id: 7, username: foreignAccount ? "other" : "me"), state: .waitingForAssistant)
            entry.assistantJobID = job.id
            settings.workflowActivity = [entry]
        }
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { call in
            if call.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if call.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            return InMemoryGitLab.output("[]")
        }
        let glab = gitlab.service(host: host, username: "me")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }),
            assistantDependencies: .init(probe: { _ in .missingCLI }))
        defer { monitor.stopTimer() }
        try body(monitor, settings, job, defaults)
    }
}
