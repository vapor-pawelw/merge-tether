import Foundation
import Observation

@MainActor
final class AssistantCLILimitRecovery {
    private struct ScheduledCheck {
        let holdID: UUID
        let dueAt: Date
        let task: Task<Void, Never>
    }

    private let health: AssistantCLIHealthStore
    private let check: @MainActor (AutomationAssistant, URL) async -> AssistantCLIHealthCheck
    private let onRecovered: @MainActor (AutomationAssistant) -> Void
    private var checks: [AutomationAssistant: ScheduledCheck] = [:]
    private var observationID: UUID?

    init(health: AssistantCLIHealthStore,
         check: @escaping @MainActor (AutomationAssistant, URL) async -> AssistantCLIHealthCheck = AssistantCLI.checkUsageLimit,
         onRecovered: @escaping @MainActor (AutomationAssistant) -> Void) {
        self.health = health
        self.check = check
        self.onRecovered = onRecovered
    }

    func start() {
        guard observationID == nil else { return }
        let id = UUID()
        observationID = id
        observeHolds(id)
    }

    func stop() {
        observationID = nil
        checks.values.forEach { $0.task.cancel() }
        checks.removeAll()
    }

    func recheckExhaustedHold(_ assistant: AutomationAssistant, executable: URL, expectedID: UUID) async -> Bool {
        guard let hold = health.hold(for: assistant), hold.id == expectedID,
              hold.limitRecheck?.exhausted == true else { return false }
        return await recheck(assistant, hold: hold, executable: executable)
    }

    private func observeHolds(_ id: UUID) {
        guard observationID == id else { return }
        let holds = withObservationTracking {
            AutomationAssistant.allCases.map { ($0, health.hold(for: $0)) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHolds(id) }
        }
        for (assistant, hold) in holds {
            let dueAt = hold?.limitCheckAt
            guard checks[assistant]?.holdID != hold?.id || checks[assistant]?.dueAt != dueAt else { continue }
            checks.removeValue(forKey: assistant)?.task.cancel()
            guard let hold, let dueAt else { continue }
            let task = Task { [weak self] in
                while dueAt > Date() {
                    // Re-read wall time during long waits so clock adjustments don't leave a stale deadline.
                    do { try await Task.sleep(for: .seconds(min(3_600, max(0, dueAt.timeIntervalSinceNow)))) }
                    catch { return }
                }
                _ = await self?.recheck(assistant, hold: hold, executable: hold.executable)
            }
            checks[assistant] = ScheduledCheck(holdID: hold.id, dueAt: dueAt, task: task)
        }
    }

    private func recheck(_ assistant: AutomationAssistant, hold: AssistantCLIHealthStore.Hold, executable: URL) async -> Bool {
        guard !Task.isCancelled, health.hold(for: assistant)?.id == hold.id else { return false }
        let startedAt = Date()
        let result = await check(assistant, executable)
        guard !Task.isCancelled, health.hold(for: assistant)?.id == hold.id else { return false }
        let checkedAt = Date()
        switch result {
        case .available:
            guard health.clear(assistant, expectedID: hold.id) else { return false }
            onRecovered(assistant)
            return true
        case .held(let issue) where issue.kind == .loginRequired:
            health.record(issue, assistant: assistant, executable: executable, startedAt: startedAt, observedAt: checkedAt)
        case .held, .unavailable:
            health.recordFailedLimitCheck(assistant, expectedID: hold.id, checkedAt: checkedAt, reportedIssue: result.issue)
        }
        return false
    }
}
