import Foundation

/// CLI subprocess adapter. Remote effects remain subject to MergeTether's existing evidence gates.
enum AssistantJobExecutor {
    enum ExecutionError: Error, Equatable { case cliUnavailable, wrongAccount, inactiveMergeRequest, missingResult, disabledPermission, headChanged }
    struct PersistenceUnavailable: Error, CustomStringConvertible {
        var description: String { String(localized: .Settings.settingsPersistenceActionBlocked) }
    }

    @MainActor static func validatePersistence(_ settings: SettingsManager) throws {
        guard settings.automaticActionsAllowed else { throw PersistenceUnavailable() }
    }

    @MainActor
    static func execute(_ handoff: AssistantAutomationRunner.Handoff, settings: SettingsManager) async throws -> AssistantJobCoordinator.Outcome {
        try await execute(handoff, settings: settings, detectCLI: { await AssistantCLI.detect($0, requireCLI: true) })
    }

    @MainActor
    static func execute(_ handoff: AssistantAutomationRunner.Handoff, settings: SettingsManager,
                        detectCLI: @MainActor (AutomationAssistant) async -> AssistantDependencyStatus) async throws -> AssistantJobCoordinator.Outcome {
        try validatePersistence(settings)
        try validateConfiguration(handoff, automation: settings.automation)
        try validateIgnoredTarget(handoff, ignored: settings.ignoredMergeRequests)
        guard case .ready(let executable) = await detectCLI(handoff.key.assistant) else {
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
        try validateReviewOwnership(isReview: handoff.workflow == .review || handoff.reviewModel != nil,
            authorID: request.author.id, userID: user.id)
        if handoff.followUpPushAllowed == true {
            guard settings.automation.hasAutomaticActionConsent, settings.automation.allowFollowUpPush, request.author.id == user.id else { throw ExecutionError.disabledPermission }
        }
        if let repair = handoff.draftRepair {
            guard handoff.workflow == .followUp, handoff.followUpPushAllowed == true,
                  repair.assistant == handoff.key.assistant,
                  repair.codingModel == settings.automation.codexReviewModel,
                  repair.codingThinking == settings.automation.codexReviewThinking else { throw ExecutionError.disabledPermission }
            let snapshot = DraftProofRecoveryCoordinator.Snapshot(request: request, discussions: [], drafts: [],
                user: user, host: handoff.key.work.host, branchHead: request.sha ?? "")
            try await DraftReplyRepair.validate(repair, snapshot: snapshot, settings: settings, glab: glab, excludingRunID: handoff.id)
        }
        if let reservation = handoff.pipelineReservation {
            guard request.author.id == user.id, request.headPipeline?.id == reservation.pipelineID,
                  reservation.host == handoff.key.work.host, reservation.projectID == request.projectID,
                  reservation.mergeRequestIID == request.iid else { throw ExecutionError.inactiveMergeRequest }
            _ = try await glab.verifiedFailedPipeline(for: request, host: handoff.key.work.host, expectedUser: user)
        }
        let ignoredFeedback = try await IgnoredFeedbackWorkerInstructions.load(for: handoff, settings: settings, glab: glab)
        try validateConfiguration(handoff, automation: settings.automation)
        try validateIgnoredTarget(handoff, ignored: settings.ignoredMergeRequests)
        let project = request.webURL.gitLabProjectPath
        guard settings.automation.assistant == handoff.key.assistant,
              handoff.manual == true || settings.automation.scope.permits(request, host: handoff.key.work.host, username: handoff.key.username),
              handoff.resolvesOwnThreads != true || (settings.automation.hasAutomaticActionConsent && settings.automation.autoResolveOwnReviewThreads),
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
            recordFeedbackContext(ignoredFeedback.decisionRevision, for: handoff, at: index, settings: settings)
            settings.save()
        }
        try validatePersistence(settings)
        let evidenceDirectory = ReviewVerdictStore.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let invocation = AssistantJobInvocation(workspace: folder, evidenceRoot: evidenceDirectory)
        try invocation.prepareEvidenceDirectories()
        let generationBaseline = try? await glab.fetchOwnDraftNotes(projectID: request.projectID, iid: request.iid,
            host: handoff.key.work.host, userID: user.id)
        let instructions = handoff.prompt + """

            This is a headless MergeTether run. Do not open coding-agent desktop apps, create GUI chats, or request interactive input.
            Keep working files and isolated Git worktrees beneath this run's working directory. Never modify another checkout.
            Preserve the MR's Draft or Ready status. Never mark a Draft ready, undraft it, or merge it in this worker.
            MergeTether handles an explicit user's Mark ready action separately; Draft automation does not authorize that change.
            If an assigned check or mandatory commit hook fails because an installed and configured local runtime
            is stopped, diagnose the exact failed command and configured endpoint, then start only that required
            runtime using its service CLI. For Docker, inspect `docker context show` and its endpoint first.
            When the active context is `orbstack` and installed `orbctl status` reports stopped, use `orbctl start`.
            A visible OrbStack GUI is not proof of a running daemon. Bound startup and readiness polling to at most 60 seconds;
            check both `orbctl status` and `docker info` before proceeding. For another configured runtime, use its documented
            service CLI and readiness check. Do not start services that the assigned work does not need.
            After readiness, reconcile git status and recent git log with the failed command's output before retrying;
            if the original local operation did not complete, retry the failed verification or commit hook once.
            Never repeat a completed commit or push. If a check still fails, inspect its exact command and arguments,
            including path quoting; do not edit global hooks or relax the check to make it pass.
            Do not install tools, change global runtime versions or Docker contexts,
            reset or delete containers, recreate VMs, or change service settings.
            Do not stop other work, bypass checks or security controls, or request interactive passwords or OS consent.
            Runtime recovery does not authorize replaying GitLab writes or expanding task permissions.
            If safe recovery or readiness cannot be established within the bound, report the exact command and remaining cause.
            Informational acknowledgements are performed by MergeTether after its current verifier and policy checks.
            Do not add reactions or resolve purely informational threads in this worker, even if an installed
            general instruction grants that permission outside this headless run. Do not create courtesy reply drafts.
            Existing explicit permissions for resolving your own substantive review findings remain unchanged.
            A writable private temporary directory is supplied in TMPDIR, TMP and TEMP, and in JAVA_TOOL_OPTIONS
            as java.io.tmpdir. Preserve that JVM option when invoking Maven or Gradle; if a wrapper overrides it,
            pass -Djava.io.tmpdir with TMPDIR explicitly. Do not disable tests to work around temporary-file failures.
            This is an empty scratch directory, not an existing repository. If you need source code, read the live source project
            (project ID \(request.sourceProjectID ?? request.projectID)) with glab, obtain its clone URL, and clone it beneath this directory.
            Fetch the exact current MR head \(request.sha ?? "(read from live MR)") without updating other local branches.
            The CLI has full tool, filesystem and network access without an interactive approval prompt.
            Full tool access does not authorize extra GitLab actions. Do not edit app-owned policy or proof records
            directly; use the bundled verification helpers to record legitimate receipts.
            No assistant desktop app, installed plugin or listener is required. Use helper shell fallbacks from the instructions.
            The verified account is \(handoff.key.username) on \(handoff.key.work.host); recheck before remote writes.
            Use only the task's explicit permissions. If a command needs unavailable approval or evidence, stop with status blocked.
            In your final structured result, status succeeded means the assigned work finished; it never substitutes for remote verification receipts.
            For an author follow-up, implementing and verifying the warranted fix and saving, re-fetching and sealing its
            private reply completes the worker's part. Publication belongs to MergeTether's separate policy checks.
            When only publication, reviewer acceptance, approval or merge is pending, report succeeded with those next
            steps in summary; do not wait for publication or classify that wait as unfinished worker work.
            Return status blocked if assigned code, tests, remote delivery or reply preparation remains unfinished,
            a required tool was denied, or meaningful verification is missing.
            In generatedDrafts, list only private drafts you actually created or substantially rewrote in THIS run,
            as {id,bodySHA256}. Re-fetch each exact draft and compute SHA-256 from its exact parsed UTF-8 note body,
            preserving whitespace and Unicode. Do not list untouched, user-created or merely observed drafts.
            Return [] when you saved no generated drafts. This declaration records authorship for display only:
            it grants no publication, approval or verification permission and never replaces a follow-up seal.
            Include the MR link, actions, verification and remaining blockers in summary. Do not claim private drafts were saved unless re-fetched.
            \(AgentExplanation.instructions(for: "blocker"))
            Keep the detailed run evidence and completed actions in summary and the transcript.
            For a blocked result, set blocker to one concise English sentence naming the exact stopped
            step and its actual cause, so the MR card explains why automatic progress stopped.
            Do not use a generic status such as "blocked" as the explanation. For succeeded, set blocker to null.
            """ + ignoredFeedback.instructions
        try AssistantJobJournal.prepare(handoff.id)
        let input = Data(instructions.utf8)
        let instructionsURL = folder.appending(path: "instructions.txt")
        try input.write(to: instructionsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: instructionsURL.path)
        let output: ProcessRunner.Output
        var capturedOutput: ProcessRunner.Output?
        let result: AssistantJobResult
        let usageMergeRequest = AssistantUsageMergeRequest(host: handoff.key.work.host, username: handoff.key.username,
            projectID: handoff.key.work.projectID, iid: handoff.key.work.iid, title: request.title,
            url: request.webURL.absoluteString)
        do {
        if handoff.key.assistant == .codex {
            try Data(AssistantJobResult.schema.utf8).write(to: invocation.schemaURL, options: .atomic)
            let arguments = invocation.codexArguments(model: handoff.codingModel ?? handoff.reviewModel,
                thinking: handoff.codingThinking ?? handoff.reviewThinking)
            output = try await AssistantUsageRunner.run(executable, arguments: arguments, environment: invocation.childEnvironment(environment),
                                                  currentDirectory: folder, timeout: 1_800, input: input,
                                                  outputDirectory: folder.appendingPathComponent("cli-output"),
                                                  usage: .init(role: .codingAgent, assistant: handoff.key.assistant,
                                                    model: (handoff.codingModel ?? handoff.reviewModel)?.rawValue,
                                                    mergeRequest: usageMergeRequest),
                                                  beforeLaunch: { @MainActor in
                                                      try validatePersistence(settings)
                                                      try validateConfiguration(handoff, automation: settings.automation)
                                                  })
            capturedOutput = output
            guard output.exitCode == 0 else { throw CLIProcessError(exitCode: output.exitCode, diagnostic: output.stderr) }
            try AssistantJobResult.validateCodexEvents(output.stdout)
            guard let data = try? Data(contentsOf: invocation.resultURL) else { throw ExecutionError.missingResult }
            result = try AssistantJobResult.codex(data)
        } else {
            let arguments = invocation.claudeArguments
            output = try await AssistantUsageRunner.run(executable, arguments: arguments, environment: invocation.childEnvironment(environment),
                                                  currentDirectory: folder, timeout: 1_800, input: input,
                                                  outputDirectory: folder.appendingPathComponent("cli-output"),
                                                  usage: .init(role: .codingAgent, assistant: handoff.key.assistant,
                                                    model: (handoff.codingModel ?? handoff.reviewModel)?.rawValue,
                                                    mergeRequest: usageMergeRequest),
                                                  beforeLaunch: { @MainActor in
                                                      try validatePersistence(settings)
                                                      try validateConfiguration(handoff, automation: settings.automation)
                                                  })
            capturedOutput = output
            guard output.exitCode == 0 else { throw CLIProcessError(exitCode: output.exitCode, diagnostic: output.stderr) }
            result = try AssistantJobResult.claude(output.stdout)
        }
        } catch {
            if let capturedOutput, !(error is CancellationError) {
                throw AssistantJobFailure(error: error, output: capturedOutput)
            }
            throw error
        }
        let transcript = GlabService.redactWorkflowEvidence(String(decoding: output.stdout, as: UTF8.self) + "\n" + output.stderr)
        let outcome = AssistantJobCoordinator.Outcome(result: result, output: transcript)
        await recordGeneratedDrafts(result, baseline: generationBaseline, user: user, request: request,
            handoff: handoff, settings: settings, glab: glab)
        do { try await AssistantJobJournal.save(outcome, for: handoff) }
        catch { Log.monitor.error("Could not checkpoint worker completion: \(String(describing: error), privacy: .private)") }
        try Task.checkCancellation()
        return outcome
    }

