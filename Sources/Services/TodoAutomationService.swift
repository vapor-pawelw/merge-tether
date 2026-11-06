import Foundation
import Observation

@MainActor
@Observable
final class TodoAutomationService {
    enum ActionState: Equatable {
        case ready(AutomationRunner), running, queuedForAssistant, finished, failed
    }

    private var running: Set<TodoAutomationReceipt> = []
    private var ineligible: Set<TodoAutomationReceipt> = []
    private struct RunningScript {
        let task: Task<ProcessRunner.Output, Error>
        let work: AssistantAutomationRunner.MergeRequestWork
        let username: String
        let manual: Bool
    }
    private var scriptTasks: [UUID: RunningScript] = [:]

    func cancelRunningScripts(outsideScope scope: MRAutomationScope? = nil) {
        for script in scriptTasks.values {
            if let scope {
                let target = MRAutomationScope.Target(host: script.work.host, username: script.username,
                    projectID: script.work.projectID, iid: script.work.iid)
                guard !script.manual, !scope.resolve(target).active else { continue }
            }
            script.task.cancel()
        }
    }

    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let jobCoordinator: AssistantJobCoordinator?

    init(canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = {
        await AssistantCLI.detect($0, requireCLI: true).isReady
    }, jobCoordinator: AssistantJobCoordinator? = nil) {
        self.canAutomate = canAutomate
        self.jobCoordinator = jobCoordinator
    }

    private struct Invocation: Equatable {
        let rule: AutomationRule
        let assistant: AutomationAssistant?
        let workspace: String
        let allowTools: Bool

        var access: AssistantAutomationRunner.Access {
            if assistant == .codex { return .gitLabRead }
            return allowTools ? .configuredTools : .preparation
        }
    }

    func prune(fetchedIDs: Set<Int>, host: String, username: String, settings: SettingsManager) {
        func isPending(_ key: TodoAutomationReceipt) -> Bool {
            key.host != host || key.username != username || fetchedIDs.contains(key.todoID) || running.contains(key)
        }

        settings.automationReceipts = settings.automationReceipts.filter(isPending)
        settings.automationAttemptReceipts = settings.automationAttemptReceipts.filter(isPending)
        settings.pendingTodoAcknowledgements = settings.pendingTodoAcknowledgements.filter {
            $0.host != host || $0.username != username || fetchedIDs.contains($0.todo.id)
        }
        ineligible = ineligible.filter(isPending)
    }

    func actionState(
        for todo: Todo, host: String, username: String,
        settings: SettingsManager, available: Set<AutomationAssistant>
    ) -> ActionState? {
        guard let event = TodoAutomationEvent(todo: todo, username: username),
              let iid = todo.target.iid, iid > 0, todo.targetURL.isGitLabMergeRequest(host: host, iid: iid)
        else { return nil }
        let key = TodoAutomationReceipt(host: host, username: username, todoID: todo.id)
        if ineligible.contains(key) { return nil }
        if let author = todo.target.author, !event.accepts(author: author, username: username) { return nil }
        if running.contains(key) { return .running }
        let rule = settings.automation[event]
        if settings.automationReceipts.contains(key) { return rule.runner == .assistant ? .queuedForAssistant : .finished }
        if settings.automationAttemptReceipts.contains(key) { return .failed }
        guard rule.isConfigured, rule.includes(project: todo.project.pathWithNamespace),
              rule.runner == .shell || available.contains(settings.automation.assistant)
        else { return nil }
        return .ready(rule.runner)
    }

