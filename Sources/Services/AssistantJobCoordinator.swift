import Foundation
import Observation

/// Owns live tasks only. Persisted queued/running records are never replayed after restart.
@MainActor
final class AssistantJobCoordinator {
    typealias Handoff = AssistantAutomationRunner.Handoff
    struct Outcome: Sendable {
        let result: AssistantJobResult
        let output: String
        var reviewDiscussionSummary: String? = nil

        var summary: String {
            guard let reviewDiscussionSummary else { return result.summary }
            return reviewDiscussionSummary + "\n\n" + result.summary
        }
    }
    typealias Executor = @MainActor (Handoff, SettingsManager) async throws -> Outcome
    typealias SuccessCleanup = @MainActor (Handoff, SettingsManager) async -> Void
    typealias CapacityProbe = @MainActor () -> Int64?

    private struct Repository: Hashable {
        let account: GitLabAccountIdentity
        let projectID: Int
    }
    private struct RepositorySize {
        let expiresAt: ContinuousClock.Instant
        let bytes: Task<Int64?, Never>
    }
    private struct RunningJob {
        let task: Task<Void, Never>
        let reservedBytes: Int64
    }
    private struct PendingJob {
        let handoff: Handoff
        let settings: SettingsManager
        var waitsForDiskRelease = false
    }

    private var tasks: [UUID: RunningJob] = [:]
    private var work: [UUID: AssistantAutomationRunner.MergeRequestWork] = [:]
    private var settingsByJob: [UUID: SettingsManager] = [:]
    private var repositorySizes: [Repository: RepositorySize] = [:]
    private let execute: Executor
    private let cleanupAfterSuccess: SuccessCleanup
    private let availableDiskBytes: CapacityProbe
    private let pipelineWorkDetector: ExistingPipelineWorkDetector
    private let maximumConcurrentJobs: Int
    private let healthStore: AssistantCLIHealthStore
    private var pending: [PendingJob] = []
    var onFinished: ((Handoff) -> Void)?
    private var terminating = false
    private var restoringCheckpointKey = false

    init(maximumConcurrentJobs: Int = 4, healthStore: AssistantCLIHealthStore? = nil,
         availableDiskBytes: CapacityProbe? = nil,
         pipelineWorkDetector: ExistingPipelineWorkDetector = .init(),
         cleanupAfterSuccess: @escaping SuccessCleanup = { _, _ in },
         execute: @escaping Executor = AssistantJobExecutor.execute) {
        self.maximumConcurrentJobs = min(4, max(1, maximumConcurrentJobs))
        self.healthStore = healthStore ?? .shared
        if let availableDiskBytes {
            self.availableDiskBytes = availableDiskBytes
        } else if ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .testHost {
            self.availableDiskBytes = { .max }
        } else {
            self.availableDiskBytes = Self.workspaceVolumeFreeBytes
        }
        self.pipelineWorkDetector = pipelineWorkDetector
        self.cleanupAfterSuccess = cleanupAfterSuccess
        self.execute = execute
        observeHealth()
    }

