import Foundation
import Testing

@testable import GitLabTodos

@Suite("GitLab sign-in checks")
struct GlabAuthStatusTests {
    @MainActor
    @Test func aFailedStatusProbeDoesNotMisreportSignOutOrDiscardTheKnownAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        if test "$1" = config; then
          printf '%s' other.example.test
        else
          printf '%s' 'network is unreachable' >&2
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "alice"
        glab.authStatus = .authenticated

        let error = await glab.recheck()

        #expect(error == .network("network is unreachable"))
        #expect(glab.currentUsername == "alice")
        #expect(glab.resolvedHost == "gitlab.example.test")
        #expect(glab.authStatus == .authenticated)
    }

    @MainActor
    @Test func simultaneousSignInChecksShareOneProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        if test "$1" = config; then
          printf '%s' gitlab.example.test
        else
          printf x >> "$0-checks"
          sleep 0.1
          printf '%s' 'Logged in to gitlab.example.test as alice' >&2
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        async let first = glab.recheck()
        async let second = glab.recheck()
        let errors = await [first, second]
        #expect(errors.allSatisfy { $0 == nil })
        #expect(glab.currentUsername == "alice")
        #expect(try String(contentsOfFile: executable.path + "-checks", encoding: .utf8) == "x")
    }

    @MainActor
    @Test(arguments: ["network is unreachable", "not authenticated", "500 Internal Server Error"])
    func defaultHostFailuresPreserveTheCorrectAccountState(_ failure: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        if test "$1" = config; then
          printf '%s' gitlab.example.test
        else
          printf '%s\\n' 'Logged in to another.example.test as bob' 'gitlab.example.test: \(failure)' 'third.example.test: No token found' >&2
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "alice"
        glab.authStatus = .authenticated
        let error = await glab.recheck()
        if failure == "not authenticated" {
            #expect(error == nil)
            #expect(glab.currentUsername == nil)
            #expect(glab.authStatus == .wrongDefaultHost(authedHosts: [.init(host: "another.example.test", username: "bob")]))
        } else {
            #expect(error != nil)
            #expect(glab.currentUsername == "alice")
            #expect(glab.authStatus == .authenticated)
        }
    }

    @Test("extracts host + username pairs from multi-host status output")
    func parsesMultipleHosts() {
        let output = """
        gitlab.com
          x gitlab.com: API call failed: GET ... 401 Unauthorized
          ! No token found
        gitlab.corp.example.com
          ✓ Logged in to gitlab.corp.example.com as alice (/Users/a/Library/Application Support/glab-cli/config.yml)
          ✓ Token found: **************************
        """

        let hosts = GlabService.parseAuthedHosts(from: output)
        #expect(hosts.count == 1)
        #expect(hosts.first?.host == "gitlab.corp.example.com")
        #expect(hosts.first?.username == "alice")
    }

    @Test("returns empty when nothing is authenticated")
    func returnsEmptyWhenNoneAuthed() {
        let output = """
        gitlab.com
          x gitlab.com: API call failed: GET ... 401 Unauthorized
          ! No token found
        """
        #expect(GlabService.parseAuthedHosts(from: output).isEmpty)
    }

    @Test("handles multiple authed hosts and deduplicates")
    func collectsMultipleAuthedHosts() {
        let output = """
        ✓ Logged in to gitlab.com as alice
        ✓ Logged in to self.example.com as bob
        ✓ Logged in to gitlab.com as alice
        """
        let hosts = GlabService.parseAuthedHosts(from: output)
        #expect(hosts.count == 2)
        #expect(hosts.map(\.host) == ["gitlab.com", "self.example.com"])
    }
}
