import Foundation

extension TodoMonitorService {
    typealias AutomaticRetryLaunch = @MainActor (AssistantAutomationRunner.Handoff, AssistantAutomaticRetryIdentity, String) async throws -> AssistantAutomationRunner.Handoff

    func wakeAutomaticRetries() {
        guard automaticRetryRuntimeStarted,
              ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application else { return }
        if let automaticRetryCoordinator { automaticRetryCoordinator.wake(); return }
        guard automaticRetryStartupTask == nil else { return }
        let startupID = UUID()
        automaticRetryStartupID = startupID
        automaticRetryStartupTask = Task { [weak self] in
            guard let self else { return }
            defer { if automaticRetryStartupID == startupID { automaticRetryStartupTask = nil } }
            guard await AssistantJobJournal.loadKey(), !Task.isCancelled, automaticRetryRuntimeStarted,
                  automaticRetryStartupID == startupID else { return }
            AssistantAutomationRunner.synchronizeInterruptedRuns(settings: settings)
            let coordinator = AssistantAutomaticRetryCoordinator(settings: settings,
                onAdopt: { [weak self] parentID, child in self?.adoptAutomaticRetry(parentID: parentID, replacement: child) },
                canRetry: { [weak self] in self?.canAutomaticallyRetry($0) == true },
                launch: { [weak self] job, identity in
                    guard let self else { return .deferred }
                    return try await self.launchAutomaticRetry(job, identity: identity)
                })
            automaticRetryCoordinator = coordinator
            coordinator.recoverUnfinishedAdmissions()
        }
    }

    func stopAutomaticRetries() {
        automaticRetryRuntimeStarted = false
        automaticRetryStartupID = nil
        automaticRetryStartupTask?.cancel()
        automaticRetryStartupTask = nil
        automaticRetryCoordinator?.cancel()
        automaticRetryCoordinator = nil
    }

    func canAutomaticallyRetry(_ job: AssistantAutomationRunner.Handoff, assistantReady: Bool? = nil, pipelineWorkDetector: ExistingPipelineWorkDetector = .init()) -> Bool {
        let configuration = settings.automation
        let target = MRAutomationScope.Target(host: job.key.work.host, username: job.key.username,
            projectID: job.key.work.projectID, iid: job.key.work.iid)
        guard settings.automaticWritesAllowed, configuration.hasAutomaticActionConsent,
              glab.resolvedHost == target.host, glab.currentUsername == target.username,
              !settings.ignoredMergeRequests.contains(target), configuration.scope.resolve(target).active,
              configuration.selectedAssistant != nil, assistantReady ?? availableAssistants.contains(configuration.assistant),
              cliHealth.hold(for: configuration.assistant) == nil,
              let current = settings.assistantHandoffs.first(where: { $0.id == job.id }),
              !settings.mrActionIntents.contains(where: { $0.reviewRecoveryJobID == job.id }),
              retryableExecution(current), current.draftRepair == nil,
              !(current.workflow == .followUp && !(current.feedbackNoteIDs ?? []).isEmpty),
              !settings.assistantHandoffs.contains(where: { $0.id != current.id && $0.key.work == current.key.work
                  && $0.key.username == current.key.username && $0.execution?.state.isActive == true }),
              !AssistantAutomationRunner.isWorking(on: current.key.work),
              let url = current.mergeRequestURL, url.isGitLabMergeRequest(host: target.host, iid: current.key.work.iid),
              current.taskPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              current.key.access != .configuredTools || configuration.permitsAssistantTools(project: url.gitLabProjectPath)
        else { return false }
        guard automaticRetryPermission(current, request: nil),
              !automaticRetryClaimHeld(current, detector: pipelineWorkDetector) else { return false }
        return true
    }

