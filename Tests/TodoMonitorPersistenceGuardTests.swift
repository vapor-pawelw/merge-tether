import Foundation
import Testing
@testable import MergeTether

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
        gitlab.write("todos", json)
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if request.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as alice") }
            if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return try gitlab.response("todos") }
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

    @Test func addAndHandleAcknowledgesOnlyTodosForTheSelectedMergeRequest() async throws {
        try await fixture("healthy", preset: .safe) { monitor, settings, gitlab, _ in
            // given
            func event(_ id: Int, projectID: Int, iid: Int, host: String) throws -> Todo {
                let path = "group/repo-\(projectID)"
                let url = try #require(URL(string: "https://\(host)/\(path)/-/merge_requests/\(iid)"))
                return Todo(id: id, actionName: .unmergeable, targetType: .mergeRequest, targetURL: url,
                    body: "Merge request update", createdAt: Date(), state: "pending",
                    project: .init(id: projectID, nameWithNamespace: path, pathWithNamespace: path),
                    author: .init(id: 9, username: "reviewer", name: "Reviewer", avatarURL: nil),
                    target: .init(id: nil, iid: iid, title: "Example", state: "opened", draft: false, workInProgress: false))
            }
            let selected = try event(501, projectID: 1, iid: 42, host: host)
            let sameTarget = try event(502, projectID: 1, iid: 42, host: host)
            let otherIID = try event(503, projectID: 1, iid: 43, host: host)
            let otherProject = try event(504, projectID: 2, iid: 42, host: host)
            let otherHost = try event(505, projectID: 1, iid: 42, host: "other.example.test")
            let todos = [selected, sameTarget, otherIID, otherProject, otherHost]
            for todo in [otherIID, otherProject] {
                settings.automation.scope[.init(host: host, username: "alice", projectID: todo.project.id, iid: todo.target.iid)] = .active
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(todos).store(in: gitlab, as: "todos")
            let handler = try #require(gitlab.handler)
            gitlab.handler = { request in
                if let todo = todos.first(where: { request.endpoint == "/todos/\($0.id)/mark_as_done" }), request.method == "POST" {
                    try gitlab.editArray("todos") { $0.removeAll { $0["id"] as? Int == todo.id } }
                } else if let todo = todos.first(where: { request.endpoint == "/projects/\($0.project.id)/merge_requests/\($0.target.iid ?? 0)" }) {
                    return InMemoryGitLab.output("""
                        {"project_id":\(todo.project.id),"iid":\(todo.target.iid ?? 0),"author":{"id":9,"username":"reviewer","name":"Reviewer"},
                         "title":"Example","web_url":"\(todo.targetURL)","state":"opened","sha":"\(String(repeating: "a", count: 40))",
                         "source_branch":"feature","target_branch":"main","draft":false,"labels":[],"has_conflicts":false}
                        """)
                }
                return try await handler(request)
            }
            #expect(settings.automaticWritesAllowed && !settings.automaticPublicWritesAllowed)
            await monitor.refreshNow()
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })

            // when
            await monitor.adoptMRTodoProposal(selected)

            // then
            let acknowledged = gitlab.requests.filter { $0.method == "POST" }.map(\.endpoint)
            #expect(acknowledged.count == 2)
            #expect(Set(acknowledged) == ["/todos/501/mark_as_done", "/todos/502/mark_as_done"])
            #expect(Set(monitor.currentAccountTodos.map(\.id)) == [otherIID.id, otherProject.id, otherHost.id])
            #expect(Set(settings.routedMRTodoReceipts.map(\.event.id)) == [selected.id, sameTarget.id])
        }
    }

}
