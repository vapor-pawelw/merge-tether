import Foundation
import Observation

@MainActor @Observable
final class AssistantSetupSession {
    let assistant: AutomationAssistant
    private(set) var status: AssistantDependencyStatus?
    private(set) var isWorking = false
    private(set) var canCommit = false
    private let probe: @MainActor (AutomationAssistant) async -> AssistantDependencyStatus
    private var generation = UUID()
    private var cancelled = false

    init(assistant: AutomationAssistant,
         probe: @escaping @MainActor (AutomationAssistant) async -> AssistantDependencyStatus = AssistantCLI.detect) {
        self.assistant = assistant
        self.probe = probe
    }
    func verify() async -> Bool {
        guard !cancelled else { return false }
        let current = UUID()
        generation = current
        isWorking = true
        canCommit = false
        let result = await probe(assistant)
        guard current == generation, !Task.isCancelled, !cancelled else { return false }
        status = result
        isWorking = false
        canCommit = result.isReady
        return canCommit
    }

    func cancel() {
        cancelled = true
        generation = UUID()
        canCommit = false
        isWorking = false
    }
}
