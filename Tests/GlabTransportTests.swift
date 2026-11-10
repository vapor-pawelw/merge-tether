import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct GlabTransportTests {
    @Test func injectedTransportDecodesResponsesAndReceivesTheExactCommand() async throws {
        var calls: [[String]] = []
        let glab = GlabService(commandRunner: { executable, arguments, environment, timeout, authorization in
            #expect(executable.path == "/nonexistent/fixture-glab")
            #expect(environment["HOME"] != nil && environment["PATH"] != nil)
            #expect(environment["GITLAB_TOKEN"] == nil)
            #expect(timeout == 15)
            #expect(authorization == nil)
            calls.append(arguments)
            return .init(stdout: Data(#"{"id":3,"username":"me"}"#.utf8), stderr: "", exitCode: 0)
        })
        glab.glabPath = URL(fileURLWithPath: "/nonexistent/fixture-glab")

        let user = try await glab.fetchAuthenticatedUser(host: "gitlab.example.test", expectedUsername: "me")

        #expect(user.id == 3)
        #expect(calls == [["api", "/user", "--hostname", "gitlab.example.test"]])
    }

    @Test func injectedTransportPreservesTimeoutAndExitErrorClassification() async throws {
        let timeout = GlabService(commandRunner: { _, _, _, _, _ in throw ProcessRunner.RunError.timedOut })
        timeout.glabPath = URL(fileURLWithPath: "/nonexistent/fixture-glab")
        await #expect(throws: GlabError.timedOut) {
            _ = try await timeout.fetchAuthenticatedUser(host: "gitlab.example.test", expectedUsername: "me")
        }
        let denied = GlabService(commandRunner: { _, _, _, _, _ in
            .init(stdout: Data(), stderr: "403 Forbidden", exitCode: 1)
        })
        denied.glabPath = timeout.glabPath
        await #expect(throws: GlabError.nonZeroExit(code: 1, stderr: "403 Forbidden")) {
            _ = try await denied.fetchAuthenticatedUser(host: "gitlab.example.test", expectedUsername: "me")
        }
    }

    @Test func aFreshSessionKeepsItsTransportAndRequiresFreshAccountEvidence() async throws {
        var reads = 0
        let original = GlabService(commandRunner: { _, _, _, _, _ in
            reads += 1
            return .init(stdout: Data(#"{"id":3,"username":"me"}"#.utf8), stderr: "", exitCode: 0)
        })
        original.glabPath = URL(fileURLWithPath: "/nonexistent/fixture-glab")
        original.currentUsername = "previous-user"
        original.resolvedHost = "previous.example.test"
        let fresh = original.freshSession()
        #expect(fresh.currentUsername == nil && fresh.resolvedHost == nil && fresh.glabPath == nil)
        fresh.glabPath = original.glabPath

        let user = try await fresh.fetchAuthenticatedUser(host: "gitlab.example.test", expectedUsername: "me")

        #expect(reads == 1 && user.id == 3)
        #expect(original.currentUsername == "previous-user")
    }
}
