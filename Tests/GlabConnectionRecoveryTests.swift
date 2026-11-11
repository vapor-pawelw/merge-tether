import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabConnectionRecoveryTests {
    private let host = "gitlab.example.test"
    private let todoJSON = #"[{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/group/repo/-/issues/42","body":"Unread issue","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}]"#

    private var todoArguments: [String] {
        ["api", "--paginate", "/todos?per_page=100&state=pending", "--hostname", host]
    }

    private func isTodoRead(_ request: InMemoryGitLab.Request) -> Bool {
        request.method == "GET" && request.arguments == todoArguments
    }

    private func fixture(initiallyOffline: Bool = false,
                         _ body: (TodoMonitorService, InMemoryGitLab) async throws -> Void) async throws {
        let name = "GlabConnectionRecoveryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if request.arguments == ["auth", "status"] {
                if gitlab.has("offline") { return InMemoryGitLab.output(error: "dial tcp lookup \(host): i/o timeout", code: 1) }
                if gitlab.has("signed-out") { return InMemoryGitLab.output(error: "not authenticated", code: 1) }
                return InMemoryGitLab.output(error: "Logged in to \(host) as alice")
            }
            if isTodoRead(request) {
                if gitlab.has("pause-todos") {
                    gitlab.write("todos-started")
                    try await gitlab.waitFor("release-todos")
                }
                if gitlab.has("offline") { return InMemoryGitLab.output(error: "dial tcp lookup \(host): i/o timeout", code: 1) }
                if gitlab.has("unauthorized") { return InMemoryGitLab.output(error: "HTTP 401 Unauthorized", code: 1) }
                if gitlab.has("forbidden") { return InMemoryGitLab.output(error: "HTTP 403 Forbidden", code: 1) }
                return InMemoryGitLab.output(todoJSON)
            }
            if request.arguments == ["api", "/user", "--hostname", host] {
                return InMemoryGitLab.output(#"{"id":7,"username":"alice"}"#)
            }
            if request.arguments == ["api", "/merge_requests?scope=all&state=opened&reviewer_id=7&per_page=100", "--hostname", host, "--paginate"]
                || request.arguments == ["api", "/merge_requests?scope=created_by_me&state=opened&with_merge_status_recheck=true&per_page=100", "--hostname", host, "--paginate"] {
                return InMemoryGitLab.output("[]")
            }
            return try gitlab.unexpected(request)
        }
        if initiallyOffline { gitlab.write("offline") }
        let glab = gitlab.service(host: host, username: "alice")
        if initiallyOffline { glab.currentUsername = nil }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.onboardingCompleted = false
        settings.automation.applyPreset(.manual, for: .codex)
        // Establish persisted startup policy before the monitor installs its change observer.
        settings.save()
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }))
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        try await body(monitor, gitlab)
    }

    @Test func transientNetworkFailureKeepsTheAccountInboxAndNormalAutomaticRecoveryWithoutAuthProbes() async throws {
        try await fixture { monitor, gitlab in
            await monitor.refreshNow()
            try #require(monitor.currentAccountTodos.map(\.id) == [401])
            let revision = monitor.glab.accountRevision
            let authReads = gitlab.requests.filter { $0.arguments.first == "auth" }.count

            gitlab.write("offline")
            await monitor.refreshNow()
            let error = try #require(monitor.lastError)
            #expect(GlabErrorPresentation(error: error).action == .retry)
            #expect(monitor.currentAccountTodos.map(\.id) == [401] && monitor.inbox.todos.map(\.id) == [401])
            #expect(monitor.glab.currentUsername == "alice" && monitor.glab.accountRevision == revision)
            #expect(gitlab.requests.filter { $0.arguments.first == "auth" }.count == authReads)

            gitlab.remove("offline")
            await monitor.refreshNow()
            #expect(monitor.lastError == nil && monitor.currentAccountTodos.map(\.id) == [401])
            #expect(gitlab.requests.filter { $0.arguments.first == "auth" }.count == authReads)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func firstCatalogRefreshOfflineSurfacesTheConnectionCauseThenRecoversWithoutSetup() async throws {
        try await fixture(initiallyOffline: true) { monitor, gitlab in
            #expect(monitor.lastError == nil)
            await monitor.refreshNow()
            let error = try #require(monitor.lastError)
            #expect(GlabErrorPresentation(error: error).kind == .connection)
            #expect(monitor.glab.currentUsername == nil && monitor.glab.authStatus == .unknown)
            gitlab.remove("offline")
            await monitor.refreshNow()
            #expect(monitor.lastError == nil && monitor.glab.currentUsername == "alice")
            #expect(monitor.currentAccountTodos.map(\.id) == [401])
        }
    }

    @Test func forbiddenReadsDoNotTriggerLoginAndKeepThePreviousInbox() async throws {
        try await fixture { monitor, gitlab in
            await monitor.refreshNow()
            try #require(monitor.currentAccountTodos.map(\.id) == [401])
            let authReads = gitlab.requests.filter { $0.arguments.first == "auth" }.count
            gitlab.write("forbidden")
            await monitor.refreshNow()
            await monitor.refreshNow()
            let error = try #require(monitor.lastError)
            #expect(GlabErrorPresentation(error: error).action == .integrationSettings)
            #expect(monitor.currentAccountTodos.map(\.id) == [401])
            #expect(gitlab.requests.filter { $0.arguments.first == "auth" }.count == authReads)
        }
    }

    @Test func anExplicitMissingLoginDoesNotAttemptAnotherUnauthenticatedInboxRead() async throws {
        try await fixture { monitor, gitlab in
            await monitor.refreshNow()
            try #require(monitor.currentAccountTodos.map(\.id) == [401])
            gitlab.write("unauthorized")
            await monitor.refreshNow()
            gitlab.write("signed-out")
            let todoReads = gitlab.requests.filter(isTodoRead).count
            await monitor.refreshNow()
            #expect(monitor.lastError == .notAuthenticated && monitor.glab.currentUsername == nil)
            #expect(gitlab.requests.filter(isTodoRead).count == todoReads)
            #expect(monitor.currentAccountTodos.isEmpty)
        }
    }

    @Test func cancelledRefreshKeepsTheLastConfirmedInboxAndDoesNotShowANewError() async throws {
        try await fixture { monitor, gitlab in
            await monitor.refreshNow()
            try #require(monitor.currentAccountTodos.map(\.id) == [401])
            gitlab.write("pause-todos")
            let pending = Task { await monitor.refreshNow() }
            try await gitlab.waitFor("todos-started")
            pending.cancel()
            gitlab.write("release-todos")
            await pending.value
            #expect(monitor.lastError == nil && monitor.currentAccountTodos.map(\.id) == [401])
        }
    }
}
