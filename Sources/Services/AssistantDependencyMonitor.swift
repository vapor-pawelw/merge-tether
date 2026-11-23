import Foundation
import Observation

@MainActor @Observable
final class AssistantDependencyMonitor {
    private(set) var statuses: [AutomationAssistant: AssistantDependencyStatus] = [:]
    private var lastChecks: [AutomationAssistant: ContinuousClock.Instant] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let probe: @MainActor (AutomationAssistant) async -> AssistantDependencyStatus
    var onReady: ((AutomationAssistant) -> Void)?
    var onRecovered: ((AutomationAssistant) -> Void)?

    init(probe: @escaping @MainActor (AutomationAssistant) async -> AssistantDependencyStatus = AssistantCLI.detect) {
        self.probe = probe
    }

    var isChecking: Bool { task != nil }

    var available: Set<AutomationAssistant> { Set(statuses.filter { $0.value.isReady }.map(\.key)) }

    func check(_ assistant: AutomationAssistant) async -> AssistantDependencyStatus {
        await probe(assistant)
    }

    func refresh(_ assistants: Set<AutomationAssistant> = Set(AutomationAssistant.allCases), force: Bool = false) {
        guard !assistants.isEmpty else { return }
        if force { task?.cancel(); task = nil }
        guard task == nil else { return }
        let now = ContinuousClock.now
        let due = AutomationAssistant.allCases.filter { assistant in
            assistants.contains(assistant) && (force || lastChecks[assistant].map { $0.duration(to: now) >= .seconds(600) } ?? true)
        }
        guard !due.isEmpty else { return }
        let current = UUID()
        generation = current
        task = Task {
            var results: [AutomationAssistant: AssistantDependencyStatus] = [:]
            for assistant in due {
                guard !Task.isCancelled else { return }
                results[assistant] = await probe(assistant)
            }
            guard generation == current, !Task.isCancelled else { return }
            let ready = results.keys.filter { results[$0]?.isReady == true && statuses[$0]?.isReady != true }
            let recovered = results.keys.filter { results[$0]?.isReady == true && statuses[$0]?.isReady == false }
            statuses.merge(results) { _, latest in latest }
            let checkedAt = ContinuousClock.now
            for assistant in due { lastChecks[assistant] = checkedAt }
            task = nil
            ready.forEach { onReady?($0) }
            recovered.forEach { onRecovered?($0) }
        }
    }
}
