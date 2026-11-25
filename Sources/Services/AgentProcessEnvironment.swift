import Foundation

/// Defense-in-depth environment adjustments for app-started agent CLIs.
///
/// This is not an operating-system or credential sandbox. Agents still run as the signed-in macOS user with
/// full tool access, so they can read that user's files (including glab configuration and SSH keys on disk)
/// or bypass these settings deliberately. The adjustments only remove ambient authority that a task does not
/// need and make an unauthorized ordinary `git push` fail instead of silently reaching a remote.
enum AgentProcessEnvironment {
    /// Push URLs are rewritten to this unsupported scheme, so Git refuses the push before any network access.
    static let pushGuardScheme = "mergetether-push-disabled://"
    /// Network remote prefixes. Local path and `file://` remotes stay usable for repository test suites.
    static let pushGuardedPrefixes = ["https://", "http://", "ssh://", "git://", "git@"]

    /// Adds `url.<guard>.pushInsteadOf` entries through `GIT_CONFIG_COUNT`, which Git applies after its
    /// configuration files. Remotes with an explicit `pushurl` are not rewritten by Git.
    static func withoutNetworkPush(_ base: [String: String]) -> [String: String] {
        var environment = base
        // Preserve earlier entries; an unparsable count would make Git reject them all, so it is replaced.
        var index = base["GIT_CONFIG_COUNT"].flatMap { Int($0) }.map { max($0, 0) } ?? 0
        for prefix in pushGuardedPrefixes {
            environment["GIT_CONFIG_KEY_\(index)"] = "url.\(pushGuardScheme).pushInsteadOf"
            environment["GIT_CONFIG_VALUE_\(index)"] = prefix
            index += 1
        }
        environment["GIT_CONFIG_COUNT"] = String(index)
        return environment
    }

    /// Read-only roles (verifiers, classifiers, draft generators) never clone over SSH or push.
    /// They keep authenticated `glab` API reads but lose the forwarded SSH agent.
    static func readOnly(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        return withoutNetworkPush(environment)
    }

    /// Executable MR workers keep SSH for fetching sources. Pushes stay available only when the
    /// handoff carries a push permission that MergeTether already checked against current policy.
    static func worker(_ base: [String: String], pushPermitted: Bool) -> [String: String] {
        pushPermitted ? base : withoutNetworkPush(base)
    }

    /// The account-bound environment shared by lightweight read-only verifier CLIs.
    @MainActor static var verifier: [String: String] {
        var environment = AssistantCLI.environment
        for (key, value) in GlabService.shellEnvironment { environment[key] = value }
        environment["PATH"] = AssistantCLI.environment["PATH"]
        return readOnly(environment)
    }

    static func pushPermitted(_ handoff: AssistantAutomationRunner.Handoff) -> Bool {
        handoff.allowsPush || handoff.followUpPushAllowed == true
    }
}
