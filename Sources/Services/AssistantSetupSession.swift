import Foundation
import Observation

@MainActor @Observable
final class AssistantSetupSession {
    let assistant: AutomationAssistant
    let requireCLI: Bool
    private(set) var status: AssistantDependencyStatus?
    private(set) var isWorking = false
    private(set) var failed = false
    private(set) var canCommit = false
    private let probe: @MainActor (AutomationAssistant, Bool) async -> AssistantDependencyStatus
    private let install: @MainActor (AutomationAssistant) async throws -> Void
    private var generation = UUID()
    private var cancelled = false

    init(assistant: AutomationAssistant, requireCLI: Bool,
         probe: @escaping @MainActor (AutomationAssistant, Bool) async -> AssistantDependencyStatus = AssistantCLI.detect,
         install: @escaping @MainActor (AutomationAssistant) async throws -> Void = AssistantCLI.install) {
        self.assistant = assistant
        self.requireCLI = true
        self.probe = probe
        self.install = install
    }
    func verify() async -> Bool {
        guard !cancelled else { return false }
        let current = UUID()
        generation = current
        isWorking = true
        canCommit = false
        failed = false
        let result = await probe(assistant, requireCLI)
        guard current == generation, !Task.isCancelled, !cancelled else { return false }
        status = result
        isWorking = false
        canCommit = result.isReady
        return canCommit
    }

    func installAndVerify() async -> Bool {
        guard !cancelled, !isWorking else { return false }
        let current = generation
        isWorking = true
        failed = false
        do {
            try await install(assistant)
            guard current == generation, !Task.isCancelled else { return false }
            return await verify()
        } catch {
            guard current == generation else { return false }
            isWorking = false
            failed = true
            canCommit = false
            return false
        }
    }
    func cancel() {
        cancelled = true
        generation = UUID()
        canCommit = false
        isWorking = false
    }
}