    private static func workspaceVolumeFreeBytes() -> Int64? {
        let directory = InstallationStorage.current.runs
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return try directory.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeAvailableCapacityKey])
                .volumeAvailableCapacity.map(Int64.init)
        } catch { return nil }
    }

    func repositorySize(projectID: Int, account: GitLabAccountIdentity, glab: GlabService) async -> Int64? {
        struct Project: Decodable {
            struct Statistics: Decodable {
                let repository_size: Int64?
            }
            let id: Int
            let statistics: Statistics?
        }

        guard projectID > 0, glab.resolvedHost == account.host, glab.currentUsername == account.username else { return nil }
        let key = Repository(account: account, projectID: projectID)
        let now = ContinuousClock.now
        let revision = glab.accountRevision
        if let cached = repositorySizes[key], cached.expiresAt > now {
            let bytes = await cached.bytes.value
            return glab.accountRevision == revision ? bytes : nil
        }
        let lookup = Task { @MainActor () -> Int64? in
            // The source project's repository size excludes unrelated project storage such as CI artifacts.
            guard let project: Project = try? await glab.mergeRequestAPI("/projects/\(projectID)?statistics=true",
                      host: account.host, timeout: 5),
                  glab.accountRevision == revision, project.id == projectID,
                  let bytes = project.statistics?.repository_size, bytes > 0 else { return nil }
            return bytes
        }
        repositorySizes[key] = .init(expiresAt: now.advanced(by: .seconds(600)), bytes: lookup)
        if repositorySizes.count > 128, let oldest = repositorySizes.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            repositorySizes.removeValue(forKey: oldest)
        }
        return await lookup.value
    }

    private func effectiveAvailableDiskBytes(_ measuredBytes: Int64?) -> Int64? {
        guard let bytes = measuredBytes, bytes >= 0 else { return nil }
        return tasks.values.reduce(bytes) { max(0, $0 - $1.reservedBytes) }
    }

    func canRetryAfterDiskFailure(_ execution: AssistantJobExecution?) -> Bool {
        guard let issue = execution?.prelaunchDiskFailure else { return true }
        return effectiveAvailableDiskBytes(availableDiskBytes()).map { $0 >= issue.requiredBytes } ?? false
    }

    private func observeHealth() {
        withObservationTracking {
            for assistant in AutomationAssistant.allCases { _ = healthStore.hold(for: assistant) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHealth(); self?.startPendingJobs() }
        }
    }

    func isWorking(on target: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        work.values.contains(target)
    }

    func isRunning(_ id: UUID) -> Bool { work[id] != nil }
    var hasActiveJobs: Bool { !tasks.isEmpty }

    func resumePendingJobs() { startPendingJobs() }

    @discardableResult
    func schedule(_ handoff: Handoff, settings: SettingsManager) -> Bool {
        guard permitsExecution(handoff, settings: settings),
              !terminating, !handoff.isObsoleteReminder, handoff.execution?.state == .queued,
              !isWorking(on: handoff.key.work), tasks[handoff.id] == nil else { return false }
        work[handoff.id] = handoff.key.work
        settingsByJob[handoff.id] = settings
        pending.append(.init(handoff: handoff, settings: settings))
        startPendingJobs()
        return true
    }

    private func permitsExecution(_ handoff: Handoff, settings: SettingsManager) -> Bool {
        settings.automaticActionsAllowed && (handoff.manual == true || settings.automaticWritesAllowed)
    }

    private func startPendingJobs() {
        guard !terminating else { return }
        let revoked = pending.filter { !permitsExecution($0.handoff, settings: $0.settings) }
        for entry in revoked { cancel(entry.handoff.id, origin: .policy) }
        let ready = pending.filter {
            !$0.waitsForDiskRelease && permitsExecution($0.handoff, settings: $0.settings)
                && $0.settings.automation.selectedAssistant != nil
                && healthStore.hold(for: $0.handoff.key.assistant) == nil
        }
        guard !ready.isEmpty else { return }
        let measured = availableDiskBytes()
        for entry in ready {
            guard !terminating else { break }
            let (handoff, settings) = (entry.handoff, entry.settings)
            guard let index = pending.firstIndex(where: { $0.handoff.id == handoff.id }),
                  !pending[index].waitsForDiskRelease, permitsExecution(handoff, settings: settings) else { continue }
            let required = Self.requiredDiskBytes(repositoryBytes: handoff.estimatedRepositoryBytes)
            let available = effectiveAvailableDiskBytes(measured)
            if let bytes = available, bytes >= required {
                guard tasks.count < maximumConcurrentJobs else {
                    updateDiskWait(nil, for: handoff.id, settings: settings)
                    continue
                }
                pending.remove(at: index)
                start(handoff, settings: settings, reservedBytes: required)
            } else {
                let issue = AssistantJobExecution.DiskAdmissionIssue(
                    cause: available == nil ? .capacityUnavailable : .insufficientCapacity, requiredBytes: required)
                if tasks.isEmpty {
                    pending.remove(at: index)
                    failDiskAdmission(handoff, settings: settings, issue: issue)
                } else {
                    pending[index].waitsForDiskRelease = true
                    updateDiskWait(issue, for: handoff.id, settings: settings)
                }
            }
        }
    }

    private func updateDiskWait(_ issue: AssistantJobExecution.DiskAdmissionIssue?, for id: UUID,
                                settings: SettingsManager) {
        guard settings.assistantHandoffs.first(where: { $0.id == id })?.execution?.diskAdmissionIssue != issue else { return }
        update(id, settings: settings) { $0.diskAdmissionIssue = issue }
    }

    private static func requiredDiskBytes(repositoryBytes: Int64?) -> Int64 {
        let minimum: Int64 = 1_000_000_000
        guard let repositoryBytes, repositoryBytes > minimum / 2 else { return minimum }
        let (doubled, overflow) = repositoryBytes.multipliedReportingOverflow(by: 2)
        return overflow ? .max : doubled
    }

    private func failDiskAdmission(_ handoff: Handoff, settings: SettingsManager,
                                   issue: AssistantJobExecution.DiskAdmissionIssue) {
        work[handoff.id] = nil
        settingsByJob[handoff.id] = nil
        let finishedAt = Date()
        AssistantAutomaticRetryCoordinator.recordDiskDeferredAttempt(for: handoff, at: finishedAt, settings: settings)
        update(handoff.id, settings: settings) {
            $0.state = .failed
            $0.startedAt = nil
            $0.finishedAt = finishedAt
            $0.diskAdmissionIssue = issue
            $0.error = String(localized: issue.errorTitle)
        }
        if let reservation = handoff.pipelineReservation, reservation.reservationID != nil {
            try? pipelineWorkDetector.finishHandoff(for: reservation)
        }
        if let finished = settings.assistantHandoffs.first(where: { $0.id == handoff.id }) {
            Task { [weak self] in
                guard let self, !terminating else { return }
                onFinished?(finished)
            }
        }
    }

    private func start(_ handoff: Handoff, settings: SettingsManager, reservedBytes: Int64) {
        let task = Task { [weak self] in
            guard let self else { return }
            self.update(handoff.id, settings: settings) {
                $0.state = .running
                $0.startedAt = Date()
                $0.diskAdmissionIssue = nil
            }
            do {
                try Task.checkCancellation()
                try AssistantJobExecutor.validatePersistence(settings)
                guard handoff.manual == true || settings.automaticWritesAllowed else {
                    throw AssistantJobExecutor.ExecutionError.disabledPermission
                }
                let outcome = try await execute(handoff, settings)
                try Task.checkCancellation()
                self.update(handoff.id, settings: settings) {
                    $0.state = outcome.result.status == .succeeded ? .succeeded : .blocked
                    $0.summary = String(outcome.summary.prefix(32_000))
                    $0.blocker = outcome.result.status == .blocked
                        ? outcome.result.blocker.map { String(GlabService.redactWorkflowEvidence($0).prefix(300)) } : nil
                    $0.output = String(outcome.output.prefix(262_144))
                    $0.finishedAt = Date()
                }
            } catch is AssistantJobExecutor.FeedbackAlreadyResolved where !Task.isCancelled && !terminating {
                self.recordResolvedFeedback(handoff.id, settings: settings)
            } catch AssistantUsageRunner.AccessError.temporarilyUnavailable {
                if !terminating && !Task.isCancelled {
                    self.update(handoff.id, settings: settings) { $0.state = .queued; $0.startedAt = nil }
                    pending.append(.init(handoff: handoff, settings: settings))
                    releaseRunningJob(handoff.id)
                    startPendingJobs()
                    return
                }
                self.update(handoff.id, settings: settings) {
                    $0.state = terminating ? .interrupted : .cancelled
                    $0.finishedAt = Date()
                }
            } catch {
                self.update(handoff.id, settings: settings) {
                    $0.state = terminating ? .interrupted : (error is CancellationError ? .cancelled : .failed)
                    $0.error = GlabService.redactWorkflowEvidence(String(describing: error))
                    if let failure = error as? AssistantJobFailure { $0.output = failure.transcript }
                    $0.finishedAt = Date()
                }
                if let index = settings.assistantHandoffs.firstIndex(where: { $0.id == handoff.id }),
                   let recovered = AssistantJobJournal.recover(settings.assistantHandoffs[index],
                        allowCompletion: error is CancellationError && AssistantJobJournal.didSave(handoff.id)) {
                    settings.assistantHandoffs[index].execution = recovered
                    settings.save()
                }
            }
            if !terminating, !Task.isCancelled,
               let finished = settings.assistantHandoffs.first(where: { $0.id == handoff.id }),
               finished.execution?.state == .succeeded {
                await cleanupAfterSuccess(finished, settings)
            }
            releaseRunningJob(handoff.id)
            work[handoff.id] = nil
            settingsByJob[handoff.id] = nil
            if !terminating, let finished = settings.assistantHandoffs.first(where: { $0.id == handoff.id }) { onFinished?(finished) }
            startPendingJobs()
        }
        tasks[handoff.id] = .init(task: task, reservedBytes: reservedBytes)
    }

    private func releaseRunningJob(_ id: UUID) {
        tasks[id] = nil
        for index in pending.indices { pending[index].waitsForDiskRelease = false }
    }

    func finishQueuedResolvedFeedback(_ id: UUID, settings: SettingsManager) -> Bool {
        guard tasks[id] == nil, settings.automaticActionsAllowed,
              let handoff = settings.assistantHandoffs.first(where: { $0.id == id }),
              handoff.execution?.state == .queued, !handoff.selectedFollowUpNotes.isEmpty else { return false }
        pending.removeAll { $0.handoff.id == id }
        work[id] = nil
        settingsByJob[id] = nil
        recordResolvedFeedback(id, settings: settings)
        if let finished = settings.assistantHandoffs.first(where: { $0.id == id }) { onFinished?(finished) }
        return true
    }

    private func recordResolvedFeedback(_ id: UUID, settings: SettingsManager) {
        guard let handoff = settings.assistantHandoffs.first(where: { $0.id == id }) else { return }
        let work = handoff.key.work
        let target = MRAutomationScope.Target.mergeRequest(host: work.host, username: handoff.key.username,
            projectID: work.projectID, iid: work.iid)
        // A skipped run cannot consume the retry budget if the same feedback is reopened.
        let attempts = settings.assistantHandoffs.filter {
            $0.id != id && $0.key.work == work && $0.key.username == target.username
                && $0.execution?.state != .feedbackResolved
        }
        settings.authorFeedbackAttempts = settings.authorFeedbackAttempts.filter { receipt in
            guard receipt.target == target, handoff.verifiedFeedbackNotes?[receipt.noteID] == receipt.revision,
                  receipt.decisionRevision == handoff.feedbackDecisionRevision || receipt.decisionRevision == nil,
                  receipt.recoveryRootID == nil || receipt.recoveryRootID == handoff.feedbackRecoveryRootID else { return true }
            return attempts.contains {
                $0.verifiedFeedbackNotes?[receipt.noteID] == receipt.revision
                    && ($0.feedbackDecisionRevision == receipt.decisionRevision || receipt.decisionRevision == nil)
                    && (receipt.recoveryRootID == nil || $0.feedbackRecoveryRootID == receipt.recoveryRootID)
            }
        }
        update(id, settings: settings) {
            $0.state = .feedbackResolved
            $0.startedAt = nil
            $0.diskAdmissionIssue = nil
            $0.summary = String(localized: .AssistantJobs.assistantJobsFeedbackResolved)
            $0.finishedAt = .now
        }
    }

    func cancel(_ id: UUID, origin: AssistantJobExecution.CancellationOrigin = .user) {
        if let settings = settingsByJob[id] {
            update(id, settings: settings) {
                if $0.cancellationOrigin != .user { $0.cancellationOrigin = origin }
            }
        }
        if let index = pending.firstIndex(where: { $0.handoff.id == id }) {
            let removed = pending.remove(at: index)
            work[id] = nil
            settingsByJob[id] = nil
            update(id, settings: removed.settings) {
                $0.state = .cancelled
                $0.finishedAt = Date()
                $0.diskAdmissionIssue = nil
            }
            if let finished = removed.settings.assistantHandoffs.first(where: { $0.id == id }) { onFinished?(finished) }
        } else { tasks[id]?.task.cancel() }
    }

    func prepareForTermination(settings: SettingsManager) {
        terminating = true
        for index in settings.assistantHandoffs.indices where work[settings.assistantHandoffs[index].id] != nil {
            settings.assistantHandoffs[index].execution = settings.assistantHandoffs[index].execution?.recoverAfterRestart()
        }
        settings.save()
        pending.removeAll()
        tasks.values.forEach { $0.task.cancel() }
        for handoff in settings.assistantHandoffs where work[handoff.id] != nil {
            if let reservation = handoff.pipelineReservation, reservation.reservationID != nil {
                try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
            }
        }
    }

    func synchronizeInterruptedRuns(settings: SettingsManager, pipelineWorkDetector: ExistingPipelineWorkDetector = .init()) {
        let detector = pipelineWorkDetector
        var changed = false
        for index in settings.assistantHandoffs.indices {
            guard let execution = settings.assistantHandoffs[index].execution,
                  execution.state.isActive || execution.state == .interrupted,
                  work[settings.assistantHandoffs[index].id] == nil else { continue }
            if let reservation = settings.assistantHandoffs[index].pipelineReservation {
                try? detector.recoverUnstartedRun(settings.assistantHandoffs[index].id, reservation: reservation, execution: execution)
            }
            let recovered = AssistantJobJournal.recover(settings.assistantHandoffs[index])
                ?? execution.recoverAfterRestart()
            if recovered != execution { settings.assistantHandoffs[index].execution = recovered; changed = true }
        }
        if changed { settings.save() }
        for handoff in settings.assistantHandoffs {
            guard let execution = handoff.execution, !execution.state.isActive, execution.state != .interrupted,
                  work[handoff.id] == nil, let reservation = handoff.pipelineReservation else { continue }
            try? detector.recoverTerminalRun(handoff.id, reservation: reservation, state: execution.state)
        }
        if !restoringCheckpointKey, !AssistantJobJournal.isKeyReady,
           settings.assistantHandoffs.contains(where: {
               work[$0.id] == nil && AssistantJobJournal.hasCheckpoint($0.id)
           }) {
            restoringCheckpointKey = true
            Task { @MainActor [weak self, weak settings] in
                let ready = await AssistantJobJournal.loadKey()
                guard let self, let settings else { return }
                restoringCheckpointKey = false
                if ready { synchronizeInterruptedRuns(settings: settings, pipelineWorkDetector: detector) }
            }
        }
    }

    func waitForTermination(timeout: Duration = .seconds(15)) async {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        while !tasks.isEmpty && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func update(_ id: UUID, settings: SettingsManager, mutate: (inout AssistantJobExecution) -> Void) {
        guard let index = settings.assistantHandoffs.firstIndex(where: { $0.id == id }),
              var execution = settings.assistantHandoffs[index].execution else { return }
        mutate(&execution)
        settings.assistantHandoffs[index].execution = execution
        settings.save()
    }
}
