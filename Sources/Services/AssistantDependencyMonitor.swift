import Foundation
import Observation

@MainActor @Observable
final class AssistantDependencyMonitor {
    private(set) var statuses: [AutomationAssistant: AssistantDependencyStatus] = [:]
    private var lastCheck: Date?
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

    func refresh(force: Bool = false) {
        if force { task?.cancel(); task = nil }
        guard task == nil, force || lastCheck.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        let current = UUID()
        generation = current
        task = Task {
            var results: [AutomationAssistant: AssistantDependencyStatus] = [:]
            for assistant in AutomationAssistant.allCases {
                results[assistant] = await probe(assistant)
            }
            guard generation == current, !Task.isCancelled else { return }
            let ready = results.keys.filter { results[$0]?.isReady == true && statuses[$0]?.isReady != true }
            let recovered = results.keys.filter { results[$0]?.isReady == true && statuses[$0]?.isReady == false }
            statuses = results
            lastCheck = Date()
            task = nil
            ready.forEach { onReady?($0) }
            recovered.forEach { onRecovered?($0) }
        }
    }
}