    func launchAutomaticRetry(_ job: AssistantAutomationRunner.Handoff, identity: AssistantAutomaticRetryIdentity,
                              assistantReady: Bool? = nil, pipelineWorkDetector: ExistingPipelineWorkDetector = .init(), retry: AutomaticRetryLaunch? = nil) async throws -> AssistantAutomaticRetryCoordinator.LaunchResult {
        guard !retryWasStopped(job.id) else { return .obsolete }
        guard canAutomaticallyRetry(job, assistantReady: assistantReady, pipelineWorkDetector: pipelineWorkDetector), !Task.isCancelled else { return .deferred }
        let revision = glab.accountRevision, configuration = settings.automation
        let user: GitLabAuthenticatedUser
        var request: GitLabMergeRequest
        do {
            async let freshUser = glab.fetchAuthenticatedUser(host: job.key.work.host, expectedUsername: job.key.username)
            async let freshRequest = glab.fetchMergeRequest(projectID: job.key.work.projectID,
                iid: job.key.work.iid, host: job.key.work.host)
            (user, request) = try await (freshUser, freshRequest)
            if job.taskIntent == .conflictResolution, !request.hasMergeConflict {
                request.mergeTrainConflict = try await glab.fetchMergeTrainPreparationConflict(request, host: job.key.work.host)
            }
        } catch is CancellationError {
            return retryWasStopped(job.id) ? .obsolete : .deferred
        }
        guard !retryWasStopped(job.id) else { return .obsolete }
        guard !Task.isCancelled, glab.accountRevision == revision, settings.automation == configuration,
              canAutomaticallyRetry(job, assistantReady: assistantReady, pipelineWorkDetector: pipelineWorkDetector), user.username == job.key.username else { return .deferred }
        guard request.projectID == job.key.work.projectID, request.iid == job.key.work.iid,
              request.webURL.isGitLabMergeRequest(host: job.key.work.host, iid: job.key.work.iid) else { return .deferred }
        if request.state == "closed" || request.state == "merged" { return .obsolete }
        guard request.state == "opened", let head = request.sha, GlabService.isFullGitSHA(head),
              let expected = job.expectedHeadSHA, GlabService.isFullGitSHA(expected) else { return .deferred }
        guard head == expected else { return .obsolete }
        if job.taskIntent == .conflictResolution, !request.hasMergeConflict { return .obsolete }
        if let priorID = job.pipelineReservation?.pipelineID ?? job.foreignPipelineDiagnosis?.pipelineID {
            guard let pipeline = request.headPipeline, let currentID = pipeline.id else { return .deferred }
            if currentID != priorID || pipeline.status == "success" { return .obsolete }
            guard pipeline.status == "failed" else { return .deferred }
        }
        guard configuration.scope.permits(request, host: job.key.work.host, username: job.key.username),
              automaticRetryPermission(job, request: request),
              !(job.workflow == .review || job.reviewModel != nil) || request.author.id != user.id,
              job.pipelineReservation == nil || request.author.id == user.id,
              job.followUpPushAllowed != true || request.author.id == user.id,
              job.taskIntent != .conflictResolution || request.author.id == user.id else { return .deferred }
        let existingJobIDs = Set(settings.assistantHandoffs.map(\.id))
        let replacement: AssistantAutomationRunner.Handoff
        do {
            if let retry { replacement = try await retry(job, identity, head) }
            else {
                replacement = try await AssistantAutomationRunner.retry(job.id, settings: settings, expectedHeadSHA: head,
                    glab: glab, manual: false, automaticRetryIdentity: identity)
            }
        } catch {
            let recordedChild = settings.assistantHandoffs.contains {
                $0.id != job.id && ($0.automaticRetryIdentity == identity
                    || $0.retryOf == job.id && !existingJobIDs.contains($0.id))
            }
            guard !recordedChild else { throw error }
            switch error {
            case AssistantAutomationRunner.HandoffError.pipelineState(_, _),
                 AssistantAutomationRunner.HandoffError.mergeRequestBusy,
                 AssistantAutomationRunner.HandoffError.executionUnavailable,
                 AssistantJobExecutor.ExecutionError.disabledPermission,
                 AssistantJobExecutor.ExecutionError.wrongAccount,
                 AssistantJobExecutor.ExecutionError.cliUnavailable,
                 AssistantJobExecutor.ExecutionError.contextUnavailable, is CancellationError:
                return retryWasStopped(job.id) ? .obsolete : .deferred
            case AssistantAutomationRunner.HandoffError.pipelinePassed(_),
                 AssistantAutomationRunner.HandoffError.pipelineSuperseded(_),
                 AssistantJobExecutor.ExecutionError.inactiveMergeRequest,
                 AssistantJobExecutor.ExecutionError.headChanged:
                return .obsolete
            default: throw error
            }
        }
        adoptAutomaticRetry(parentID: job.id, replacement: replacement)
        return .started(replacement)
    }

    func adoptAutomaticRetry(parentID: UUID, replacement: AssistantAutomationRunner.Handoff) {
        mrTodoRouter.rebindJob(oldID: parentID, replacement: replacement)
        var changed = false
        for index in settings.workflowActivity.indices {
            let entry = settings.workflowActivity[index]
            guard entry.assistantJobID == parentID,
                  entry.host == replacement.key.work.host, entry.user.username == replacement.key.username,
                  entry.event.mergeRequest.projectID == replacement.key.work.projectID,
                  entry.event.mergeRequest.iid == replacement.key.work.iid else { continue }
            settings.workflowActivity[index].assistantJobID = replacement.id
            settings.workflowActivity[index].state = .waitingForAssistant
            settings.workflowActivity[index].summary = nil
            changed = true
        }
        if changed { settings.save() }
        authoredMergeRequests.workflow.synchronizeAssistantJobs()
    }

    private func automaticRetryClaimHeld(_ job: AssistantAutomationRunner.Handoff, detector: ExistingPipelineWorkDetector) -> Bool {
        guard detector.hasActiveReservation(host: job.key.work.host, projectID: job.key.work.projectID,
            iid: job.key.work.iid) else { return false }
        let message = String(localized: .AssistantRetry.assistantRetryReservationHeld)
        if !settings.automationEvents.contains(where: {
            $0.action == .retry && $0.origin == .automatic && $0.state == .blocked && $0.jobID == job.id && $0.message == message
        }) {
            settings.recordAutomationEvent(target: .init(host: job.key.work.host, username: job.key.username,
                projectID: job.key.work.projectID, iid: job.key.work.iid), action: .retry, origin: .automatic,
                state: .blocked, message: message, jobID: job.id)
        }
        return true
    }

    private func retryWasStopped(_ id: UUID) -> Bool {
        guard let execution = settings.assistantHandoffs.first(where: { $0.id == id })?.execution else { return true }
        return execution.cancellationOrigin == .user || execution.state == .cancelled && execution.cancellationOrigin != .policy
    }

    private func retryableExecution(_ job: AssistantAutomationRunner.Handoff) -> Bool {
        guard !job.isObsoleteReminder, let execution = job.execution, execution.cancellationOrigin != .user else { return false }
        return execution.state == .failed || execution.state == .interrupted
            || execution.state == .cancelled && execution.cancellationOrigin == .policy
    }

    private func automaticRetryPermission(_ job: AssistantAutomationRunner.Handoff, request: GitLabMergeRequest?) -> Bool {
        AssistantAutomationRunner.automaticRetryPermission(for: job, configuration: settings.automation,
            request: request, origin: AssistantAutomationRunner.originatingWorkflowEvent(for: job, settings: settings))
    }

}