    @MainActor
    static func recordGeneratedDrafts(_ result: AssistantJobResult, baseline: [GitLabDraftNote]?,
        user: GitLabAuthenticatedUser, request: GitLabMergeRequest, handoff: AssistantAutomationRunner.Handoff,
        settings: SettingsManager, glab: GlabService, directory: URL = AICommentProvenanceStore.directory) async {
        let work = handoff.key.work
        let revision = glab.accountRevision
        func current() -> Bool {
            !Task.isCancelled && glab.accountRevision == revision && glab.resolvedHost == work.host
                && glab.currentUsername == handoff.key.username
                && settings.assistantHandoffs.contains { $0.id == handoff.id && $0.key == handoff.key && $0.expectedHeadSHA == handoff.expectedHeadSHA && $0.execution?.state.isActive == true }
        }
        guard let claims = result.generatedDrafts, !claims.isEmpty, let baseline, current(),
              request.projectID == work.projectID, request.iid == work.iid,
              let expectedHead = handoff.expectedHeadSHA, expectedHead == request.sha else { return }
        do {
            let authenticated = try await glab.fetchAuthenticatedUser(host: work.host, expectedUsername: handoff.key.username)
            let live = try await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: work.host)
            guard current(), authenticated == user, live.projectID == request.projectID, live.iid == request.iid,
                  live.webURL == request.webURL, live.sourceProjectID == request.sourceProjectID,
                  live.sourceBranch == request.sourceBranch, live.targetProjectID == request.targetProjectID,
                  live.targetBranch == request.targetBranch, live.state == "opened", let head = live.sha, !head.isEmpty,
                  live.sha == request.sha || handoff.followUpPushAllowed == true || handoff.allowsPush else { return }
            let drafts = try await glab.fetchOwnDraftNotes(projectID: work.projectID, iid: work.iid, host: work.host, userID: user.id)
            guard current() else { return }
            let context = AICommentProvenanceStore.Context(host: work.host, username: user.username, userID: user.id,
                projectID: work.projectID, iid: work.iid)
            let runID = handoff.id
            try await Task.detached(priority: .utility) {
                try AICommentProvenanceStore.recordGenerated(claims, baseline: baseline, current: drafts,
                    context: context, runID: runID, headSHA: head, in: directory)
            }.value
            guard current() else { return }
        } catch {
            Log.monitor.error("Could not record generated comment origins: \(String(describing: error), privacy: .private)")
        }
    }

    @MainActor
    private static func recordFeedbackContext(_ revision: String?, for handoff: AssistantAutomationRunner.Handoff,
                                              at index: Int, settings: SettingsManager) {
        let previous = settings.assistantHandoffs[index].feedbackDecisionRevision
        settings.assistantHandoffs[index].feedbackDecisionRevision = revision
        guard previous != revision else { return }
        let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
            projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
        let notes = handoff.verifiedFeedbackNotes ?? [:]
        let corresponding = settings.authorFeedbackAttempts.filter {
            $0.target == target && notes[$0.noteID] == $0.revision && $0.decisionRevision == previous
                && ($0.recoveryRootID == nil || $0.recoveryRootID == handoff.feedbackRecoveryRootID)
        }
        for receipt in corresponding {
            // A receipt can also belong to another historical or running invocation.
            let shared = settings.assistantHandoffs.contains { other in
                other.id != handoff.id && other.key.work == handoff.key.work && other.key.username == handoff.key.username
                    && other.feedbackDecisionRevision == previous && other.verifiedFeedbackNotes?[receipt.noteID] == receipt.revision
                    && (receipt.recoveryRootID == nil || other.feedbackRecoveryRootID == receipt.recoveryRootID)
            }
            if !shared { settings.authorFeedbackAttempts.remove(receipt) }
            var current = receipt
            current.decisionRevision = revision
            settings.authorFeedbackAttempts.insert(current)
        }
    }

    static func validateIgnoredTarget(_ handoff: AssistantAutomationRunner.Handoff, ignored: Set<MRAutomationScope.Target>) throws {
        let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                                              projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
        guard !ignored.contains(target) else { throw ExecutionError.disabledPermission }
    }

    static func validateConfiguration(_ handoff: AssistantAutomationRunner.Handoff, automation: AutomationSettings) throws {
        guard !handoff.isObsoleteReminder else { throw ExecutionError.disabledPermission }
        let project = handoff.mergeRequestURL?.gitLabProjectPath ?? ""
        guard handoff.followUpPushAllowed != true || (automation.hasAutomaticActionConsent && automation.allowFollowUpPush),
              handoff.resolvesOwnThreads != true || (automation.hasAutomaticActionConsent && automation.autoResolveOwnReviewThreads),
              !handoff.allowsPush || automation.permitsConflictPush(project: project) else { throw ExecutionError.disabledPermission }
        guard handoff.manual == true || (automation.hasAutomaticActionConsent
            && handoff.configurationSnapshot?.preservingScope(from: automation) == automation) else {
            throw ExecutionError.disabledPermission
        }
    }

    static func validateHeadSnapshot(expected: String?, actual: String?) throws {
        guard let expected, !expected.isEmpty, actual == expected else { throw ExecutionError.headChanged }
    }

    static func validateReviewOwnership(isReview: Bool, authorID: Int, userID: Int) throws {
        guard !isReview || authorID != userID else { throw ExecutionError.disabledPermission }
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
