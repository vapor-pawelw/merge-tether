import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct AssistantJobCoordinatorTests {
    private func fixture() throws -> (SettingsManager, String, UserDefaults) {
        let name = "AssistantJobCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (SettingsManager(defaults: defaults), name, defaults)
    }

    private func job(state: AssistantJobExecution.State? = .queued, iid: Int = 2) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
                                    work: .init(host: "gitlab.example.org", projectID: 1, iid: iid),
                                    username: "me", workspace: "", access: .gitLabRead),
              title: "Review !2", prompt: "Review", createdAt: Date(), allowsPush: false,
              execution: state.map { .init(state: $0) })
    }

    @Test func interruptedRecoveryPreservesLegacyAndCompletedHistory() throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.assistantHandoffs = [job(state: .running), job(state: nil), job(state: .succeeded)]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in Issue.record("Must not replay"); throw CancellationError() })
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[0].execution?.state == .interrupted)
        #expect(settings.assistantHandoffs[1].execution == nil)
        #expect(settings.assistantHandoffs[2].execution?.state == .succeeded)
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.assistantHandoffs[0].execution?.state == .interrupted)
    }

    @Test func excludesDuplicateMergeRequestAndPreservesRunningJobDuringRecovery() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = job(), duplicate = job()
        settings.assistantHandoffs = [first, duplicate]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "Done")
        })
        #expect(coordinator.schedule(first, settings: settings))
        #expect(!coordinator.schedule(duplicate, settings: settings))
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[0].execution?.state == .queued)
        #expect(settings.assistantHandoffs[1].execution?.state == .interrupted)
        coordinator.cancel(first.id)
        for _ in 0..<100 where coordinator.isRunning(first.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(settings.assistantHandoffs[0].execution?.state == .cancelled)
        #expect(!coordinator.isWorking(on: first.key.work))
    }

    @Test func persistsBlockedResultWithoutAcknowledgingFeedback() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let pending = job()
        settings.assistantHandoffs = [pending]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .blocked, summary: "Missing evidence"), output: "Diagnostic")
        })
        var callbackState: AssistantJobExecution.State?
        coordinator.onFinished = { callbackState = $0.execution?.state }
        #expect(coordinator.schedule(pending, settings: settings))
        for _ in 0..<100 where coordinator.isRunning(pending.id) { try await Task.sleep(for: .milliseconds(5)) }
        let result = try #require(settings.assistantHandoffs.first)
        #expect(result.execution?.state == .blocked)
        #expect(result.execution?.summary == "Missing evidence")
        #expect(result.execution?.output == "Diagnostic")
        #expect(result.deliveredFeedbackTodos.isEmpty)
        #expect(callbackState == .blocked)
        #expect(SettingsManager(defaults: defaults).assistantHandoffs.first?.execution?.state == .blocked)
    }

    @Test func failedCLIResultKeepsRedactedPartialOutputForInspection() async throws {
        struct Failure: Error {}
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let pending = job()
        settings.assistantHandoffs = [pending]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            throw AssistantJobFailure(error: Failure(), output: .init(
                stdout: Data("Draft 12 saved, then verification failed".utf8), stderr: "Missing proof", exitCode: 1))
        })
        #expect(coordinator.schedule(pending, settings: settings))
        for _ in 0..<100 where coordinator.isRunning(pending.id) { try await Task.sleep(for: .milliseconds(5)) }
        let execution = try #require(settings.assistantHandoffs.first?.execution)
        #expect(execution.state == .failed)
        #expect(execution.output?.contains("Draft 12 saved") == true)
        #expect(execution.output?.contains("Missing proof") == true)
        #expect(settings.assistantHandoffs.first?.deliveredFeedbackTodos.isEmpty == true)
    }

    @Test func thrownExecutorFailureIsPersistedAsFailure() async throws {
        struct Failure: Error {}
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let pending = job()
        settings.assistantHandoffs = [pending]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in throw Failure() })
        #expect(coordinator.schedule(pending, settings: settings))
        for _ in 0..<100 where coordinator.isRunning(pending.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(settings.assistantHandoffs.first?.execution?.state == .failed)
        #expect(settings.assistantHandoffs.first?.execution?.error != nil)
    }
    @Test func concurrencyLimitKeepsExcessJobsQueuedAndAllowsCancellingThem() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = job(iid: 1), second = job(iid: 2)
        settings.assistantHandoffs = [first, second]
        var executed: [UUID] = []
        let coordinator = AssistantJobCoordinator(maximumConcurrentJobs: 1, execute: { handoff, _ in
            executed.append(handoff.id)
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        #expect(coordinator.schedule(first, settings: settings))
        #expect(coordinator.schedule(second, settings: settings))
        for _ in 0..<100 where executed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executed == [first.id])
        #expect(settings.assistantHandoffs[1].execution?.state == .queued)
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[1].execution?.state == .queued)
        coordinator.cancel(second.id)
        #expect(settings.assistantHandoffs[1].execution?.state == .cancelled)
        #expect(!coordinator.isWorking(on: second.key.work))
        coordinator.cancel(first.id)
        for _ in 0..<100 where coordinator.isRunning(first.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executed == [first.id])
    }

}
