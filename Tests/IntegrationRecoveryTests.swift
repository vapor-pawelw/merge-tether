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
          'api --paginate /todos?per_page=100&state=pending'*) printf '[]' ;;
          'api /user '*) printf '%s' '{"id":7,"username":"alice"}' ;;
          'api /merge_requests?scope=created_by_me&'*) printf '['; cat "$0-mr.json"; printf ']' ;;
          'api /projects/1/merge_requests/2 --hostname '*) cat "$0-mr.json" ;;
          *) printf '[]' ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice"},"title":"Recovered MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8)
            .write(to: URL(fileURLWithPath: executable.path + "-mr.json"))
        let suite = "IntegrationRecoveryTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = executable
        settings.onboardingCompleted = false
        let glab = GlabService()
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        await monitor.bootstrap()
        #expect(glab.currentUsername == nil)
        #expect(glab.authStatus == .unknown)
        try Data().write(to: URL(fileURLWithPath: executable.path + "-online"))

        settings.onboardingCompleted = true
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
    }
}
