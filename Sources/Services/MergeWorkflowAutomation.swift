import Foundation
import Observation

enum MergeWorkflowActivityState: String, Codable {
    case preview, notified, awaitingPipelineHandoff, alreadyRegistered, queued, running, waitingForAssistant, completed, failed, skipped
}

struct MergeWorkflowActivityEntry: Codable, Identifiable {
    let id: String
    let event: MergeWorkflowEvent
    let createdAt: Date
    fileprivate let host: String
    fileprivate let user: GitLabAuthenticatedUser
    var state: MergeWorkflowActivityState
    var summary: String?
    var chatURL: URL?
    var assistantJobID: UUID?
}

@MainActor
@Observable
final class MergeWorkflowAutomation {
    private var history: [MergeWorkflowActivityEntry]
    var entries: [MergeWorkflowActivityEntry] {
        history.filter { isCurrent(host: $0.host, user: $0.user) }
    }

    var pendingPipelineHandoffs: [MergeWorkflowActivityEntry] {
        entries.filter { $0.state == .awaitingPipelineHandoff && configuredRule(for: $0.event)?.mode == .assistant }
    }

    private let settings: SettingsManager
    private let glab: GlabService
    private let notifications: NotificationService
    private let detector: ExistingPipelineWorkDetector
    private let monitor = MergeWorkflowMonitor()
    private var work: Task<Void, Never>?
    private var polling = false

    init(
        settings: SettingsManager, glab: GlabService, notifications: NotificationService,
        detector: ExistingPipelineWorkDetector = ExistingPipelineWorkDetector()
    ) {
        self.settings = settings
        self.glab = glab
        self.notifications = notifications
        self.detector = detector
        history = settings.workflowActivity.map { stored in
            var entry = stored
            if entry.state == .queued || entry.state == .running { entry.state = .skipped }
            return entry
        }
        synchronizeAssistantJobs()
    }

    /// A CLI result completes workflow activity only when its linked run finished.
    /// Historical desktop deliveries have no execution evidence and remain history.
    func synchronizeAssistantJobs() {
        var changed = false
        for index in history.indices {
            if let updated = settings.workflowActivity.first(where: { $0.id == history[index].id }),
               updated.assistantJobID != history[index].assistantJobID {
                history[index].assistantJobID = updated.assistantJobID
                changed = true
            }
            guard let id = history[index].assistantJobID,
                  let job = settings.assistantHandoffs.first(where: { $0.id == id }),
                  let execution = job.execution else { continue }
            let state: MergeWorkflowActivityState = switch execution.state {
            case .queued: .waitingForAssistant
            case .running: .running
            case .succeeded: .completed
            case .blocked, .failed, .interrupted: .failed
            case .cancelled: .skipped
            }
            let summary = execution.summary ?? execution.error
            if history[index].state != state || history[index].summary != summary {
                history[index].state = state
                history[index].summary = summary
                changed = true
            }
        }
        if changed { saveHistory() }
    }

    func observe(_ authored: [GitLabMergeRequest], host: String, user: GitLabAuthenticatedUser) {
        guard !polling, isCurrent(host: host, user: user) else { return }
        let rules = settings.automation.workflowRules
        for entry in entries where entry.state == .awaitingPipelineHandoff || entry.state == .alreadyRegistered {
            let original = entry.event.mergeRequest
            let current = authored.first { $0.projectID == original.projectID && $0.iid == original.iid }
            if current == nil || current?.sha != original.sha
                || (current?.headPipeline.map { $0.id != entry.event.pipelineID || $0.status != "failed" } == true) {
                update(entry.id, .skipped)
            }
        }
        reconsiderRegisteredPipelines()
        let knownChats = Set(settings.assistantChats.keys.filter { $0.work.host == host && $0.username == user.username }.map(\.work))
        let knownHandoffs = Set(settings.assistantHandoffs.filter { $0.key.work.host == host && $0.key.username == user.username }.map(\.key.work))
        let trackedReviews = knownChats.union(knownHandoffs).filter {
            settings.automation.scope.resolve(.init(host: host, username: user.username, projectID: $0.projectID, iid: $0.iid)).active
        }
        polling = true
        Task {
            defer { polling = false }
            await monitor.poll(
                glab: glab, host: host, user: user, authored: authored,
                enabled: rules.enabled, reviewSLA: Double(max(1, rules[.reviewWaiting].waitHours)) * 3600, trackedReviews: trackedReviews
            ) { event in
                guard self.isCurrent(host: host, user: user) else { return }
                self.receive(event, host: host, user: user)
            }
            startNext()
        }
    }

