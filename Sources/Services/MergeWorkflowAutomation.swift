import Foundation
import Observation

enum MergeWorkflowActivityState: String, Codable {
    case preview, notified, awaitingPipelineHandoff, alreadyRegistered, queued, running, waitingForAssistant, completed, failed, skipped
}

struct PipelineClaimAssessmentLineage: Codable, Equatable, Sendable {
    let skippedActivityID: String
    let skippedCreatedAt: Date
}

struct PipelineClaimAssessmentAttempt: Codable, Sendable {
    let target: MRAutomationScope.Target
    let userID: Int
    let lineage: PipelineClaimAssessmentLineage
    let assessmentActivityID: String
    let sourceProjectID: Int
    let sourceBranch: String
    let sourceSHA: String
    let targetProjectID: Int
    let targetBranch: String
    let targetSHA: String
    let pipelineProjectID: Int
    let pipelineID: Int
    let pipelineSHA: String
    let createdAt: Date
}

struct MergeWorkflowReadFailure: Codable, Sendable {
    let date: Date
    let configuration: AutomationSettings
}

enum PipelineClaimAssessmentError: LocalizedError {
    case ownershipReserved, persistenceUnavailable
    var errorDescription: String? {
        switch self {
        case .ownershipReserved: String(localized: .PipelineAutomation.pipelineRefreshOwnershipReserved)
        case .persistenceUnavailable: String(localized: .PipelineAutomation.pipelineClaimAssessmentPersistenceUnavailable)
        }
    }
}

struct MergeWorkflowActivityEntry: Codable, Identifiable {
    let id: String
    var event: MergeWorkflowEvent
    let createdAt: Date
    let host: String
    let user: GitLabAuthenticatedUser
    var state: MergeWorkflowActivityState
    var summary: String?
    var chatURL: URL?
    var assistantJobID: UUID?
    var pipelineClaimAssessment: PipelineClaimAssessmentLineage? = nil
    var readOnlyFailure: MergeWorkflowReadFailure? = nil
    var isReadOnlyFailure: Bool { readOnlyFailure != nil }
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
    private let jobCoordinator: AssistantJobCoordinator?
    private let monitor = MergeWorkflowMonitor()
    private let retryWait: ReadOnlyAssessmentRetry.Wait
    private let now: ReadOnlyAssessmentRetry.Clock
    private var work: Task<Void, Never>?
    private var polling = false
    private var confirmedPipelineHandoffs: Set<String> = []
    @ObservationIgnored var onRemoteChange: (() -> Void)?

    func hasReadOnlyFailure(for request: GitLabMergeRequest) -> Bool {
        let current = entries.filter {
            $0.event.mergeRequest.projectID == request.projectID && $0.event.mergeRequest.iid == request.iid
                && $0.event.mergeRequest.sha == request.sha
                && ($0.event.kind != .pipelineFailure || $0.event.pipelineID == request.headPipeline?.id)
        }
        // A newer result for the same trigger supersedes its older admission failure.
        return MergeWorkflowTrigger.allCases.contains { trigger in
            guard let entry = current.first(where: { $0.event.kind == trigger }), entry.state == .failed,
                  let failure = entry.readOnlyFailure, shouldProceed(entry),
                  failure.configuration.preservingScope(from: settings.automation) == settings.automation else { return false }
            return true
        }
    }