    /// Returns true once the configured action has succeeded. Keep the receipt
    /// until GitLab confirms the todo is gone, so retrying a POST never reruns it.
    func prepareToAcknowledge(
        _ todo: Todo,
        event: TodoAutomationEvent,
        host: String,
        username: String,
        settings: SettingsManager,
        glab: GlabService,
        manual: Bool = false,
        isPending: @MainActor () -> Bool
    ) async throws -> Bool {
        let rule = settings.automation[event]
        let project = todo.project.pathWithNamespace
        guard (manual || rule.isEnabled), isPending(), rule.isConfigured, rule.includes(project: project),
              let iid = todo.target.iid, iid > 0,
              todo.targetURL.isGitLabMergeRequest(host: host, iid: iid)
        else { return false }

        let key = TodoAutomationReceipt(host: host, username: username, todoID: todo.id)
        let target = MRAutomationScope.Target(host: host, username: username, projectID: todo.project.id, iid: iid)
        guard manual || settings.automation.scope.resolve(target).active else { return false }
        let manualAcknowledgement = TodoActionAcknowledgement(host: host, username: username, todo: todo.feedbackIdentity)
        if settings.automationReceipts.contains(key) {
            if manual && rule.runner == .shell {
                settings.pendingTodoAcknowledgements.insert(manualAcknowledgement)
                settings.save()
            }
            return rule.runner == .shell && (manual || rule.markDoneOnSuccess)
        }
        guard !settings.automationAttemptReceipts.contains(key), !ineligible.contains(key) else { return false }

        let assistant = rule.runner == .assistant ? settings.automation.assistant : nil
        guard running.insert(key).inserted else { return false }
        defer { running.remove(key) }
        let workspace = assistant == nil ? "" : settings.automation.assistantWorkspace
        let invocation = Invocation(
            rule: rule, assistant: assistant, workspace: workspace,
            allowTools: settings.automation.permitsAssistantTools(project: project)
        )

        let author: Todo.Author
        if let targetAuthor = todo.target.author {
            author = targetAuthor
        } else {
            author = try await glab.mergeRequestAuthor(projectID: todo.project.id, iid: iid, host: host)
        }

        guard event.accepts(author: author, username: username) else {
            ineligible.insert(key)
            return false
        }
        guard isPending(),
              settings.automation[event] == rule,
              assistant == nil || (settings.automation.assistant == assistant
                  && settings.automation.assistantWorkspace == workspace
                  && settings.automation.permitsAssistantTools(project: project) == invocation.allowTools)
        else { return false }

        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: todo.project.id, iid: iid)
        guard assistant == nil || !AssistantAutomationRunner.isWorking(on: work) else { return false }
        let context = TodoAutomationContext(todo: todo, event: event, author: author, iid: iid)
        let acknowledgement = assistant != nil && (manual || rule.markDoneOnSuccess) ? todo.feedbackIdentity : nil
        var noteIDs = todo.linkedNoteID.map { [$0] } ?? []
        if assistant != nil, event == .authorFeedback, noteIDs.isEmpty,
           let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: work.projectID, iid: iid, host: host) {
            noteIDs = Array(GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: author.id)
                .filter { $0.author?.id == todo.author.id }.compactMap(\.id).prefix(12))
        }
        let evidence: String
        if assistant != nil, invocation.access == .preparation {
            evidence = await glab.mergeWorkflowEvidence(projectID: todo.project.id, iid: iid, host: host, noteIDs: noteIDs)
        } else {
            evidence = ""
        }
        let stackPosition = assistant == nil ? nil : await glab.stackPosition(for: work)
        guard isPending(), settings.automation[event] == rule,
              manual || settings.automation.scope.resolve(target).active,
              assistant == nil || (settings.automation.assistant == assistant
                  && settings.automation.assistantWorkspace == workspace
                  && settings.automation.permitsAssistantTools(project: project) == invocation.allowTools),
              assistant == nil || !AssistantAutomationRunner.isWorking(on: work)
        else { return false }
        if assistant == nil, !manual {
            let configuration = settings.automation
            guard await canAutomate(configuration.assistant), !Task.isCancelled,
                  settings.automation == configuration, isPending(),
                  settings.automation.scope.resolve(target).active else { return false }
        }
        // Mark a side effect as attempted only after evidence and account checks.
        settings.automationAttemptReceipts.insert(key)
        settings.save()
        if assistant == nil || event != .authorFeedback || noteIDs.isEmpty || !AssistantAutomationRunner.attachFeedbackTodo(
            acknowledgement, noteIDs: noteIDs, work: work, username: username, settings: settings
        ) {
            try await run(
                context, invocation: invocation, work: work, stackPosition: stackPosition, evidence: evidence,
                username: username, settings: settings, manual: manual,
                feedbackNoteIDs: event == .authorFeedback ? noteIDs : [], feedbackTodo: acknowledgement
            )
        }
        settings.automationReceipts.insert(key)
        if manual && assistant == nil { settings.pendingTodoAcknowledgements.insert(manualAcknowledgement) }
        settings.save()
        let currentRule = settings.automation[event]
        return assistant == nil && (manual || (currentRule.isEnabled && currentRule.markDoneOnSuccess))
    }

    func prepareFeedback(
        work: AssistantAutomationRunner.MergeRequestWork, noteIDs: [Int], username: String,
        settings: SettingsManager, glab: GlabService, manual: Bool = true, shouldProceed: @MainActor () -> Bool
    ) async throws {
        let configuration = settings.automation
        let rule = configuration.authorFeedback
        guard rule.runner == .assistant, rule.isConfigured, shouldProceed() else { return }
        let request = try await glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: work.host)
        let project = request.webURL.gitLabProjectPath
        guard request.state == "opened", request.author.username == username,
              request.webURL.isGitLabMergeRequest(host: work.host, iid: work.iid), rule.includes(project: project) else { return }
        let discussions = try await glab.fetchMergeRequestDiscussions(projectID: work.projectID, iid: work.iid, host: work.host)
        let remaining = Set(AssistantAutomationRunner.unhandledFeedback(noteIDs, work: work, username: username, settings: settings))
        let feedback = Array(GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: request.author.id)
            .filter { $0.id.map(remaining.contains) == true }.prefix(12))
        let ids = feedback.compactMap(\.id)
        guard !ids.isEmpty else { return }

        let invocation = Invocation(rule: rule, assistant: configuration.assistant, workspace: configuration.assistantWorkspace,
                                    allowTools: configuration.permitsAssistantTools(project: project))
        let evidence = invocation.access == .preparation ? await glab.mergeWorkflowEvidence(
            projectID: work.projectID, iid: work.iid, host: work.host, noteIDs: ids
        ) : ""
        let stackPosition = await glab.stackPosition(for: work)
        guard shouldProceed(), settings.automation == configuration,
              AssistantAutomationRunner.unhandledFeedback(ids, work: work, username: username, settings: settings) == ids.sorted()
        else { return }
        try await run(
            .init(request: request, feedback: feedback),
            invocation: invocation,
            work: work, stackPosition: stackPosition, evidence: evidence, username: username, settings: settings, manual: manual,
            feedbackNoteIDs: ids
        )
    }

    private func run(
        _ context: TodoAutomationContext,
        invocation: Invocation,
        work: AssistantAutomationRunner.MergeRequestWork,
        stackPosition: String?,
        evidence: String,
        username: String,
        settings: SettingsManager,
        manual: Bool,
        feedbackNoteIDs: [Int] = [],
        feedbackTodo: Todo.FeedbackIdentity? = nil
    ) async throws {
        let rule = invocation.rule
        let titleTemplate = rule.titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = context.render(titleTemplate.isEmpty ? "{repo} !{iid} ({author})" : titleTemplate,
                                   titleAuthor: context.author.assistantTitleName(viewerUsername: username))
        if let assistant = invocation.assistant {
            let scope = feedbackNoteIDs.isEmpty ? "" : "\n\nFocus on GitLab note IDs: \(feedbackNoteIDs.map(String.init).joined(separator: ", "))."
            let task = switch context.event {
            case .reviewRequested: "Task: Review or re-review this merge request."
            case .authorFeedback: "Task: Follow up on review feedback on my merge request."
            }
            let custom = rule.promptTemplate == AutomationSettings()[context.event].promptTemplate
                ? "" : "\n\nMy additional instructions: \(context.render(rule.promptTemplate))"
            let isolation = context.event == .authorFeedback
                ? "\n\n\(AssistantAutomationRunner.isolatedFixInstructions)" : ""
            let fallback = switch context.event {
            case .reviewRequested:
                "Check the current head, scope and diff. Verify actionable findings and check discussions and drafts for duplicates. For a re-review, recheck prior findings against the new head."
            case .authorFeedback:
                "Check the current head and only the indicated feedback, or unresolved feedback when no notes are specified. Verify it against the code. For warranted fixes follow the mandatory implement, test, commit, authorized push and remote-content verification sequence before saving any response drafts. If push is off, pending or failed, keep that run's result in chat only."
            }
            let suppliedEvidence = invocation.access == .gitLabRead ? "" : "\n\n<gitlab-evidence>\n" + evidence + "\n</gitlab-evidence>"
            let prompt = "\(task)\(scope)\(custom)\(isolation)\n\nFallback if needed: \(fallback)\(suppliedEvidence)"
            try await AssistantAutomationRunner.launch(
                assistant, title: title, stackPosition: stackPosition, mergeRequestURL: context.url,
                prompt: prompt,
                workspace: invocation.workspace,
                access: invocation.access,
                work: work, username: username, settings: settings,
                feedbackNoteIDs: feedbackNoteIDs, feedbackTodo: feedbackTodo,
                isReview: context.event == .reviewRequested,
                mrWorkflow: context.event == .authorFeedback ? .followUp : .review,
                manual: manual, jobCoordinator: jobCoordinator
            )
        } else {
            var environment = AssistantAutomationRunner.environment
            environment.merge(context.environment(taskTitle: title)) { _, value in value }
            let scriptEnvironment = environment
            let id = UUID()
            let task = Task {
                try await ProcessRunner.run(
                    URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", rule.command],
                    environment: scriptEnvironment, timeout: 300
                )
            }
            scriptTasks[id] = RunningScript(task: task, work: work, username: username, manual: manual)
            defer { scriptTasks[id] = nil }
            let output = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard output.exitCode == 0 else { throw ScriptError.nonZeroExit(output.exitCode) }
        }
    }

    private enum ScriptError: Error {
        case nonZeroExit(Int32)
    }
}
