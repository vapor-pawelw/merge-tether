import Foundation
import Testing
@testable import MergeTether

struct AgentProcessEnvironmentTests {
    private let base = ["HOME": "/Users/fixture", "PATH": "/usr/bin:/bin", "SSH_AUTH_SOCK": "/tmp/fixture-agent.sock"]

    @Test func workersWithoutPushPermissionKeepSSHFetchButGuardNetworkPushes() {
        let guarded = AgentProcessEnvironment.worker(base, pushPermitted: false)
        #expect(guarded["SSH_AUTH_SOCK"] == base["SSH_AUTH_SOCK"])
        #expect(guarded["GIT_CONFIG_COUNT"] == String(AgentProcessEnvironment.pushGuardedPrefixes.count))
        let values = (0..<AgentProcessEnvironment.pushGuardedPrefixes.count).map { guarded["GIT_CONFIG_VALUE_\($0)"] }
        #expect(values == AgentProcessEnvironment.pushGuardedPrefixes)
        #expect(AgentProcessEnvironment.worker(base, pushPermitted: true) == base)
    }

    @Test func readOnlyRolesLoseTheSSHAgentAndKeepEarlierGitConfiguration() {
        var configured = base
        configured["GIT_CONFIG_COUNT"] = "1"
        configured["GIT_CONFIG_KEY_0"] = "core.fixture"
        configured["GIT_CONFIG_VALUE_0"] = "kept"
        let environment = AgentProcessEnvironment.readOnly(configured)
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["HOME"] == base["HOME"] && environment["PATH"] == base["PATH"])
        #expect(environment["GIT_CONFIG_KEY_0"] == "core.fixture" && environment["GIT_CONFIG_VALUE_0"] == "kept")
        #expect(environment["GIT_CONFIG_COUNT"] == String(1 + AgentProcessEnvironment.pushGuardedPrefixes.count))
        #expect(environment["GIT_CONFIG_KEY_1"] == "url.\(AgentProcessEnvironment.pushGuardScheme).pushInsteadOf")

        var invalid = base
        invalid["GIT_CONFIG_COUNT"] = "not-a-number"
        #expect(AgentProcessEnvironment.readOnly(invalid)["GIT_CONFIG_KEY_0"] != nil)
        #expect(AgentProcessEnvironment.readOnly(invalid)["GIT_CONFIG_COUNT"] == String(AgentProcessEnvironment.pushGuardedPrefixes.count))
    }

    @MainActor @Test func verifierEnvironmentNeverForwardsTheSSHAgent() {
        let environment = AgentProcessEnvironment.verifier
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["HOME"] != nil && environment["PATH"] == AssistantCLI.environment["PATH"])
        #expect(environment["GIT_CONFIG_COUNT"] != nil)
    }

    @Test func pushPermissionFollowsTheHandoffsCheckedPermissions() {
        func handoff(allowsPush: Bool, followUp: Bool?) -> AssistantAutomationRunner.Handoff {
            .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                username: "me", workspace: "", access: .gitLabRead), title: "Fixture", prompt: "Fixture",
                createdAt: .now, allowsPush: allowsPush, followUpPushAllowed: followUp)
        }
        #expect(!AgentProcessEnvironment.pushPermitted(handoff(allowsPush: false, followUp: nil)))
        #expect(!AgentProcessEnvironment.pushPermitted(handoff(allowsPush: false, followUp: false)))
        #expect(AgentProcessEnvironment.pushPermitted(handoff(allowsPush: true, followUp: nil)))
        #expect(AgentProcessEnvironment.pushPermitted(handoff(allowsPush: false, followUp: true)))
    }

    /// Uses the local Git executable against a synthetic repository; nothing is fetched or pushed.
    @Test func gitRewritesNetworkPushURLsButLeavesFetchAndLocalRemotes() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "push-guard-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var isolated = ["HOME": folder.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                        "GIT_CONFIG_GLOBAL": "/dev/null"]
        func git(_ arguments: [String], _ environment: [String: String]) async throws -> String {
            let output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                currentDirectory: folder, timeout: 10)
            #expect(output.exitCode == 0, "\(arguments): \(output.stderr)")
            return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q"], isolated)
        let remotes = ["https": "https://gitlab.example.test/team/repo.git", "scp": "git@gitlab.example.test:team/repo.git",
                       "ssh": "ssh://git@gitlab.example.test/team/repo.git", "local": folder.appending(path: "bare.git").path]
        for (name, url) in remotes { _ = try await git(["remote", "add", name, url], isolated) }
        let guarded = AgentProcessEnvironment.worker(isolated, pushPermitted: false)
        for (name, url) in remotes {
            let push = try await git(["remote", "get-url", "--push", name], guarded)
            let fetch = try await git(["remote", "get-url", name], guarded)
            #expect(fetch == url)
            #expect(push.hasPrefix(AgentProcessEnvironment.pushGuardScheme) == (name != "local"), "\(name): \(push)")
        }
        isolated["GIT_CONFIG_COUNT"] = "0"
        #expect(try await git(["remote", "get-url", "--push", "https"], isolated) == remotes["https"])
    }
}
