import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AssistantAutomaticRetryCoordinatorTests {
    @Test func aDueRetryPersistsItsReservationBeforeFreshWorkflowAdmission() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(15)
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }

        coordinator.wake()
        try await f.settle(coordinator)

        #expect(f.launches == 1 && f.sawDurableReservation)
        let child = try #require(f.settings.assistantHandoffs.last)
        #expect(child.retryOf == f.original.id)
        #expect(child.automaticRetryIdentity?.attempt == 1)
        #expect(f.settings.assistantAutomaticRetryAttempts.first?.replacementJobID == child.id)
        #expect(f.settings.automationEvents.contains { $0.action == .retry && $0.origin == .automatic && $0.state == .queued })
    }

    @Test func delayHealthAndPermissionsDoNotSpendAttempts() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
        #expect(coordinator.pendingPlans.first?.dueAt == f.finished.addingTimeInterval(15))
        f.date = f.finished.addingTimeInterval(100)
        f.allowed = false
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
        f.allowed = true
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1)
    }

    @Test func theInitialCLIReadyTransitionWakesAnOverdueRetryWithoutRecoveryBudgetReset() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.allowed = false
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        let dependencies = AssistantDependencyMonitor(probe: { _ in .ready(URL(fileURLWithPath: "/example/cli")) })
        var recoveryResets = 0
        dependencies.onRecovered = { _ in recoveryResets += 1 }
        dependencies.onReady = { assistant in
            guard assistant == .codex else { return }
            f.allowed = dependencies.available.contains(assistant)
            coordinator.wake()
        }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)

        dependencies.refresh(force: true)
        for _ in 0..<1000 where dependencies.isChecking { await Task.yield() }
        try #require(!dependencies.isChecking)
        try await f.settle(coordinator)

        #expect(f.launches == 1 && recoveryResets == 0)
    }

    @Test func deferredAdmissionDoesNotSpinOrSpendItsRetry() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.result = .deferred
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
        #expect(f.settings.assistantHandoffs.first?.automaticRetryIdentity == nil)
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1)
        f.date = f.date.addingTimeInterval(15)
        f.result = .started
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 2 && f.settings.assistantAutomaticRetryAttempts.first?.attempt == 1)
    }

    @Test func repeatedWakesAndAnActiveTaskDoNotCreateAnotherRunForTheMR() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.hold = true
        let coordinator = f.coordinator()
        defer { coordinator.cancel(); f.release() }
        coordinator.wake()
        try await f.waitForLaunch()
        coordinator.wake(); coordinator.wake(); coordinator.wake()
        #expect(f.launches == 1 && f.settings.assistantAutomaticRetryAttempts.count == 1)
        f.release()
        try await f.settle(coordinator)
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1 && f.settings.assistantHandoffs.count == 2)
    }

    @Test func failureBudgetSurvivesRestartAndProfileChanges() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.result = .failed
        f.date = f.finished.addingTimeInterval(15)
        var current = f.settings
        for attempt in 1...3 {
            let coordinator = f.coordinator(settings: current)
            coordinator.wake()
            try await f.settle(coordinator)
            coordinator.cancel()
            #expect(current.assistantAutomaticRetryAttempts.count == attempt)
            current = SettingsManager(defaults: f.defaults)
            current.automation.applyPreset(.trusted, for: .codex)
            current.save()
            f.date = f.date.addingTimeInterval(attempt == 1 ? 60 : 300)
        }
        let exhausted = f.coordinator(settings: current)
        defer { exhausted.cancel() }
        exhausted.wake()
        try await f.settle(exhausted)
        #expect(f.launches == 3)
        #expect(exhausted.exhaustedJobIDs == [f.original.id])
        #expect(current.automationEvents.contains { $0.action == .retry && $0.origin == .automatic && $0.state == .blocked })
    }

    @Test(arguments: [false, true])
    func startupReconcilesARecordedChildBeforeConsumingAnInterruptedAdmission(_ childExists: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(20)
        let plan = try #require(AssistantAutomaticRetryPolicy.assess([
            .init(id: f.original.id, target: f.target, family: "review", createdAt: f.original.createdAt,
                state: .failed, finishedAt: f.finished)
        ], attempts: []).compactMap { if case .planned(let value) = $0 { value } else { nil } }.first)
        let reserved = plan.reservation(at: f.date)
        f.settings.assistantAutomaticRetryAttempts = [reserved]
        if childExists { f.settings.assistantHandoffs.append(f.child(of: f.original, identity: reserved.identity)) }
        f.settings.save()
        let reloaded = SettingsManager(defaults: f.defaults)
        let coordinator = f.coordinator(settings: reloaded)
        defer { coordinator.cancel() }

        coordinator.recoverUnfinishedAdmissions()
        try await f.settle(coordinator)

        #expect(f.launches == 0)
        #expect(reloaded.assistantAutomaticRetryAttempts.first?.state == (childExists ? .started : .failed))
        if !childExists {
            #expect(coordinator.pendingPlans.first?.attempt == 2)
            #expect(coordinator.pendingPlans.first?.dueAt == f.date.addingTimeInterval(60))
        }
    }

    @Test(arguments: [AssistantAutomaticRetryAttempt.State.reserved, .started])
    func startupAdoptsPersistedChildrenOnceEvenIfTheirLedgerWasAlreadyStarted(_ state: AssistantAutomaticRetryAttempt.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let plan = try #require(AssistantAutomaticRetryPolicy.assess([
            .init(id: f.original.id, target: f.target, family: "review", createdAt: f.original.createdAt,
                state: .failed, finishedAt: f.finished)
        ], attempts: []).compactMap { if case .planned(let value) = $0 { value } else { nil } }.first)
        var receipt = plan.reservation(at: f.date)
        var child = f.child(of: f.original, identity: receipt.identity)
        child.execution = .init(state: .succeeded, finishedAt: f.date)
        receipt.state = state
        if state == .started { receipt.replacementJobID = child.id }
        f.settings.assistantAutomaticRetryAttempts = [receipt]
        f.settings.assistantHandoffs.append(child)
        f.settings.save()
        var adoptions = 0
        let coordinator = f.coordinator(onAdopt: { parent, adopted in
            #expect(parent == f.original.id && adopted.id == child.id)
            adoptions += 1
        })
        defer { coordinator.cancel() }

        coordinator.recoverUnfinishedAdmissions()
        try await f.settle(coordinator)
        coordinator.wake()
        try await f.settle(coordinator)

        #expect(adoptions == 1 && f.launches == 0)
        #expect(f.settings.assistantAutomaticRetryAttempts.first?.state == .started)
        #expect(f.settings.assistantAutomaticRetryAttempts.first?.replacementJobID == child.id)
    }

    @Test func startupAdoptsShuffledStartedLineagesInParentOrder() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let firstIdentity = AssistantAutomaticRetryIdentity(rootID: f.original.id, reservationID: UUID(), attempt: 1)
        var first = f.child(of: f.original, identity: firstIdentity)
        first.execution = .init(state: .failed, finishedAt: f.date)
        let lastIdentity = AssistantAutomaticRetryIdentity(rootID: f.original.id, reservationID: UUID(), attempt: 2)
        var last = f.child(of: first, identity: lastIdentity)
        last.execution = .init(state: .succeeded, finishedAt: f.date)
        last = .init(id: last.id, key: last.key, title: last.title, prompt: last.prompt,
            createdAt: f.date.addingTimeInterval(1), allowsPush: false, execution: last.execution,
            taskPrompt: last.taskPrompt, mergeRequestURL: last.mergeRequestURL, workflow: last.workflow,
            retryOf: first.id, automaticRetryIdentity: lastIdentity)
        let firstReceipt = AssistantAutomaticRetryAttempt(id: firstIdentity.reservationID, rootID: f.original.id,
            parentJobID: f.original.id, target: f.target, family: "review", attempt: 1, reservedAt: f.date,
            state: .started, replacementJobID: first.id)
        let lastReceipt = AssistantAutomaticRetryAttempt(id: lastIdentity.reservationID, rootID: f.original.id,
            parentJobID: first.id, target: f.target, family: "review", attempt: 2, reservedAt: f.date,
            state: .started, replacementJobID: last.id)
        f.settings.assistantHandoffs += [first, last]
        f.settings.assistantAutomaticRetryAttempts = [lastReceipt, firstReceipt]
        f.settings.save()
        var linkedJob = f.original.id
        let coordinator = f.coordinator(onAdopt: { parent, child in
            if linkedJob == parent { linkedJob = child.id }
        })
        defer { coordinator.cancel() }

        coordinator.recoverUnfinishedAdmissions()
        try await f.settle(coordinator)

        #expect(linkedJob == last.id && f.launches == 0)
    }

    @Test func explicitCancellationAndPersistenceFailureRemainStopped() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.settings.assistantHandoffs[0].execution?.state = .cancelled
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0)
        f.settings.assistantHandoffs[0].execution?.state = .failed
        f.settings.recordPersistenceFailure("retry-fixture")
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
    }

    @Test func aFailureAfterCreatingTheChildCannotReplayItsParentAdmission() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.result = .throwAfterStarted
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1)
        #expect(f.settings.assistantAutomaticRetryAttempts.first?.state == .started)
        #expect(f.settings.assistantAutomaticRetryAttempts.first?.replacementJobID == f.settings.assistantHandoffs.last?.id)
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1)
    }

    @Test func policyCancellationUsesTheSameBudgetAfterPermissionsReturn() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.settings.assistantHandoffs[0].execution?.state = .cancelled
        f.settings.assistantHandoffs[0].execution?.cancellationOrigin = .policy
        f.allowed = false
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
        f.allowed = true
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1 && f.settings.assistantAutomaticRetryAttempts.first?.attempt == 1)
    }

    @Test func explicitStopRemainsStoppedWhenShutdownRecordsAnInterruption() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.settings.assistantHandoffs[0].execution?.state = .interrupted
        f.settings.assistantHandoffs[0].execution?.cancellationOrigin = .user
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 0 && f.settings.assistantAutomaticRetryAttempts.isEmpty)
    }

    @Test func aLaterUnrelatedDiagnosisDoesNotRetirePipelineWork() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        var pipeline = f.original
        pipeline.taskIntent = .pipelineDiagnosis
        f.settings.assistantHandoffs = [pipeline]
        let later = AssistantAutomationRunner.Handoff(id: UUID(), key: pipeline.key, title: "Review complete",
            prompt: "Review", createdAt: f.finished.addingTimeInterval(1), allowsPush: false,
            execution: .init(state: .succeeded, finishedAt: f.finished.addingTimeInterval(2)),
            taskPrompt: "Review", mergeRequestURL: pipeline.mergeRequestURL, workflow: .review)
        f.settings.assistantHandoffs.append(later)
        let coordinator = f.coordinator()
        defer { coordinator.cancel() }
        coordinator.wake()
        try await f.settle(coordinator)
        #expect(f.launches == 1)
        #expect(f.settings.assistantHandoffs.last?.retryOf == pipeline.id)
    }

    @Test func missingLedgerCannotResetTheBudgetAfterFailedPreflightWithoutAChild() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.date = f.finished.addingTimeInterval(100)
        f.result = .failed
        let first = f.coordinator()
        first.wake()
        try await f.settle(first)
        first.cancel()
        #expect(f.settings.assistantHandoffs.first?.automaticRetryIdentity?.attempt == 1)
        f.settings.assistantAutomaticRetryAttempts = []
        f.settings.save()
        f.date = f.date.addingTimeInterval(1_000)
        let reloaded = SettingsManager(defaults: f.defaults)
        let restarted = f.coordinator(settings: reloaded)
        defer { restarted.cancel() }
        restarted.wake()
        try await f.settle(restarted)
        #expect(f.launches == 1 && reloaded.assistantAutomaticRetryAttempts.isEmpty)
    }

    @MainActor private final class Fixture {
        enum Result: Equatable { case started, deferred, failed, throwAfterStarted }
        let suite = "AssistantAutomaticRetryCoordinatorTests.\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsManager
        let finished = Date(timeIntervalSince1970: 1_000)
        var date = Date(timeIntervalSince1970: 1_000)
        let target = AssistantAutomaticRetryTarget(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let original: AssistantAutomationRunner.Handoff
        var launches = 0
        var allowed = true
        var sawDurableReservation = false
        var result = Result.started
        var hold = false
        var gate: CheckedContinuation<Void, Never>?

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            original = .init(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Review", prompt: "Review", createdAt: finished.addingTimeInterval(-1), allowsPush: false,
                execution: .init(state: .failed, finishedAt: finished), taskPrompt: "Review",
                mergeRequestURL: URL(string: "https://gitlab.example.test/g/p/-/merge_requests/2"), workflow: .review)
            settings.assistantHandoffs = [original]
            settings.save()
        }

        func coordinator(settings supplied: SettingsManager? = nil,
                         onAdopt: @escaping @MainActor (UUID, AssistantAutomationRunner.Handoff) -> Void = { _, _ in }) -> AssistantAutomaticRetryCoordinator {
            let current = supplied ?? settings
            return .init(settings: current, now: { [self] in date },
                wait: { _ in try await Task.sleep(for: .seconds(3_600)) }, onAdopt: onAdopt, canRetry: { [self] _ in allowed },
                launch: { [self] job, identity in
                    launches += 1
                    sawDurableReservation = SettingsManager(defaults: defaults).assistantAutomaticRetryAttempts.contains {
                        $0.identity == identity && $0.state == .reserved
                    }
                    if hold { await withCheckedContinuation { gate = $0 } }
                    switch result {
                    case .deferred: return .deferred
                    case .failed: return .failed("Synthetic preflight failure")
                    case .started, .throwAfterStarted:
                        let replacement = child(of: job, identity: identity)
                        current.assistantHandoffs.append(replacement); current.save()
                        if result == .throwAfterStarted { throw GlabError.timedOut }
                        return .started(replacement)
                    }
                })
        }

        func child(of job: AssistantAutomationRunner.Handoff,
                   identity: AssistantAutomaticRetryIdentity) -> AssistantAutomationRunner.Handoff {
            .init(id: UUID(), key: job.key, title: "Retry", prompt: "Reconcile existing work", createdAt: date,
                allowsPush: job.allowsPush, execution: .init(state: .queued), taskPrompt: job.taskPrompt,
                mergeRequestURL: job.mergeRequestURL, workflow: job.workflow, manual: false,
                retryOf: job.id, automaticRetryIdentity: identity, taskIntent: job.taskIntent)
        }
        func release() { hold = false; gate?.resume(); gate = nil }
        func clean() { release(); defaults.removePersistentDomain(forName: suite) }
        func waitForLaunch() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while gate == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(gate != nil)
        }
        func settle(_ coordinator: AssistantAutomaticRetryCoordinator) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while coordinator.isProcessing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(!coordinator.isProcessing)
        }
    }
}