    func retryReadOnlyFailures() {
        for index in history.indices where history[index].state == .failed && history[index].isReadOnlyFailure
            && isCurrent(host: history[index].host, user: history[index].user) {
            if let failure = history[index].readOnlyFailure {
                history[index].readOnlyFailure = .init(date: .distantPast, configuration: failure.configuration)
            }
        }
        saveHistory()
        startNext()
    }

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
        detector: ExistingPipelineWorkDetector = ExistingPipelineWorkDetector(), jobCoordinator: AssistantJobCoordinator? = nil,
        retryWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
        now: @escaping ReadOnlyAssessmentRetry.Clock = { Date() }
    ) {
        self.settings = settings
        self.glab = glab
        self.notifications = notifications
        self.detector = detector
        self.jobCoordinator = jobCoordinator
        self.retryWait = retryWait
        self.now = now
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
        let observationScope = settings.automation.scope
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
                enabled: rules.enabled, reviewSLA: Double(max(1, rules[.reviewWaiting].waitHours)) * 3600, trackedReviews: trackedReviews,
                automationScope: observationScope,
                isCurrent: { self.isCurrent(host: host, user: user) && self.settings.automation.scope == observationScope }
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
        guard settings.automation.autoClaimPipelineFailures, settings.automation.packageDecision != .disabled else { return }
        for entry in entries where entry.state == .skipped && entry.event.kind == .pipelineFailure && entry.pipelineClaimAssessment == nil {
            guard entry.user == user, entry.assistantJobID == nil, entry.chatURL == nil,
                  (entry.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let key = pipelineKey(entry), key.projectID > 0, key.mergeRequestIID > 0, key.pipelineID > 0,
                  let current = authored.first(where: { $0.projectID == key.projectID && $0.iid == key.mergeRequestIID }),
                  current.state == "opened", current.author.id == user.id,
                  settings.automation.scope.permits(current, host: entry.host, username: entry.user.username),
                  let source = current.sha, GlabService.isFullGitSHA(source), source == entry.event.mergeRequest.sha,
                  current.headPipeline?.id == key.pipelineID, current.headPipeline?.status == "failed",
                  current.webURL.isGitLabMergeRequest(host: entry.host, iid: current.iid)
            else { continue }
            let event = MergeWorkflowEvent(kind: entry.event.kind, mergeRequest: current,
                identity: entry.event.identity, context: entry.event.context,
                pipelineProjectID: entry.event.pipelineProjectID, pipelineID: entry.event.pipelineID,
                jobID: entry.event.jobID, isInfrastructureFailure: entry.event.isInfrastructureFailure,
                noteIDs: entry.event.noteIDs)
            guard let rule = configuredRule(for: event), rule.mode == .assistant, rule.includes(current),
                  !settings.ignoredMergeRequests.contains(.init(host: entry.host, username: entry.user.username,
                                                                projectID: key.projectID, iid: key.mergeRequestIID)),
                  !AssistantAutomationRunner.isWorking(on: workKey(entry))
            else { continue }
            guard !hasRecordedPipelineEffects(entry, key: key),
                  history.lazy.filter({ $0.state == .queued }).prefix(24).count < 24 else { continue }
            if detector.status(for: key) == .unverified {
                if let index = history.firstIndex(where: { $0.id == entry.id }) { history[index].event = event }
                update(entry.id, .queued)
            } else if !detector.hasActiveReservation(for: key), detector.hasEmptyPipelineReceipt(for: key),
                      !history.contains(where: { $0.pipelineClaimAssessment?.skippedActivityID == entry.id }) {
                let id = entry.id + "|claim-assessment|" + UUID().uuidString.lowercased()
                let event = MergeWorkflowEvent(kind: .pipelineFailure, mergeRequest: current, identity: id,
                    context: String(localized: .PipelineAutomation.pipelineClaimAssessmentContext),
                    pipelineProjectID: current.headPipeline?.projectID, pipelineID: key.pipelineID)
                var assessment = MergeWorkflowActivityEntry(id: id, event: event, createdAt: Date(), host: entry.host,
                                                           user: entry.user, state: .queued)
                assessment.pipelineClaimAssessment = .init(skippedActivityID: entry.id, skippedCreatedAt: entry.createdAt)
                history.insert(assessment, at: 0)
                pruneHistory()
                saveHistory()
            }
        }
    }

    private func hasRecordedPipelineEffects(_ entry: MergeWorkflowActivityEntry, key: ExistingPipelineWorkDetector.Key) -> Bool {
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
                $0.target.host == entry.host && $0.target.username == entry.user.username && $0.userID == entry.user.id
                    && $0.target.projectID == key.projectID && $0.target.iid == key.mergeRequestIID
                    && $0.oldPipelineID == key.pipelineID
        }
        let assessmentAttempt = settings.pipelineClaimAssessmentAttempts.contains {
            $0.target.host == entry.host && $0.target.username == entry.user.username && $0.userID == entry.user.id
                && $0.target.projectID == key.projectID && $0.target.iid == key.mergeRequestIID && $0.pipelineID == key.pipelineID
        }
        return recordedWorker || routedWorker || refreshAttempt || assessmentAttempt
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
        pruneHistory()
        saveHistory()
    }

    func startNext() {
        guard work == nil else { return }
        for entry in entries where entry.state == .failed && entry.isReadOnlyFailure
            && entry.assistantJobID == nil && entry.chatURL == nil && shouldProceed(entry)
            && !AssistantAutomationRunner.isWorking(on: workKey(entry)) {
            guard let failure = entry.readOnlyFailure,
                  failure.configuration.preservingScope(from: settings.automation) != settings.automation
                    || now().timeIntervalSince(failure.date) >= ReadOnlyAssessmentRetry.cooldown else { continue }
            update(entry.id, .queued)
        }
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
                } catch PipelineClaimAssessmentError.ownershipReserved {
                    update(next.id, .alreadyRegistered)
                } catch let failure as InitialReadFailure {
                    if let index = history.firstIndex(where: { $0.id == next.id }) {
                        history[index].state = .failed
                        history[index].readOnlyFailure = .init(date: now(), configuration: failure.configuration)
                        history[index].summary = String(GlabService.redactWorkflowEvidence(String(describing: failure.cause)).prefix(600))
                        saveHistory()
                    }
                } catch {
                    update(next.id, .failed)
                    let summary = (error as? PipelineRefreshError)?.errorDescription
                        ?? (error as? PipelineClaimAssessmentError)?.errorDescription
                    if let summary,
                       let index = history.firstIndex(where: { $0.id == next.id }) {
                        history[index].summary = summary
                        saveHistory()
                    }
                    Log.monitor.error("Merge workflow execution failed: \(String(describing: error), privacy: .private)")
                }
            }
            return
        }
    }

    private struct InitialReadFailure: Error {
        let cause: any Error
        let configuration: AutomationSettings
    }

    private func execute(_ entry: MergeWorkflowActivityEntry) async throws {
        let event = entry.event
        let original = event.mergeRequest
        let assessmentConfiguration = settings.automation
        let assessmentAccountRevision = glab.accountRevision
        var assessmentTargetSHA: String?
        guard shouldProceed(entry) else { throw CancellationError() }

        let latest: GitLabMergeRequest
        do {
            latest = try await ReadOnlyAssessmentRetry.run(isCurrent: {
                self.shouldProceed(entry) && self.glab.accountRevision == assessmentAccountRevision
                    && assessmentConfiguration.preservingScope(from: self.settings.automation) == self.settings.automation
            }, wait: retryWait) {
                let authenticated = try await self.glab.fetchAuthenticatedUser(host: entry.host, expectedUsername: entry.user.username)
                guard authenticated == entry.user else { throw CancellationError() }
                let current = try await self.glab.fetchMergeRequest(projectID: original.projectID, iid: original.iid, host: entry.host)
                guard current.state == "opened", current.sha == original.sha, current.sha != nil,
                      current.webURL.isGitLabMergeRequest(host: entry.host, iid: current.iid),
                      self.settings.automation.scope.permits(current, host: entry.host, username: entry.user.username),
                      self.configuredRule(for: event)?.includes(current) == true, self.shouldProceed(entry)
                else { throw CancellationError() }
                return current
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw InitialReadFailure(cause: error, configuration: assessmentConfiguration) }
        if let index = history.firstIndex(where: { $0.id == entry.id }), history[index].readOnlyFailure != nil {
            history[index].readOnlyFailure = nil
            history[index].summary = nil
            saveHistory()
        }
        // Pipeline refresh, reservations, job retries and worker launch remain outside the read retry boundary.

        var handoff: ExistingPipelineWorkDetector.Key?
        if event.kind == .pipelineFailure {
            guard let key = pipelineKey(entry), latest.author.id == entry.user.id,
                  !AssistantAutomationRunner.isWorking(on: workKey(entry)),
                  latest.headPipeline?.id == key.pipelineID,
                  latest.headPipeline?.status == "failed"
            else { throw CancellationError() }
            if entry.pipelineClaimAssessment != nil {
                guard mayAssessClaim(entry, current: latest, configuration: assessmentConfiguration) else { throw CancellationError() }
                _ = try await glab.verifiedFailedPipeline(for: latest, host: entry.host, expectedUser: entry.user)
                guard let targetProject = latest.targetProjectID else { throw CancellationError() }
                assessmentTargetSHA = try await glab.fetchBranchHeadSHA(projectID: targetProject, branch: latest.targetBranch, host: entry.host)
                guard mayAssessClaim(entry, current: latest, configuration: assessmentConfiguration),
                      glab.accountRevision == assessmentAccountRevision else { throw CancellationError() }
            } else if settings.automation.autoClaimPipelineFailures {
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

            guard let ownedReservation = try detector.registerRun(for: key, explicitRetry: entry.pipelineClaimAssessment != nil) else {
                update(entry.id, .alreadyRegistered)
                return
            }
            handoff = ownedReservation
        }
        defer {
            if let handoff { try? detector.finishHandoff(for: handoff) }
        }

        if entry.pipelineClaimAssessment == nil, event.isInfrastructureFailure, let handoff, let jobID = event.jobID,
           let pipelineProjectID = event.pipelineProjectID,
           latest.headPipeline?.projectID == pipelineProjectID,
           mayRetryInfrastructure(for: event) {
            try await glab.retryVerifiedInfrastructureJob(
                jobID, pipelineID: handoff.pipelineID, projectID: pipelineProjectID, host: entry.host,
                beforeRetry: {
                    let current = try await self.glab.fetchMergeRequest(projectID: latest.projectID, iid: latest.iid, host: entry.host)
                    guard current.state == "opened", current.author.id == entry.user.id,
                          current.webURL == latest.webURL, current.sha == latest.sha,
                          current.sourceProjectID == latest.sourceProjectID, current.sourceBranch == latest.sourceBranch,
                          current.targetProjectID == latest.targetProjectID, current.targetBranch == latest.targetBranch,
                          current.headPipeline?.id == latest.headPipeline?.id,
                          current.headPipeline?.projectID == latest.headPipeline?.projectID,
                          current.headPipeline?.sha == latest.headPipeline?.sha, current.headPipeline?.status == "failed",
                          self.glab.accountRevision == assessmentAccountRevision,
                          self.settings.automation.scope.permits(current, host: entry.host, username: entry.user.username),
                          self.configuredRule(for: event)?.includes(current) == true else { throw CancellationError() }
                },
                shouldProceed: { self.shouldProceed(entry) && self.mayRetryInfrastructure(for: event) }
            )
            update(entry.id, .completed)
            return
        }

        let settingsBeforeLaunch = entry.pipelineClaimAssessment == nil ? settings.automation : assessmentConfiguration
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
              settings.automation.scope.permits(current, host: entry.host, username: entry.user.username),
              configuredRule(for: event)?.includes(current) == true,
              shouldProceed(entry), settingsBeforeLaunch.preservingScope(from: settings.automation) == settings.automation
        else { throw CancellationError() }
        if event.kind == .pipelineFailure {
            guard current.headPipeline?.id == event.pipelineID else { throw CancellationError() }
            _ = try await glab.verifiedFailedPipeline(for: current, host: entry.host, expectedUser: entry.user)
            guard shouldProceed(entry), settingsBeforeLaunch.preservingScope(from: settings.automation) == settings.automation else { throw CancellationError() }
        }
        if !feedbackIDs.isEmpty, feedbackIDs != AssistantAutomationRunner.unhandledFeedback(
            feedbackIDs, work: workKey(entry), username: entry.user.username, settings: settings
        ) { throw CancellationError() }

        let repository = latest.webURL.gitLabProjectPath.split(separator: "/").last.map(String.init)
            ?? "project \(latest.projectID)"
        let eventContext = feedbackIDs.isEmpty ? event.context : "New unresolved review notes: \(feedbackIDs.map(String.init).joined(separator: ", "))."
        var assessmentInstructions = ""
        if let lineage = entry.pipelineClaimAssessment {
            guard let reservation = handoff, let targetSHA = assessmentTargetSHA,
                  let sourceProject = current.sourceProjectID, let source = current.sha,
                  let targetProject = current.targetProjectID, let pipeline = current.headPipeline,
                  let pipelineProject = pipeline.projectID, let pipelineID = pipeline.id, let pipelineSHA = pipeline.sha,
                  current.sourceProjectID == latest.sourceProjectID, current.sourceBranch == latest.sourceBranch,
                  current.targetProjectID == latest.targetProjectID, current.targetBranch == latest.targetBranch,
                  current.headPipeline?.sha == latest.headPipeline?.sha,
                  mayAssessClaim(entry, current: current, configuration: assessmentConfiguration, reservation: reservation)
            else { throw CancellationError() }
            let finalTarget = try await glab.fetchBranchHeadSHA(projectID: targetProject, branch: current.targetBranch, host: entry.host)
            let finalUser = try await glab.fetchAuthenticatedUser(host: entry.host, expectedUsername: entry.user.username)
            guard finalTarget == targetSHA, finalUser == entry.user, glab.accountRevision == assessmentAccountRevision,
                  mayAssessClaim(entry, current: current, configuration: assessmentConfiguration, reservation: reservation)
            else { throw CancellationError() }
            let attempt = PipelineClaimAssessmentAttempt(
                target: .init(host: entry.host, username: entry.user.username, projectID: current.projectID, iid: current.iid),
                userID: entry.user.id, lineage: lineage, assessmentActivityID: entry.id,
                sourceProjectID: sourceProject, sourceBranch: current.sourceBranch, sourceSHA: source,
                targetProjectID: targetProject, targetBranch: current.targetBranch, targetSHA: targetSHA,
                pipelineProjectID: pipelineProject, pipelineID: pipelineID, pipelineSHA: pipelineSHA, createdAt: Date())
            guard settings.savePipelineClaimAssessmentAttempt(attempt) else { throw PipelineClaimAssessmentError.persistenceUnavailable }
            guard shouldProceed(entry), assessmentConfiguration.preservingScope(from: settings.automation) == settings.automation,
                  !settings.ignoredMergeRequests.contains(attempt.target), detector.ownsReservation(for: reservation),
                  glab.accountRevision == assessmentAccountRevision else { throw CancellationError() }
            assessmentInstructions = """
                This is a NEW current-state assessment, not a retry of an earlier worker. An old local pipeline claim has no recorded worker.
                Do not replay any prior task, command, push, job retry, draft operation or claimed result.
                First reconcile live GitLab account, MR/source head \(source), target \(current.targetBranch) at \(targetSHA),
                pipeline \(pipelineID), current jobs and retry history, recent commits, discussions and existing drafts before any writes.
                The old receipt alone does not require a user decision: the configured permissions authorize a fresh diagnosis of the CURRENT state.
                Identify work already delivered or underway and avoid duplicate fixes, retries and replies. If ownership, delivery or the current
                source/target/account cannot be safely reconciled, report the specific blocker and do not repeat an uncertain operation.
                Only after independently verifying a warranted correction may you implement it under the current follow-up push and proof rules.

                """
        }
        let context = assessmentInstructions + """
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
            feedbackNoteIDs: feedbackIDs, isReview: event.kind == .reviewUpdate, mrWorkflow: mrWorkflow,
            expectedHeadSHA: entry.pipelineClaimAssessment == nil ? nil : current.sha, jobCoordinator: jobCoordinator,
            configurationSnapshot: entry.pipelineClaimAssessment == nil ? nil : assessmentConfiguration
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

    private func mayAssessClaim(
        _ entry: MergeWorkflowActivityEntry, current: GitLabMergeRequest, configuration: AutomationSettings,
        reservation: ExistingPipelineWorkDetector.Key? = nil
    ) -> Bool {
        guard let lineage = entry.pipelineClaimAssessment, let key = pipelineKey(entry),
              let skipped = history.first(where: { $0.id == lineage.skippedActivityID }),
              skipped.createdAt == lineage.skippedCreatedAt, skipped.state == .skipped, skipped.pipelineClaimAssessment == nil,
              skipped.host == entry.host, skipped.user == entry.user, skipped.assistantJobID == nil, skipped.chatURL == nil,
              (skipped.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              skipped.event.pipelineID == key.pipelineID, skipped.event.mergeRequest.projectID == current.projectID,
              skipped.event.mergeRequest.iid == current.iid, skipped.event.mergeRequest.sha == current.sha,
              current.state == "opened", current.author.id == entry.user.id,
              settings.automation.scope.permits(current, host: entry.host, username: entry.user.username),
              current.headPipeline?.id == key.pipelineID, current.headPipeline?.status == "failed",
              configuration.preservingScope(from: settings.automation) == settings.automation,
              settings.automation.autoClaimPipelineFailures, settings.automation.packageDecision != .disabled,
              shouldProceed(entry), configuredRule(for: entry.event)?.includes(current) == true,
              !settings.ignoredMergeRequests.contains(.init(host: entry.host, username: entry.user.username,
                                                          projectID: current.projectID, iid: current.iid)),
              !hasRecordedPipelineEffects(skipped, key: key), !AssistantAutomationRunner.isWorking(on: workKey(entry)),
              detector.hasEmptyPipelineReceipt(for: key) else { return false }
        if let reservation { return detector.ownsReservation(for: reservation) }
        return !detector.hasActiveReservation(for: key)
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

    private func pruneHistory() {
        let protected = Set(history.flatMap { entry -> [String] in
            guard [.queued, .running, .waitingForAssistant].contains(entry.state),
                  let lineage = entry.pipelineClaimAssessment else { return [] }
            return [entry.id, lineage.skippedActivityID]
        })
        if history.count > 120,
           let index = history.lastIndex(where: { $0.state != .queued && $0.state != .running && !protected.contains($0.id) }) {
            history.remove(at: index)
        }
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
