import Foundation
import Testing
@testable import GitLabTodos

struct AssistantJobInvocationTests {
    @MainActor @Test(arguments: AutomationAssistant.allCases)
    func bothWorkersReceiveBoundedRequiredRuntimeRecoveryWithoutExtraPermissions(_ assistant: AutomationAssistant) async throws {
        // given
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "RequiredRuntimeRecovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: assistant)
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let sha = String(repeating: "a", count: 40)
        let glab = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            case "$*" in
              'config get host') printf '%s' '\(host)' ;;
              'auth status') printf '%s' 'Logged in to \(host) as me' >&2 ;;
              'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
              'api /projects/7/merge_requests/11 '*) printf '%s' '{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},"title":"Fixture","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened","sha":"\(sha)","source_branch":"feature","target_branch":"main","labels":[]}' ;;
              *) exit 20 ;;
            esac
            """.utf8).write(to: glab)
        let cli = folder.appending(path: "cli")
        try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            pathlib.Path(__file__+'.capture').write_text(sys.stdin.read())
            pathlib.Path(__file__+'.args').write_text(json.dumps(args))
            result={'status':'succeeded','summary':'Synthetic task; no external effects.','blocker':None}
            if args[0]=='exec':
                json.dump(result,open(args[args.index('--output-last-message')+1],'w'))
                print(json.dumps({'type':'turn.completed'}))
            else:
                print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: cli)
        for executable in [glab, cli] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        settings.glabPath = glab
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: assistant, work: .init(host: host, projectID: 7, iid: 11),
                username: "me", workspace: "", access: .gitLabRead),
            title: "Verify assigned code", prompt: "Task: verify assigned code. This task does not authorize GitLab writes.",
            createdAt: Date(), allowsPush: false, followUpPushAllowed: true, workflow: .followUp,
            manual: true, expectedHeadSHA: sha)
        let run = URL.homeDirectory.appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Assistant Runs/\(handoff.id.uuidString)")
        defer { try? FileManager.default.removeItem(at: run) }

        // when
        let outcome = try await AssistantJobExecutor.execute(handoff, settings: settings, detectCLI: { _ in .ready(cli) })

        // then
        #expect(outcome.result.status == .succeeded)
        let instructions = try String(contentsOf: URL(fileURLWithPath: cli.path + ".capture"), encoding: .utf8)
        #expect(instructions.contains(handoff.prompt))
        #expect(instructions.contains("Do not open coding-agent desktop apps"))
        #expect(!instructions.contains("Do not open desktop apps,"))
        #expect(instructions.contains("installed and configured local runtime"))
        #expect(instructions.contains("docker context show") && instructions.contains("orbctl start"))
        #expect(instructions.contains("orbctl status") && instructions.contains("docker info"))
        #expect(instructions.contains("at most 60 seconds"))
        #expect(instructions.contains("retry the failed verification or commit hook once"))
        #expect(instructions.contains("reconcile git status and recent git log"))
        #expect(instructions.contains("Never repeat a completed commit or push"))
        #expect(instructions.contains("Do not install tools, change global runtime versions or Docker contexts"))
        #expect(instructions.contains("reset or delete containers, recreate VMs, or change service settings"))
        #expect(instructions.contains("Do not stop other work, bypass checks or security controls, or request interactive passwords"))
        #expect(instructions.contains("does not authorize replaying GitLab writes or expanding task permissions"))
        #expect(instructions.contains("Informational acknowledgements are performed by MergeTether"))
        #expect(instructions.contains("Do not add reactions or resolve purely informational threads in this worker"))
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: cli.path + ".args")))
        if assistant == .codex {
            #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        } else {
            #expect(arguments.contains("--dangerously-skip-permissions"))
            #expect(value(after: "--tools", in: arguments) == "default")
        }
    }

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
