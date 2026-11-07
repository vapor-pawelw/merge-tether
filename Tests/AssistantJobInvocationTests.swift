import Foundation
import Testing
@testable import GitLabTodos

struct AssistantJobInvocationTests {
    @Test func childProcessesHaveAWritablePrivateTemporaryDirectoryEvenWithSpaces() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Worker files \(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let invocation = AssistantJobInvocation(workspace: folder, evidenceRoot: folder.appending(path: "evidence"))
        try invocation.prepareEvidenceDirectories()
        let environment = invocation.childEnvironment(["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"])
        #expect(environment["TMPDIR"] == invocation.temporaryDirectory.path)
        #expect(environment["JAVA_TOOL_OPTIONS"]?.contains("-Djava.io.tmpdir=") == true)
        let child = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -n \"$TMPDIR\" && printf writable > \"$TMPDIR/probe\""],
            environment: environment, currentDirectory: folder, timeout: 5)
        #expect(child.exitCode == 0)
        #expect(try String(contentsOf: invocation.temporaryDirectory.appending(path: "probe"), encoding: .utf8) == "writable")
    }

    private let policy = AssistantJobInvocation(workspace: URL(fileURLWithPath: "/tmp/run"),
        evidenceRoot: URL(fileURLWithPath: "/tmp/evidence"))

    @Test func helperPreparationDoesNotCreateOrReplaceAppPermissionRecords() {
        #expect(!policy.helperEvidenceDirectories.contains(policy.evidenceRoot))
        #expect(!policy.helperEvidenceDirectories.contains { $0.path.contains("follow-up-runs") })
        #expect(policy.helperEvidenceDirectories.contains { $0.lastPathComponent == "follow-up-locks" })
    }

    @Test func workerHasAllToolsWithoutAnOSOrToolWriteRestriction() throws {
        let settings = try #require(JSONSerialization.jsonObject(with: Data(policy.claudeSettings.utf8)) as? [String: Any])
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == false)
        #expect(settings["permissions"] == nil)
        #expect(policy.claudeTools == "default")
    }

    @Test func codexWorkerBypassesSandboxAndApprovalsWithoutChangingItsResultContract() {
        let arguments = policy.codexArguments(model: .sol, thinking: .high)
        #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(arguments.contains("--ignore-rules"))
        #expect(!arguments.contains("--sandbox"))
        #expect(!arguments.contains("--add-dir"))
        #expect(value(after: "--output-schema", in: arguments) == policy.schemaURL.path)
        #expect(value(after: "--output-last-message", in: arguments) == policy.resultURL.path)
        #expect(value(after: "--model", in: arguments) == CodexReviewModel.sol.rawValue)
        #expect(arguments.contains(#"model_reasoning_effort="high""#))
        #expect(arguments.last == "-")
    }

    @Test func claudeWorkerDoesNotRequireApprovalOrRestrictTheToolSet() {
        let arguments = policy.claudeArguments
        #expect(arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--safe-mode"))
        #expect(!arguments.contains("--permission-mode"))
        #expect(!arguments.contains("--allowedTools"))
        #expect(value(after: "--tools", in: arguments) == "default")
        #expect(value(after: "--settings", in: arguments) == policy.claudeSettings)
        #expect(value(after: "--json-schema", in: arguments) == AssistantJobResult.schema)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