    func confirmPipelineHandoff(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }),
              entry.state == .awaitingPipelineHandoff,
              let key = pipelineKey(entry),
              isCurrent(host: entry.host, user: entry.user),
              configuredRule(for: entry.event)?.mode == .assistant
        else { return }

        guard detector.status(for: key) == .unverified, !AssistantAutomationRunner.isWorking(on: workKey(entry)) else {
            update(id, .alreadyRegistered)
            return
        }
        update(id, .queued)
        startNext()
    }

    private func reconsiderRegisteredPipelines() {
        for entry in entries where entry.state == .alreadyRegistered {
            guard let key = pipelineKey(entry), detector.status(for: key) == .unverified,
                  !AssistantAutomationRunner.isWorking(on: workKey(entry)),
                  configuredRule(for: entry.event)?.mode == .assistant
            else { continue }

            update(entry.id, .awaitingPipelineHandoff)
        }
    }

    private func receive(_ event: MergeWorkflowEvent, host: String, user: GitLabAuthenticatedUser) {
        guard let rule = configuredRule(for: event),
              !entries.contains(where: { $0.id == event.identity })
        else { return }

        var entry = MergeWorkflowActivityEntry(
            id: event.identity, event: event, createdAt: Date(), host: host, user: user, state: .queued
        )
        switch rule.mode {
        case .off: return
        case .preview: entry.state = .preview
        case .notify: entry.state = .preview
        case .assistant:
            if event.kind == .pipelineFailure {
                if let key = pipelineKey(entry) {
                    entry.state = detector.status(for: key) == .registered || AssistantAutomationRunner.isWorking(on: workKey(entry))
                        ? .alreadyRegistered : .awaitingPipelineHandoff
                } else {
                    entry.state = .skipped
                }
            }
        }

        if entry.state == .queued, history.lazy.filter({ $0.state == .queued }).prefix(24).count == 24 {
            entry.state = .skipped
        }
        history.insert(entry, at: 0)
        if history.count > 120,
           let index = history.lastIndex(where: { $0.state != .queued && $0.state != .running }) {
            history.remove(at: index)
        }
        saveHistory()
    }

    private func startNext() {
        guard work == nil, let next = entries.last(where: { $0.state == .queued }) else { return }
        update(next.id, .running)
        work = Task {
            defer {
                work = nil
                startNext()
            }
            do {
                try await execute(next)
            } catch is CancellationError {
                update(next.id, .skipped)
            } catch {
                update(next.id, .failed)
                Log.monitor.error("Merge workflow execution failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func execute(_ entry: MergeWorkflowActivityEntry) async throws {
        let event = entry.event
        let original = event.mergeRequest
        guard shouldProceed(entry) else { throw CancellationError() }

        let authenticated = try await glab.fetchAuthenticatedUser(host: entry.host, expectedUsername: entry.user.username)
        guard authenticated == entry.user else { throw CancellationError() }
        let latest = try await glab.fetchMergeRequest(projectID: original.projectID, iid: original.iid, host: entry.host)
        guard latest.state == "opened", latest.sha == original.sha, latest.sha != nil,
              latest.webURL.isGitLabMergeRequest(host: entry.host, iid: latest.iid),
              configuredRule(for: event)?.includes(latest) == true, shouldProceed(entry)
        else { throw CancellationError() }

        var handoff: ExistingPipelineWorkDetector.Key?
        if event.kind == .pipelineFailure {
            guard let key = pipelineKey(entry), latest.author.id == entry.user.id,
                  !AssistantAutomationRunner.isWorking(on: workKey(entry)),
                  latest.headPipeline?.id == key.pipelineID, latest.headPipeline?.sha == latest.sha,
                  latest.headPipeline?.status == "failed"
            else { throw CancellationError() }

            guard let ownedReservation = try detector.registerRun(for: key) else {
                update(entry.id, .alreadyRegistered)
                return
            }
            handoff = ownedReservation
        }
        defer {
            if let handoff { try? detector.finishHandoff(for: handoff) }
        }

        if event.isInfrastructureFailure, let handoff, let jobID = event.jobID,
           let pipelineProjectID = event.pipelineProjectID,
           latest.headPipeline?.projectID == pipelineProjectID,
           mayRetryInfrastructure(for: event) {
            try await glab.retryVerifiedInfrastructureJob(
                jobID, pipelineID: handoff.pipelineID, projectID: pipelineProjectID, host: entry.host,
                shouldProceed: { self.shouldProceed(entry) && self.mayRetryInfrastructure(for: event) }
            )
            update(entry.id, .completed)
            return
        }

        let settingsBeforeLaunch = settings.automation
        let feedbackIDs = if event.kind == .newDiscussion && !event.noteIDs.isEmpty {
            try await uncoveredDiscussionIDs(entry)
        } else { [Int]() }
        if event.kind == .newDiscussion, !event.noteIDs.isEmpty, feedbackIDs.isEmpty {
            update(entry.id, .skipped)
            return
        }
        let readsInCodex = settingsBeforeLaunch.assistant == .codex
            && [.reviewUpdate, .newDiscussion].contains(event.kind)
        let evidence = readsInCodex ? "" : await glab.mergeWorkflowEvidence(
            projectID: latest.projectID, iid: latest.iid, host: entry.host,
            noteIDs: event.kind == .newDiscussion ? feedbackIDs : event.noteIDs, jobID: event.jobID
        )
        let stackPosition = await glab.stackPosition(for: workKey(entry))
        let current = try await glab.fetchMergeRequest(projectID: latest.projectID, iid: latest.iid, host: entry.host)
        guard current.state == "opened", current.sha == latest.sha,
              configuredRule(for: event)?.includes(current) == true,
              shouldProceed(entry), settings.automation == settingsBeforeLaunch
        else { throw CancellationError() }
        if !feedbackIDs.isEmpty, feedbackIDs != AssistantAutomationRunner.unhandledFeedback(
            feedbackIDs, work: workKey(entry), username: entry.user.username, settings: settings
        ) { throw CancellationError() }

        let repository = latest.webURL.gitLabProjectPath.split(separator: "/").last.map(String.init)
            ?? "project \(latest.projectID)"
        let eventContext = feedbackIDs.isEmpty ? event.context : "New unresolved review notes: \(feedbackIDs.map(String.init).joined(separator: ", "))."
        let context = """
            Task: \(event.kind.taskName).
            Expected head: \(latest.sha ?? "")
            Event: \(eventContext)

            Fallback if needed: \(event.kind.instructions)
            """
        let access: AssistantAutomationRunner.Access = if readsInCodex {
            .gitLabRead
        } else if settingsBeforeLaunch.permitsAssistantTools(project: latest.webURL.gitLabProjectPath) {
            .configuredTools
        } else { .preparation }
        // Planning events keep their narrower remote-action policy, but every CLI route can inspect live evidence with tools.
        let mrWorkflow: AssistantAutomationRunner.MRWorkflow? = switch event.kind {
        case .reviewUpdate: .review
        case .newDiscussion, .pipelineFailure: current.author.username == entry.user.username ? .followUp : nil
        case .reviewWaiting: .draftReply
        case .blockerChange, .stackDependencyMerged: nil
        }
        let isolation = mrWorkflow == .followUp ? "\n\n\(AssistantAutomationRunner.isolatedFixInstructions)" : ""
        let suppliedEvidence = readsInCodex ? "" : "\n\n<gitlab-evidence>\n" + evidence + "\n</gitlab-evidence>"
        let job = try await AssistantAutomationRunner.launch(
            settingsBeforeLaunch.assistant,
            title: "\(repository) !\(latest.iid) (\(latest.author.assistantTitleName(viewerUsername: entry.user.username)))",
            stackPosition: stackPosition,
            mergeRequestURL: latest.webURL,
            prompt: context + isolation + suppliedEvidence,
            workspace: settingsBeforeLaunch.assistantWorkspace,
            access: access,
            work: workKey(entry), username: entry.user.username, settings: settings, pipelineReservation: handoff,
            feedbackNoteIDs: feedbackIDs, isReview: event.kind == .reviewUpdate, mrWorkflow: mrWorkflow
        )
        // Transfer this owned reservation to the CLI run; terminal completion
        // releases it through the monitor callback rather than user dismissal.
        handoff = nil
        if let index = history.firstIndex(where: { $0.id == entry.id }) {
            history[index].assistantJobID = job.id
            history[index].state = .waitingForAssistant
            saveHistory()
        }
        synchronizeAssistantJobs()
    }

    private func configuredRule(for event: MergeWorkflowEvent) -> MergeWorkflowRule? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              settings.automation.scope.permits(event.mergeRequest, host: host, username: username) else { return nil }
        let rule = settings.automation.workflowRules[event.kind]
        return rule.mode != .off && rule.includes(event.mergeRequest) ? rule : nil
    }

    private func uncoveredDiscussionIDs(_ entry: MergeWorkflowActivityEntry) async throws -> [Int] {
        let work = workKey(entry)
        async let pending = glab.fetchTodos(host: work.host)
        let discussions = try await glab.fetchMergeRequestDiscussions(projectID: work.projectID, iid: work.iid, host: work.host)
        let todos = try await pending.get()
        let ids = Set(entry.event.noteIDs)
        let notes = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: entry.user.id)
            .filter { $0.id.map(ids.contains) == true }
        let uncovered = TodoAutomationEvent.feedbackWithoutTodo(
            notes, todos: todos, host: work.host, projectID: work.projectID, iid: work.iid, username: entry.user.username
        ).compactMap(\.id)
        return AssistantAutomationRunner.unhandledFeedback(uncovered, work: work, username: entry.user.username, settings: settings)
    }

    private func mayRetryInfrastructure(for event: MergeWorkflowEvent) -> Bool {
        guard let rule = configuredRule(for: event), rule.retryInfrastructureFailure else { return false }
        return MergeWorkflowRule.projectPaths(rule.projects).contains(event.mergeRequest.webURL.gitLabProjectPath)
    }

    private func workKey(_ entry: MergeWorkflowActivityEntry) -> AssistantAutomationRunner.MergeRequestWork {
        .init(host: entry.host, projectID: entry.event.mergeRequest.projectID, iid: entry.event.mergeRequest.iid)
    }

    private func pipelineKey(_ entry: MergeWorkflowActivityEntry) -> ExistingPipelineWorkDetector.Key? {
        guard let pipelineID = entry.event.pipelineID else { return nil }
        return .init(
            host: entry.host, projectID: entry.event.mergeRequest.projectID,
            mergeRequestIID: entry.event.mergeRequest.iid, pipelineID: pipelineID
        )
    }

    private func isCurrent(host: String, user: GitLabAuthenticatedUser) -> Bool {
        glab.resolvedHost == host && glab.currentUsername == user.username
    }

    private func shouldProceed(_ entry: MergeWorkflowActivityEntry) -> Bool {
        isCurrent(host: entry.host, user: entry.user) && configuredRule(for: entry.event)?.mode == .assistant
    }

    private func update(_ id: String, _ state: MergeWorkflowActivityState) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].state = state
            saveHistory()
        }
    }

    private func saveHistory() {
        settings.workflowActivity = history
        settings.save()
    }
}

