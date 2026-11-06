import Foundation
import Observation

@MainActor @Observable
final class AssistantDependencyMonitor {
    private(set) var statuses: [AutomationAssistant: AssistantDependencyStatus] = [:]
    private var lastCheck: Date?
    private var requirement: Bool?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let probe: @MainActor (AutomationAssistant, Bool) async -> AssistantDependencyStatus
    var onRecovered: ((AutomationAssistant) -> Void)?

    init(probe: @escaping @MainActor (AutomationAssistant, Bool) async -> AssistantDependencyStatus = AssistantCLI.detect) {
        self.probe = probe
    }

    var isChecking: Bool { task != nil }

    var available: Set<AutomationAssistant> { Set(statuses.filter { $0.value.isReady }.map(\.key)) }

    func refresh(requireCLI _: Bool = true, force: Bool = false) {
        let requireCLI = true
        if force { task?.cancel(); task = nil }
        if requirement != requireCLI {
            task?.cancel()
            task = nil
            lastCheck = nil
            statuses = [:]
        }
        guard task == nil, force || lastCheck.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        requirement = requireCLI
        let current = UUID()
        generation = current
        task = Task {
            var results: [AutomationAssistant: AssistantDependencyStatus] = [:]
            for assistant in AutomationAssistant.allCases {
                results[assistant] = await probe(assistant, requireCLI)
            }
            guard generation == current, !Task.isCancelled else { return }
            let recovered = results.keys.filter { results[$0]?.isReady == true && statuses[$0]?.isReady == false }
            statuses = results
            lastCheck = Date()
            task = nil
            recovered.forEach { onRecovered?($0) }
        }
    }
}
