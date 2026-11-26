import Foundation
import Observation

/// Only schedules fresh workflow admission. The callback must perform current-context checks before creating a new run.
@MainActor @Observable
final class AssistantAutomaticRetryCoordinator {
    typealias Handoff = AssistantAutomationRunner.Handoff
    typealias Clock = @MainActor () -> Date
    typealias Wait = @MainActor (TimeInterval) async throws -> Void
    enum LaunchResult { case started(Handoff), deferred, obsolete, failed(String) }

    private(set) var pendingPlans: [AssistantAutomaticRetryPolicy.Plan] = []
    private(set) var exhaustedJobIDs: Set<UUID> = []
    var onChange: (() -> Void)?
    var isProcessing: Bool { drainTask != nil }
    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let now: Clock
    @ObservationIgnored private let wait: Wait
    @ObservationIgnored private let canRetry: @MainActor (Handoff) -> Bool
    @ObservationIgnored private let onAdopt: @MainActor (UUID, Handoff) -> Void
    @ObservationIgnored private var adoptedReservations: Set<UUID> = []
    @ObservationIgnored private let launch: @MainActor (Handoff, AssistantAutomaticRetryIdentity) async throws -> LaunchResult
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var deferredUntil: [UUID: Date] = [:]
    @ObservationIgnored private var announcedPlans: Set<String> = []
    @ObservationIgnored private var announcedExhaustion: Set<UUID> = []
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var stopped = false

    init(settings: SettingsManager, now: @escaping Clock = { Date() },
         wait: @escaping Wait = { try await Task.sleep(for: .seconds($0)) },
         onAdopt: @escaping @MainActor (UUID, Handoff) -> Void = { _, _ in },
         canRetry: @escaping @MainActor (Handoff) -> Bool,
         launch: @escaping @MainActor (Handoff, AssistantAutomaticRetryIdentity) async throws -> LaunchResult) {
        self.settings = settings; self.now = now; self.wait = wait
        self.canRetry = canRetry; self.launch = launch; self.onAdopt = onAdopt
    }

