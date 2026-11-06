import Foundation
import Testing
@testable import GitLabTodos

struct AssistantExecutionSandboxTests {
    private let policy = AssistantExecutionSandbox(workspace: URL(fileURLWithPath: "/tmp/run"),
        evidenceRoot: URL(fileURLWithPath: "/tmp/evidence"), host: "gitlab.example.org:8443")

    @Test func appPermissionRecordsAreNeverWritableRoots() {
        #expect(!policy.writableEvidenceDirectories.contains(policy.evidenceRoot))
        #expect(!policy.writableEvidenceDirectories.contains { $0.path.contains("follow-up-runs") })
        #expect(policy.writableEvidenceDirectories.contains { $0.lastPathComponent == "follow-up-locks" })
    }

    @Test func claudeCannotFallBackToUnsandboxedWritesOrUseUnsandboxedFileEditors() throws {
        let settings = try #require(JSONSerialization.jsonObject(with: Data(policy.claudeSettings.utf8)) as? [String: Any])
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        #expect(filesystem["disabled"] as? Bool == false)
        #expect(filesystem["allowWrite"] as? [String] == policy.writableEvidenceDirectories.map(\.path))
        #expect(policy.claudeTools == "Read,Glob,Grep,Bash")
        let network = try #require(sandbox["network"] as? [String: Any])
        #expect(network["allowedDomains"] as? [String] == ["gitlab.example.org"])
    }
}
