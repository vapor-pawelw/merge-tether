import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct TodoMonitorPersistenceGuardTests {
    private let host = "gitlab.example.test"
    private let issueJSON = #"[{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/group/repo/-/issues/42","body":"Unread issue","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}]"#

    private func fixture(_ scenario: String, mr: Bool = false, preset: AutomationPreset = .full,
                         body: (TodoMonitorService, SettingsManager, InMemoryGitLab, Todo) async throws -> Void) async throws {
        let name = "TodoMonitorPersistenceGuardTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if scenario == "degraded" || scenario == "restored" {
            defaults.set(Data("invalid journal".utf8), forKey: "mergeSubmissions")
        }
        var settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(preset, for: .codex)
        settings.save()
        if scenario == "restored" {
            #expect(!settings.automaticActionsAllowed)
            // Model an externally repaired record and a fresh app session, without changing the profile.
            defaults.set(try JSONEncoder().encode([MergeSubmissionReceipt]()), forKey: "mergeSubmissions")
            settings = SettingsManager(defaults: defaults)
        }
        let json = mr ? issueJSON.replacingOccurrences(of: "Issue", with: "MergeRequest")
            .replacingOccurrences(of: "/issues/42", with: "/merge_requests/42") : issueJSON
        let todo = try #require(GlabService.decodeTodos(Data(json.utf8)).first)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if request.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as alice") }
            if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return InMemoryGitLab.output(json) }
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"alice"}"#) }
            if request.method == "POST" { return InMemoryGitLab.output("{}") }
            return InMemoryGitLab.output("[]")
        }
        let glab = gitlab.service(host: host, username: "alice")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.onboardingCompleted = false
        let notifications = NotificationService(authorization: { .denied }, post: { _ in })
        let monitor = TodoMonitorService(settings: settings, glab: glab, notifications: notifications)
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        try await body(monitor, settings, gitlab, todo)
    }

    @Test(arguments: ["healthy", "degraded", "restored"], [AutomationPreset.full, .manual])
    func automaticAcknowledgementPausesWithoutChangingTheProfileAndManualReadingRemainsPossible(_ scenario: String, preset: AutomationPreset) async throws {
        try await fixture(scenario, preset: preset) { monitor, settings, gitlab, todo in
            settings.pendingTodoAcknowledgements.insert(.init(host: host, username: "alice", todo: todo.feedbackIdentity))
            settings.save()
            let configuration = settings.automation
            await monitor.refreshNow()
            let automaticAcknowledgementExpected = scenario != "degraded" && preset == .full
            #expect(gitlab.requests.contains { $0.method == "POST" } == automaticAcknowledgementExpected)
            #expect(settings.automation == configuration)
            if !automaticAcknowledgementExpected {
                #expect(monitor.currentAccountTodos.map(\.id) == [todo.id])
                #expect(monitor.inbox.todos.map(\.id) == [todo.id])
                await monitor.markDone(todo)
                #expect(monitor.currentAccountTodos.isEmpty)
                #expect(gitlab.requests.contains { $0.method == "POST" })
                #expect(settings.automation == configuration)
            }
        }
    }

    @Test func degradationDuringRouterEvidenceReadSuppressesItsAutomaticAcknowledgement() async throws {
        try await fixture("healthy", mr: true) { monitor, settings, gitlab, todo in
            let target = MRAutomationScope.Target(host: host, username: "alice", projectID: todo.project.id, iid: todo.target.iid)
            settings.routedMRTodoReceipts.insert(.init(target: target, event: todo.feedbackIdentity, intentID: nil))
            settings.save()
            let handler = try #require(gitlab.handler)
            var invalidated = false
            gitlab.handler = { request in
                if request.endpoint == "/user" {
                    invalidated = true
                    settings.recordPersistenceFailure("mergeSubmissions")
                }
                return try await handler(request)
            }
            await monitor.refreshNow()
            #expect(invalidated && !settings.automaticActionsAllowed)
            #expect(!gitlab.requests.contains { $0.method == "POST" })
            #expect(monitor.currentAccountTodos.map(\.id) == [todo.id])
        }
    }

    @Test func manualRoutedAcceptanceStillNeedsADurableJournalBeforeAcknowledgement() async throws {
        try await fixture("healthy", mr: true) { monitor, settings, gitlab, todo in
            let target = MRAutomationScope.Target(host: host, username: "alice", projectID: todo.project.id, iid: todo.target.iid)
            settings.routedMRTodoReceipts.insert(.init(target: target, event: todo.feedbackIdentity, intentID: nil))
            settings.save()
            settings.recordPersistenceFailure("routedMRTodoReceipts")
            let router = MergeRequestTodoRouter(settings: settings, glab: monitor.glab, canAutomate: { false })
            let acknowledged = await router.process([todo], host: host, username: "alice", managed: [target], automatically: false)
            #expect(gitlab.requests.contains { $0.endpoint == "/user" })
            #expect(acknowledged.isEmpty)
            #expect(!gitlab.requests.contains { $0.method == "POST" })
        }
    }

}