    func wake() {
        guard !stopped else { return }
        requested = true
        timerTask?.cancel(); timerTask = nil
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            await drain()
            drainTask = nil
            if requested && !stopped { wake() }
        }
    }

    func cancel() {
        stopped = true
        timerTask?.cancel(); timerTask = nil
        drainTask?.cancel()
    }

    static func recordDiskDeferredAttempt(for child: Handoff, at date: Date, settings: SettingsManager) {
        guard let identity = child.automaticRetryIdentity, let parent = child.retryOf else { return }
        let work = child.key.work
        let target = AssistantAutomaticRetryTarget(host: work.host, username: child.key.username,
            projectID: work.projectID, iid: work.iid)
        guard let index = settings.assistantAutomaticRetryAttempts.firstIndex(where: {
            $0.identity == identity && $0.parentJobID == parent && $0.target == target && $0.diskDeferred != true
                && ($0.state == .reserved && $0.replacementJobID == nil
                    || $0.state == .started && $0.replacementJobID == child.id)
        }) else { return }
        var attempt = settings.assistantAutomaticRetryAttempts[index]
        attempt.state = .started
        attempt.finishedAt = date
        attempt.replacementJobID = child.id
        attempt.diskDeferred = true
        settings.assistantAutomaticRetryAttempts[index] = attempt
    }

    /// Startup-only, after job completion checkpoints have been recovered. An admission that did
    /// not record a child consumes its attempt; it never replays the same reservation.
    func recoverUnfinishedAdmissions() {
        guard drainTask == nil, settings.automaticActionsAllowed else { return }
        var changed = reconcileRecordedChildren()
        for index in settings.assistantAutomaticRetryAttempts.indices
            where settings.assistantAutomaticRetryAttempts[index].state == .reserved {
            settings.assistantAutomaticRetryAttempts[index].state = .failed
            settings.assistantAutomaticRetryAttempts[index].finishedAt = now()
            settings.assistantAutomaticRetryAttempts[index].failure = String(localized: .AssistantRetry.assistantRetryAdmissionInterrupted)
            changed = true
        }
        if changed { settings.save(); onChange?() }
        wake()
    }

    private func drain() async {
        while !stopped && !Task.isCancelled {
            requested = false
            if reconcileRecordedChildren() { settings.save(); onChange?() }
            let jobs = settings.assistantHandoffs
            let candidates = jobs.filter { $0.readOnlyReview != true }.map { candidate($0) }
            let assessments = AssistantAutomaticRetryPolicy.assess(candidates, attempts: settings.assistantAutomaticRetryAttempts)
            var plans: [AssistantAutomaticRetryPolicy.Plan] = []
            var exhausted: Set<UUID> = []
            for assessment in assessments {
                switch assessment {
                case .planned(var plan):
                    if let hold = deferredUntil[plan.parentJobID] { plan.dueAt = max(plan.dueAt, hold) }
                    plans.append(plan)
                    if settings.automaticActionsAllowed,
                       jobs.first(where: { $0.id == plan.parentJobID }).map({ canRetry($0) }) == true,
                       announcedPlans.insert(plan.id).inserted {
                        record(plan.target, state: .requested, jobID: plan.parentJobID,
                            message: String(localized: .AssistantRetry.assistantRetryScheduled(plan.attempt,
                                AssistantAutomaticRetryPolicy.maximumRetries, max(plan.dueAt, now()).formatted(date: .abbreviated, time: .standard))))
                    }
                case .exhausted(let parentID, let rootID):
                    exhausted.insert(parentID)
                    if settings.automaticActionsAllowed, announcedExhaustion.insert(rootID).inserted,
                       let job = jobs.first(where: { $0.id == parentID }) {
                        record(target(job), state: .blocked, jobID: parentID,
                            message: String(localized: .AssistantRetry.assistantRetryExhausted(AssistantAutomaticRetryPolicy.maximumRetries)))
                    }
                }
            }
            if pendingPlans != plans || exhaustedJobIDs != exhausted {
                pendingPlans = plans; exhaustedJobIDs = exhausted; onChange?()
            }
            guard settings.automaticActionsAllowed,
                  let plan = plans.first(where: { plan in
                      plan.dueAt <= now() && jobs.first(where: { $0.id == plan.parentJobID }).map { canRetry($0) } == true
                  }), let job = settings.assistantHandoffs.first(where: { $0.id == plan.parentJobID }) else {
                armTimer(plans); return
            }
            let reservation = plan.reservation(at: now())
            let previousIdentity = job.automaticRetryIdentity
            settings.assistantAutomaticRetryAttempts.append(reservation)
            if plan.rootID == job.id,
               let index = settings.assistantHandoffs.firstIndex(where: { $0.id == job.id }) {
                settings.assistantHandoffs[index].automaticRetryIdentity = reservation.identity
            }
            guard settings.save(), settings.automaticActionsAllowed else { return }
            guard !stopped, !Task.isCancelled, canRetry(job) else {
                remove(reservation, restoring: previousIdentity)
                settings.save()
                continue
            }
            let outcome: LaunchResult
            do { outcome = try await launch(job, reservation.identity) }
            catch { outcome = .failed(GlabService.redactWorkflowEvidence(String(describing: error))) }
            if reconcileRecordedChildren(),
               let recorded = settings.assistantAutomaticRetryAttempts.first(where: { $0.id == reservation.id }),
               let child = settings.assistantHandoffs.first(where: { $0.id == recorded.replacementJobID }) {
                apply(.started(child), reservation: reservation, previousIdentity: previousIdentity)
            } else { apply(outcome, reservation: reservation, previousIdentity: previousIdentity) }
        }
    }

    private func apply(_ result: LaunchResult, reservation: AssistantAutomaticRetryAttempt,
                       previousIdentity: AssistantAutomaticRetryIdentity?) {
        guard let index = settings.assistantAutomaticRetryAttempts.firstIndex(where: {
            $0.id == reservation.id && $0.diskDeferred != true
        }) else { return }
        switch result {
        case .started(let child):
            settings.assistantAutomaticRetryAttempts[index].state = .started
            settings.assistantAutomaticRetryAttempts[index].finishedAt = now()
            settings.assistantAutomaticRetryAttempts[index].replacementJobID = child.id
            record(reservation.target, state: .queued, jobID: child.id, related: reservation.parentJobID,
                message: String(localized: .AssistantRetry.assistantRetryStarted(reservation.attempt, AssistantAutomaticRetryPolicy.maximumRetries)))
        case .deferred:
            remove(reservation, restoring: previousIdentity)
            deferredUntil[reservation.parentJobID] = now().addingTimeInterval(15)
        case .obsolete:
            settings.assistantAutomaticRetryAttempts[index].state = .obsolete
            settings.assistantAutomaticRetryAttempts[index].finishedAt = now()
            record(reservation.target, state: .completed, jobID: reservation.parentJobID,
                message: String(localized: .AssistantRetry.assistantRetryObsolete))
        case .failed(let reason):
            let explanation = String(GlabService.redactWorkflowEvidence(reason).prefix(600))
            settings.assistantAutomaticRetryAttempts[index].state = .failed
            settings.assistantAutomaticRetryAttempts[index].finishedAt = now()
            settings.assistantAutomaticRetryAttempts[index].failure = explanation
            record(reservation.target, state: .failed, jobID: reservation.parentJobID,
                message: String(localized: .AssistantRetry.assistantRetryFailed(explanation)))
        }
        settings.save(); onChange?()
    }

    private func remove(_ reservation: AssistantAutomaticRetryAttempt, restoring previousIdentity: AssistantAutomaticRetryIdentity?) {
        settings.assistantAutomaticRetryAttempts.removeAll { $0.id == reservation.id }
        if reservation.rootID == reservation.parentJobID,
           let index = settings.assistantHandoffs.firstIndex(where: { $0.id == reservation.parentJobID }),
           settings.assistantHandoffs[index].automaticRetryIdentity == reservation.identity {
            settings.assistantHandoffs[index].automaticRetryIdentity = previousIdentity
        }
    }

    private func armTimer(_ plans: [AssistantAutomaticRetryPolicy.Plan]) {
        guard !stopped, settings.automaticActionsAllowed,
              let due = plans.map(\.dueAt).filter({ $0 > now() }).min() else { return }
        let delay = due.timeIntervalSince(now()), wait = wait
        timerTask = Task { [weak self] in
            do { try await wait(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            timerTask = nil; wake()
        }
    }

    private func reconcileRecordedChildren() -> Bool {
        var changed = false
        let indices = settings.assistantAutomaticRetryAttempts.indices.sorted {
            let a = settings.assistantAutomaticRetryAttempts[$0], b = settings.assistantAutomaticRetryAttempts[$1]
            return a.attempt == b.attempt ? a.id.uuidString < b.id.uuidString : a.attempt < b.attempt
        }
        for index in indices {
            let record = settings.assistantAutomaticRetryAttempts[index]
            guard record.state == .reserved || record.state == .started else { continue }
            let children = settings.assistantHandoffs.filter {
                $0.automaticRetryIdentity == record.identity && $0.retryOf == record.parentJobID && target($0) == record.target
            }
            guard children.count == 1, let child = children.first, child.id != record.parentJobID else { continue }
            if let execution = child.execution, execution.prelaunchDiskFailure != nil, record.diskDeferred != true {
                guard record.state == .reserved ? record.replacementJobID == nil : record.replacementJobID == child.id else { continue }
                Self.recordDiskDeferredAttempt(for: child, at: execution.finishedAt ?? now(), settings: settings)
                changed = true
            } else if record.state == .reserved {
                guard record.replacementJobID == nil else { continue }
                settings.assistantAutomaticRetryAttempts[index].state = .started
                settings.assistantAutomaticRetryAttempts[index].finishedAt = now()
                settings.assistantAutomaticRetryAttempts[index].replacementJobID = child.id
                changed = true
            } else if record.replacementJobID != child.id { continue }
            if adoptedReservations.insert(record.id).inserted { onAdopt(record.parentJobID, child) }
        }
        return changed
    }

    private func candidate(_ job: Handoff) -> AssistantAutomaticRetryPolicy.Candidate {
        .init(id: job.id, target: target(job), family: family(job), createdAt: job.createdAt,
            state: job.execution?.state ?? .blocked, finishedAt: job.execution?.finishedAt,
            cancellationOrigin: job.execution?.cancellationOrigin,
            automaticRetryIdentity: job.automaticRetryIdentity, retryOf: job.retryOf,
            isExecutable: job.taskPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && job.mergeRequestURL != nil
                && job.execution?.pendingWorkerAudit == nil && job.execution?.remoteEffects?.isEmpty != false,
            delegatesRecovery: job.draftRepair != nil || job.workflow == .followUp && !(job.feedbackNoteIDs ?? []).isEmpty,
            isObsolete: job.isObsoleteReminder)
    }

    private func family(_ job: Handoff) -> String {
        if let identity = job.automaticRetryIdentity,
           let record = settings.assistantAutomaticRetryAttempts.first(where: { $0.identity == identity }) { return record.family }
        if job.pipelineReservation != nil || job.foreignPipelineDiagnosis != nil || job.taskIntent == .pipelineDiagnosis { return "pipeline" }
        if job.taskIntent == .conflictResolution || job.allowsPush { return "conflict" }
        if job.workflow == .review || job.reviewModel != nil { return "review" }
        if job.workflow == .followUp && !(job.feedbackNoteIDs ?? []).isEmpty { return "feedback" }
        return "task:" + UserAttentionSnapshot.digest(job.taskPrompt ?? "")
    }

    private func target(_ job: Handoff) -> AssistantAutomaticRetryTarget {
        .init(host: job.key.work.host, username: job.key.username, projectID: job.key.work.projectID, iid: job.key.work.iid)
    }

    private func record(_ target: AssistantAutomaticRetryTarget, state: MRAutomationEvent.State,
                        jobID: UUID, related: UUID? = nil, message: String) {
        settings.recordAutomationEvent(target: .init(host: target.host, username: target.username,
            projectID: target.projectID, iid: target.iid), action: .retry, origin: .automatic,
            state: state, message: message, jobID: jobID, relatedJobID: related, now: now())
    }
}
