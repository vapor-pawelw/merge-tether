import Foundation

/// CLI subprocess adapter. Remote effects remain subject to MergeTether's existing evidence gates.
enum AssistantJobExecutor {
    enum ExecutionError: Error, Equatable { case cliUnavailable, wrongAccount, inactiveMergeRequest, missingResult, disabledPermission, headChanged }

    @MainActor
    static func execute(_ handoff: AssistantAutomationRunner.Handoff, settings: SettingsManager) async throws -> AssistantJobCoordinator.Outcome {
        try validateConfiguration(handoff, automation: settings.automation)
        try validateIgnoredTarget(handoff, ignored: settings.ignoredMergeRequests)
        guard case .ready(let executable) = await AssistantCLI.detect(handoff.key.assistant, requireCLI: true) else {
            throw ExecutionError.cliUnavailable
        }
        try Task.checkCancellation()
        let glab = GlabService()
        if let executable = settings.glabPath { glab.glabPath = executable }
        else { glab.glabPath = await OnboardingDetector.findGlabExecutable() }
        guard await glab.recheck() == nil, glab.authStatus == .authenticated,
              glab.resolvedHost == handoff.key.work.host, glab.currentUsername == handoff.key.username else {
            throw ExecutionError.wrongAccount
        }
        let user = try await glab.fetchAuthenticatedUser(host: handoff.key.work.host, expectedUsername: handoff.key.username)
        let request = try await glab.fetchMergeRequest(projectID: handoff.key.work.projectID,
                                                      iid: handoff.key.work.iid, host: handoff.key.work.host)
        guard request.state == "opened" else { throw ExecutionError.inactiveMergeRequest }
        try validateHeadSnapshot(expected: handoff.expectedHeadSHA, actual: request.sha)
        if handoff.followUpPushAllowed == true {
            guard settings.automation.allowFollowUpPush, request.author.id == user.id else { throw ExecutionError.disabledPermission }
        }
        if let reservation = handoff.pipelineReservation {
            guard request.author.id == user.id, request.headPipeline?.id == reservation.pipelineID,
                  request.headPipeline?.status == "failed", request.headPipeline?.sha == request.sha,
                  request.sha != nil else { throw ExecutionError.inactiveMergeRequest }
        }
        try validateConfiguration(handoff, automation: settings.automation)
        try validateIgnoredTarget(handoff, ignored: settings.ignoredMergeRequests)
        let project = request.webURL.gitLabProjectPath
        guard settings.automation.assistant == handoff.key.assistant,
              handoff.manual == true || settings.automation.scope.permits(request, host: handoff.key.work.host, username: handoff.key.username),
              handoff.resolvesOwnThreads != true || settings.automation.autoResolveOwnReviewThreads,
              !handoff.allowsPush || settings.automation.permitsConflictPush(project: project),
              handoff.key.access != .configuredTools || settings.automation.permitsAssistantTools(project: project)
        else { throw ExecutionError.disabledPermission }
        try Task.checkCancellation()
        let folder = URL.homeDirectory.appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Assistant Runs")
            .appending(path: handoff.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A failed or local-only fix may contain changes the user still needs.
        // Keep run files inspectable rather than deleting them at subprocess exit.
        if let index = settings.assistantHandoffs.firstIndex(where: { $0.id == handoff.id }) {
            settings.assistantHandoffs[index].execution?.workingDirectory = folder.path
            settings.save()
        }
        let evidenceDirectory = ReviewVerdictStore.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let sandbox = AssistantExecutionSandbox(workspace: folder, evidenceRoot: evidenceDirectory, host: handoff.key.work.host)
        try sandbox.prepare()
        let instructions = handoff.prompt + """

            This is a headless MergeTether run. Do not open desktop apps, create GUI chats, or request interactive input.
            Keep working files and isolated Git worktrees beneath this run's working directory. Never modify another checkout.
            This is an empty scratch directory, not an existing repository. If you need source code, read the live source project
            (project ID \(request.sourceProjectID ?? request.projectID)) with glab, obtain its clone URL, and clone it beneath this directory.
            Fetch the exact current MR head \(request.sha ?? "(read from live MR)") without updating other local branches.
            Only the helper evidence subdirectories are writable; app-owned follow-up permission records remain read-only.
            The bundled verification helpers can record receipts there;
            no assistant desktop app, installed plugin or listener is required. Use helper shell fallbacks from the instructions.
            The verified account is \(handoff.key.username) on \(handoff.key.work.host); recheck before remote writes.
            Use only the task's explicit permissions. If a command needs unavailable approval or evidence, stop with status blocked.
            In your final structured result, status succeeded means the assigned work finished; it never substitutes for remote verification receipts.
            Return status blocked if any requested work remains undone, a required tool was denied, or meaningful verification is missing.
            Include the MR link, actions, verification and remaining blockers in summary. Do not claim private drafts were saved unless re-fetched.
            For a blocked result, set blocker to one concise English sentence naming the exact stopped
            step and its actual cause, so the MR card explains why automatic progress stopped.
            Do not use a generic status such as "blocked" as the explanation. For succeeded, set blocker to null.
            """
        let input = Data(instructions.utf8)
        let output: ProcessRunner.Output
        var capturedOutput: ProcessRunner.Output?
        let result: AssistantJobResult
        do {
        if handoff.key.assistant == .codex {
            let schema = folder.appending(path: "schema.json")
            let response = folder.appending(path: "result.json")
            try Data(AssistantJobResult.schema.utf8).write(to: schema, options: .atomic)
            var arguments = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                             "--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=true",
                             "--disable", "apps", "--disable", "plugins", "--disable", "memories",
                             "--output-schema", schema.path, "--output-last-message", response.path, "--json"]
            for directory in sandbox.writableEvidenceDirectories { arguments += ["--add-dir", directory.path] }
            if let model = handoff.reviewModel { arguments += ["--model", model.rawValue] }
            if let thinking = handoff.reviewThinking { arguments += ["-c", "model_reasoning_effort=\"\(thinking.rawValue)\""] }
            arguments.append("-")
            output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                                                  currentDirectory: folder, timeout: 1_800, input: input)
            capturedOutput = output
            guard output.exitCode == 0 else { throw CLIProcessError(exitCode: output.exitCode, diagnostic: output.stderr) }
            try AssistantJobResult.validateCodexEvents(output.stdout)
            guard let data = try? Data(contentsOf: response) else { throw ExecutionError.missingResult }
            result = try AssistantJobResult.codex(data)
        } else {
            // File editing tools bypass Claude's Bash sandbox, so edits are performed
            // through the sandboxed shell only. Missing sandbox support fails closed.
            let arguments = ["-p", "--safe-mode", "--permission-mode", "dontAsk", "--permission-prompts", "none",
                             "--tools", sandbox.claudeTools, "--allowedTools", sandbox.claudeTools,
                             "--settings", sandbox.claudeSettings,
                             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                             "--no-session-persistence", "--output-format", "json", "--json-schema", AssistantJobResult.schema]
            output = try await ProcessRunner.run(executable, arguments: arguments, environment: environment,
                                                  currentDirectory: folder, timeout: 1_800, input: input)
            capturedOutput = output
            guard output.exitCode == 0 else { throw CLIProcessError(exitCode: output.exitCode, diagnostic: output.stderr) }
            result = try AssistantJobResult.claude(output.stdout)
        }
        try Task.checkCancellation()
        } catch {
            if let capturedOutput, !(error is CancellationError) {
                throw AssistantJobFailure(error: error, output: capturedOutput)
            }
            throw error
        }
        let transcript = GlabService.redactWorkflowEvidence(String(decoding: output.stdout, as: UTF8.self) + "\n" + output.stderr)
        return .init(result: result, output: transcript)
    }

    static func validateIgnoredTarget(_ handoff: AssistantAutomationRunner.Handoff, ignored: Set<MRAutomationScope.Target>) throws {
        let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                                              projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
        guard !ignored.contains(target) else { throw ExecutionError.disabledPermission }
    }

    static func validateConfiguration(_ handoff: AssistantAutomationRunner.Handoff, automation: AutomationSettings) throws {
        guard handoff.manual == true || handoff.configurationSnapshot?.preservingScope(from: automation) == automation else {
            throw ExecutionError.disabledPermission
        }
    }

    static func validateHeadSnapshot(expected: String?, actual: String?) throws {
        guard let expected, !expected.isEmpty, actual == expected else { throw ExecutionError.headChanged }
    }

    @MainActor private static var environment: [String: String] {
        var value = AssistantCLI.environment
        // The agent's glab child must use the same explicitly selected local account configuration.
        for (key, entry) in GlabService.shellEnvironment { value[key] = entry }
        value["PATH"] = AssistantCLI.environment["PATH"]
        return value
    }

    private struct CLIProcessError: Error, CustomStringConvertible {
        let exitCode: Int32
        let diagnostic: String
        var description: String { "CLI exit \(exitCode): \(GlabService.redactWorkflowEvidence(String(diagnostic.suffix(8_000))))" }
    }
}
