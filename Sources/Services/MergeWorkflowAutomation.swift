import Foundation
import Observation

enum MergeWorkflowActivityState: String, Codable {
    case preview, notified, awaitingPipelineHandoff, alreadyRegistered, queued, running, waitingForAssistant, completed, failed, skipped
}

struct MergeWorkflowActivityEntry: Codable, Identifiable {
    let id: String
    let event: MergeWorkflowEvent
    let createdAt: Date
    let host: String
    let user: GitLabAuthenticatedUser
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
    private var confirmedPipelineHandoffs: Set<String> = []
    @ObservationIgnored var onRemoteChange: (() -> Void)?

    func isAutomaticallyProcessingPipeline(_ request: GitLabMergeRequest) -> Bool {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return false }
        // A confirmed request can precede GitLab's next MR-detail response.
        // Keep that gap neutral even if a to-do route requested the pipeline.
        if settings.pipelineRefreshAttempts.contains(where: {
            $0.createdPipelineID != nil && $0.target.host == host && $0.target.username == username
                && $0.userID == request.author.id && $0.target.projectID == request.projectID && $0.target.iid == request.iid
                && $0.oldPipelineID == request.headPipeline?.id && $0.sourceSHA == request.sha
                && $0.sourceProjectID == request.sourceProjectID && $0.sourceBranch == request.sourceBranch
                && $0.targetProjectID == request.targetProjectID && $0.targetBranch == request.targetBranch
        }) { return true }
        return entries.contains { entry in
            guard entry.event.kind == .pipelineFailure, entry.event.mergeRequest.projectID == request.projectID,
                  entry.event.mergeRequest.iid == request.iid, entry.event.mergeRequest.sha == request.sha else { return false }
            switch entry.state {
            case .queued, .running, .waitingForAssistant: return true
            case .alreadyRegistered:
                guard let key = pipelineKey(entry) else { return false }
                return detector.hasActiveReservation(for: key) || AssistantAutomationRunner.isWorking(on: workKey(entry))
            default: return false
            }
        }
    }

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
            let entry = history[index]
            if entry.event.kind == .reviewWaiting, isCurrent(host: entry.host, user: entry.user),
               let id = entry.assistantJobID,
               let jobIndex = settings.assistantHandoffs.firstIndex(where: {
                   $0.id == id && $0.key.work == workKey(entry) && $0.key.username == entry.user.username
                       && ($0.workflow == .draftReply || $0.workflow == nil)
               }) {
                if settings.assistantHandoffs[jobIndex].workflow == nil {
                    settings.assistantHandoffs[jobIndex].workflow = .draftReply
                    changed = true
                }
                if let state = settings.assistantHandoffs[jobIndex].execution?.state,
                   state.isActive || state == .cancelled {
                    if state.isActive {
                        AssistantAutomationRunner.cancel(id, settings: settings)
                        if settings.assistantHandoffs[jobIndex].execution?.state.isActive == true {
                            settings.assistantHandoffs[jobIndex].execution?.state = .cancelled
                            settings.assistantHandoffs[jobIndex].execution?.finishedAt = Date()
                        }
                        changed = true
                    }
                    let localState: MergeWorkflowActivityState = settings.automation.workflowRules[.reviewWaiting].mode == .off ? .skipped : .preview
                    if history[index].state != localState { history[index].state = localState; changed = true }
                    continue
                }
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
        synchronizeAssistantJobs()
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
        reconsiderSkippedPipelines(authored, user: user)
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
        confirmedPipelineHandoffs.insert(id)
        update(id, .queued)
        startNext()
    }

    private func reconsiderRegisteredPipelines() {
        for entry in entries where entry.state == .alreadyRegistered || entry.state == .awaitingPipelineHandoff {
            guard let key = pipelineKey(entry),
                  configuredRule(for: entry.event)?.mode == .assistant
            else { continue }
            update(entry.id, pipelineDisposition(entry, key: key))
        }
    }

    /// Older gates could skip a pipeline before claiming or launching work.
    /// Reconsider that event only while every recorded effect is still absent;
    /// execution keeps the live account, source/target and atomic-claim checks.
    private func reconsiderSkippedPipelines(_ authored: [GitLabMergeRequest], user: GitLabAuthenticatedUser) {
        guard settings.automation.autoClaimPipelineFailures else { return }
        for entry in entries where entry.state == .skipped && entry.event.kind == .pipelineFailure {
            guard entry.user == user, entry.assistantJobID == nil, entry.chatURL == nil,
                  (entry.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let key = pipelineKey(entry), key.projectID > 0, key.mergeRequestIID > 0, key.pipelineID > 0,
                  let current = authored.first(where: { $0.projectID == key.projectID && $0.iid == key.mergeRequestIID }),
                  current.state == "opened", current.author.id == user.id,
                  let source = current.sha, GlabService.isFullGitSHA(source), source == entry.event.mergeRequest.sha,
                  current.headPipeline?.id == key.pipelineID, current.headPipeline?.status == "failed",
                  current.webURL.isGitLabMergeRequest(host: entry.host, iid: current.iid),
                  let rule = configuredRule(for: entry.event), rule.mode == .assistant, rule.includes(current),
                  detector.status(for: key) == .unverified,
                  !AssistantAutomationRunner.isWorking(on: workKey(entry))
            else { continue }
            let recordedWorker = settings.assistantHandoffs.contains { job in
                job.key.work == workKey(entry) && job.key.username == entry.user.username
                    && job.pipelineReservation?.host == key.host && job.pipelineReservation?.projectID == key.projectID
                    && job.pipelineReservation?.mergeRequestIID == key.mergeRequestIID
                    && job.pipelineReservation?.pipelineID == key.pipelineID
            }
            let routedWorker = settings.mrActionIntents.contains { intent in
                intent.kind == .pipeline && intent.jobID != nil && intent.target.host == entry.host
                    && intent.target.username == entry.user.username && intent.target.projectID == key.projectID
                    && intent.target.iid == key.mergeRequestIID && intent.request.headPipeline?.id == key.pipelineID
            }
            let refreshAttempt = settings.pipelineRefreshAttempts.contains {
                $0.target.host == entry.host && $0.target.username == entry.user.username && $0.userID == user.id
                    && $0.target.projectID == key.projectID && $0.target.iid == key.mergeRequestIID
                    && $0.oldPipelineID == key.pipelineID
            }
            guard !recordedWorker, !routedWorker, !refreshAttempt,
                  history.lazy.filter({ $0.state == .queued }).prefix(24).count < 24 else { continue }
            update(entry.id, .queued)
        }
    }

    func receive(_ event: MergeWorkflowEvent, host: String, user: GitLabAuthenticatedUser) {
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
                    entry.state = pipelineDisposition(entry, key: key)
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

    func startNext() {
        guard work == nil else { return }
        while let next = entries.last(where: { $0.state == .queued }) {
            let mode = configuredRule(for: next.event)?.mode
            guard next.event.kind != .reviewWaiting, mode == .assistant else {
                update(next.id, mode == .notify || mode == .preview ? .preview : .skipped)
                continue
            }
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
                } catch PipelineRefreshError.ownershipReserved {
                    update(next.id, .alreadyRegistered)
                } catch {
                    update(next.id, .failed)
                    if let error = error as? PipelineRefreshError,
                       let index = history.firstIndex(where: { $0.id == next.id }) {
                        history[index].summary = error.errorDescription
                        saveHistory()
                    }
                    Log.monitor.error("Merge workflow execution failed: \(String(describing: error), privacy: .private)")
                }
            }
            return
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
                  latest.headPipeline?.id == key.pipelineID,
                  latest.headPipeline?.status == "failed"
            else { throw CancellationError() }
            if settings.automation.autoClaimPipelineFailures {
                if try await glab.refreshStaleFailedPipeline(for: latest, host: entry.host, expectedUser: entry.user,
                    settings: settings, detector: detector, shouldProceed: { self.shouldProceed(entry) }) {
                    update(entry.id, .completed)
                    onRemoteChange?()
                    return
                }
            } else {
                _ = try await glab.verifiedFailedPipeline(for: latest, host: entry.host, expectedUser: entry.user)
            }
            guard shouldProceed(entry) else { throw CancellationError() }

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
        if event.kind == .pipelineFailure {
            guard current.headPipeline?.id == event.pipelineID else { throw CancellationError() }
            _ = try await glab.verifiedFailedPipeline(for: current, host: entry.host, expectedUser: entry.user)
            guard shouldProceed(entry), settings.automation == settingsBeforeLaunch else { throw CancellationError() }
        }
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
        case .reviewWaiting: nil
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
        var rule = settings.automation.workflowRules[event.kind]
        rule.mode = rule.effectiveMode(for: event.kind)
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

    private func pipelineDisposition(
        _ entry: MergeWorkflowActivityEntry, key: ExistingPipelineWorkDetector.Key
    ) -> MergeWorkflowActivityState {
        if detector.hasActiveReservation(for: key) || AssistantAutomationRunner.isWorking(on: workKey(entry)) {
            return .alreadyRegistered
        }
        if settings.automation.autoClaimPipelineFailures { return .queued }
        return detector.status(for: key) == .registered ? .alreadyRegistered : .awaitingPipelineHandoff
    }

    private func isCurrent(host: String, user: GitLabAuthenticatedUser) -> Bool {
        glab.resolvedHost == host && glab.currentUsername == user.username
    }

    private func shouldProceed(_ entry: MergeWorkflowActivityEntry) -> Bool {
        entry.event.kind != .reviewWaiting && isCurrent(host: entry.host, user: entry.user)
            && configuredRule(for: entry.event)?.mode == .assistant
            && (entry.event.kind != .pipelineFailure || settings.automation.autoClaimPipelineFailures
                || confirmedPipelineHandoffs.contains(entry.id))
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
            "Diagnose the pipeline failure and separate infrastructure failures from code failures. Implement and verify warranted in-scope fixes. When follow-up push is enabled, commit and push tested corrections, then re-fetch the remote HEAD and verify source content before saving completion drafts. With push off, pending or failed, keep the result in chat."
        case .reviewUpdate:
            "Re-review the changes since my previous review. Check which of my existing findings still apply to the new head. Prepare private reply drafts."
        case .newDiscussion:
            "Evaluate the new review threads on my MR. For warranted fixes, implement, verify, commit, push when authorized, and verify remote HEAD/content before saving response drafts. With push off, pending or failed, keep that run's result in chat."
        case .blockerChange:
            "Explain which GitLab merge blocker changed and what will unblock this MR."
        case .stackDependencyMerged:
            "The parent MR in this stack was merged. Identify the correct target and prepare a rebase or retarget plan, showing which diff should remain. Leave the remote target and branches for the user."
        case .reviewWaiting:
            "Track review waiting locally. Do not create reminders or other GitLab comments."
        }
    }
}
