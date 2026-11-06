import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct IntegrationRecoveryTests {
    @Test func refreshRecoversAnAccountAfterAnEarlierFailedAuthenticationProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        case "$*" in
          'config get host') printf '%s' 'gitlab.example.test' ;;
          'auth status')
            if test -f "$0-online"; then
              printf '%s' 'Logged in to gitlab.example.test as alice' >&2
            else
              printf '%s' 'network is unreachable' >&2
              exit 1
            fi ;;
          'api --paginate /todos?per_page=100&state=pending'*)
            if test -f "$0-fail-todos"; then printf 'network unavailable' >&2; exit 1; fi
            if test -f "$0-todos.json"; then cat "$0-todos.json"; else printf '[]'; fi ;;
          'api /user '*)
            if test -f "$0-user.json"; then cat "$0-user.json"; else printf '%s' '{"id":7,"username":"alice"}'; fi ;;
          'api /merge_requests?scope=created_by_me&'*) printf '['; cat "$0-mr.json"; printf ']' ;;
          'api /projects/1/merge_requests/2 --hostname '*) cat "$0-mr.json" ;;
          *) printf '[]' ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice"},"title":"Recovered MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8)
            .write(to: URL(fileURLWithPath: executable.path + "-mr.json"))
        let aliceTodo = #"[{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/group/repo/-/issues/42","body":"Alice's unread issue","state":"pending","created_at":"2026-11-06T10:00:00.000Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}]"#
        try Data(aliceTodo.utf8).write(to: URL(fileURLWithPath: executable.path + "-todos.json"))
        let suite = "IntegrationRecoveryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = executable
        settings.onboardingCompleted = false
        let glab = GlabService()
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        await monitor.bootstrap()
        #expect(monitor.boardRefreshState == .current)
        #expect(glab.currentUsername == nil)
        #expect(glab.authStatus == .unknown)
        try Data().write(to: URL(fileURLWithPath: executable.path + "-online"))

        settings.onboardingCompleted = true
        #expect(monitor.boardRefreshState == .syncing)
        monitor.authoredMergeRequests.setVisible(true)
        await monitor.refreshNow()
        for _ in 0..<300 where monitor.authoredMergeRequests.isLoading || monitor.attention.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        monitor.authoredMergeRequests.setVisible(false)
        monitor.stopTimer()

        #expect(monitor.ownMergeRequestItems.contains { $0.id.projectID == 1 && $0.id.iid == 2 })
        #expect(glab.currentUsername == "alice")
        #expect(glab.authStatus == .authenticated)
        #expect(monitor.lastError == nil)
        #expect(monitor.currentAccountTodos.map(\.id) == [401])
        #expect(monitor.inbox.todos.map(\.id) == [401])
        #expect(monitor.userAttention.items.contains { $0.id == "gitlab.example.test/alice/todo/401" })

        // A same-account transient fetch failure preserves the last clickable inbox.
        try Data().write(to: URL(fileURLWithPath: executable.path + "-fail-todos"))
        await monitor.refreshNow()
        #expect(monitor.lastError != nil)
        #expect(monitor.currentAccountTodos.map(\.id) == [401])
        #expect(monitor.inbox.todos.map(\.id) == [401])
        try FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + "-fail-todos"))
        await monitor.refreshNow()
        #expect(monitor.lastError == nil)

        #expect(monitor.boardRefreshState == .current)
        glab.currentUsername = "bob"
        #expect(monitor.currentAccountTodos.isEmpty)
        #expect(monitor.inbox.todos.isEmpty)
        #expect(!monitor.hasUnseenTodos)
        #expect(!monitor.userAttention.items.contains { $0.id.hasSuffix("/todo/401") })
        // Matching account text cannot revive an inbox from an earlier account epoch.
        glab.currentUsername = "alice"
        #expect(monitor.currentAccountTodos.isEmpty)
        #expect(monitor.inbox.todos.isEmpty)
        #expect(!monitor.hasUnseenTodos)
        #expect(!monitor.userAttention.items.contains { $0.id.hasSuffix("/todo/401") })
        glab.currentUsername = "bob"
        try Data(#"{"id":8,"username":"bob"}"#.utf8).write(to: URL(fileURLWithPath: executable.path + "-user.json"))
        monitor.attention.refresh(host: "gitlab.example.test", username: "bob", todos: [])
        monitor.authoredMergeRequests.setVisible(true)
        for _ in 0..<300 where monitor.authoredMergeRequests.isLoading || monitor.attention.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor.attention.hasSyncedCurrentCatalog && monitor.authoredMergeRequests.hasSyncedCurrentCatalog)
        // Both catalogs belong to Bob now; Alice's successful TODO fetch is still stale.
        #expect(monitor.boardRefreshState == .syncing)
        let bobTodo = aliceTodo.replacingOccurrences(of: "401", with: "402")
            .replacingOccurrences(of: "Alice's unread issue", with: "Bob's unread issue")
        try Data(bobTodo.utf8).write(to: URL(fileURLWithPath: executable.path + "-todos.json"))
        await monitor.refreshNow()
        for _ in 0..<300 where monitor.authoredMergeRequests.isLoading || monitor.attention.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(monitor.boardRefreshState == .current)
        #expect(monitor.currentAccountTodos.map(\.id) == [402])
        try Data().write(to: URL(fileURLWithPath: executable.path + "-fail-todos"))
        await monitor.refreshNow()
        #expect(monitor.lastError != nil)
        #expect(monitor.boardRefreshState == .current)
        #expect(monitor.currentAccountTodos.map(\.id) == [402])
        monitor.authoredMergeRequests.setVisible(false)
        monitor.stopTimer()
    }
}