private extension MergeWorkflowTrigger {
    var taskName: String {
        switch self {
        case .pipelineFailure: "CI failure"
        case .reviewUpdate: "re-review"
        case .newDiscussion: "review feedback"
        case .blockerChange: "merge blocker"
        case .stackDependencyMerged: "stack follow-up"
        case .reviewWaiting: "waiting for review"
        }
    }

    var instructions: String {
        switch self {
        case .pipelineFailure:
            "Diagnose the pipeline failure. Separate infrastructure failures from code failures. Prepare a scoped fix and a verification plan when the evidence supports one."
        case .reviewUpdate:
            "Re-review the changes since my previous review. Check which of my existing findings still apply to the new head. Prepare private reply drafts."
        case .newDiscussion:
            "Evaluate the new review threads on my MR. For warranted fixes, implement, verify, commit, push when authorized, and verify remote HEAD/content before saving response drafts. With push off, pending or failed, keep that run's result in chat."
        case .blockerChange:
            "Explain which GitLab merge blocker changed and what will unblock this MR."
        case .stackDependencyMerged:
            "The parent MR in this stack was merged. Identify the correct target and prepare a rebase or retarget plan, showing which diff should remain. Leave the remote target and branches for the user."
        case .reviewWaiting:
            "Summarize what the MR is waiting for. Prepare at most one short reminder as a draft."
        }
    }
}
