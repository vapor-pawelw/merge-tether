import Foundation

/// Owns live tasks only. Persisted queued/running records are never replayed after restart.
@MainActor
final class AssistantJobCoordinator {
    typealias Handoff = AssistantAutomationRunner.Handoff
    struct Outcome: Sendable {
        let result: AssistantJobResult
        let output: String
    }
    typealias Executor = @MainActor (Handoff, SettingsManager) async throws -> Outcome

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var work: [UUID: AssistantAutomationRunner.MergeRequestWork] = [:]
    private let execute: Executor
    private let maximumConcurrentJobs: Int
    private var pending: [(handoff: Handoff, settings: SettingsManager)] = []
    var onFinished: ((Handoff) -> Void)?
    private var terminating = false

    init(maximumConcurrentJobs: Int = 2, execute: @escaping Executor = AssistantJobExecutor.execute) {
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.execute = execute
    }

    func isWorking(on target: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        work.values.contains(target)
    }

    func isRunning(_ id: UUID) -> Bool { work[id] != nil }

    @discardableResult
    func schedule(_ handoff: Handoff, settings: SettingsManager) -> Bool {
        guard !terminating, handoff.execution?.state == .queued, !isWorking(on: handoff.key.work), tasks[handoff.id] == nil else { return false }
        work[handoff.id] = handoff.key.work
        pending.append((handoff, settings))
        startPendingJobs()
        return true
    }

    private func startPendingJobs() {
        while !terminating, tasks.count < maximumConcurrentJobs, !pending.isEmpty {
            let next = pending.removeFirst()
            start(next.handoff, settings: next.settings)
        }
    }

    private func start(_ handoff: Handoff, settings: SettingsManager) {
        tasks[handoff.id] = Task { [weak self] in
            guard let self else { return }
            self.update(handoff.id, settings: settings) {
                $0.state = .running
                $0.startedAt = Date()
            }
            do {
                try Task.checkCancellation()
                let outcome = try await execute(handoff, settings)
                try Task.checkCancellation()
                self.update(handoff.id, settings: settings) {
                    $0.state = outcome.result.status == .succeeded ? .succeeded : .blocked
                    $0.summary = String(outcome.result.summary.prefix(32_000))
                    $0.blocker = outcome.result.status == .blocked
                        ? outcome.result.blocker.map { String(GlabService.redactWorkflowEvidence($0).prefix(300)) } : nil
                    $0.output = String(outcome.output.prefix(262_144))
                    $0.finishedAt = Date()
                }
            } catch {
                self.update(handoff.id, settings: settings) {
                    $0.state = terminating ? .interrupted : (error is CancellationError ? .cancelled : .failed)
                    $0.error = GlabService.redactWorkflowEvidence(String(describing: error))
                    if let failure = error as? AssistantJobFailure { $0.output = failure.transcript }
                    $0.finishedAt = Date()
                }
            }
            tasks[handoff.id] = nil
            work[handoff.id] = nil
            if !terminating, let finished = settings.assistantHandoffs.first(where: { $0.id == handoff.id }) { onFinished?(finished) }
            startPendingJobs()
        }
    }

    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.handoff.id == id }) {
            let removed = pending.remove(at: index)
            work[id] = nil
            update(id, settings: removed.settings) { $0.state = .cancelled; $0.finishedAt = Date() }
            if let finished = removed.settings.assistantHandoffs.first(where: { $0.id == id }) { onFinished?(finished) }
        } else { tasks[id]?.cancel() }
    }

    func prepareForTermination(settings: SettingsManager) {
        terminating = true
        for index in settings.assistantHandoffs.indices where work[settings.assistantHandoffs[index].id] != nil {
            settings.assistantHandoffs[index].execution = settings.assistantHandoffs[index].execution?.recoverAfterRestart()
        }
        settings.save()
        pending.removeAll()
        tasks.values.forEach { $0.cancel() }
        for handoff in settings.assistantHandoffs where work[handoff.id] != nil {
            if let reservation = handoff.pipelineReservation, reservation.reservationID != nil {
                try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
            }
        }
    }

    func synchronizeInterruptedRuns(settings: SettingsManager) {
        var changed = false
        for index in settings.assistantHandoffs.indices {
            guard let execution = settings.assistantHandoffs[index].execution,
                  execution.state.isActive, work[settings.assistantHandoffs[index].id] == nil else { continue }
            settings.assistantHandoffs[index].execution = execution.recoverAfterRestart()
            changed = true
        }
        if changed { settings.save() }
    }

    private func update(_ id: UUID, settings: SettingsManager, mutate: (inout AssistantJobExecution) -> Void) {
        guard let index = settings.assistantHandoffs.firstIndex(where: { $0.id == id }),
              var execution = settings.assistantHandoffs[index].execution else { return }
        mutate(&execution)
        settings.assistantHandoffs[index].execution = execution
        settings.save()
    }
}
