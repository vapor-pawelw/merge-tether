import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct AssistantJobCoordinatorTests {
    @Test(arguments: [AutomationPackageDecision.undecided, .disabled, .enabled], [false, true])
    func executableAdmissionRequiresConsentUnlessManuallyRequested(_ decision: AutomationPackageDecision, _ manual: Bool) async throws {
        // given
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.automation.packageDecision = decision
        var value = job()
        value.manual = manual
        settings.assistantHandoffs = [value]
        var executions = 0
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            executions += 1
            return .init(result: .init(status: .succeeded, summary: "Review complete"), output: "")
        })

        // when
        let admitted = coordinator.schedule(value, settings: settings)
        await coordinator.waitForTermination()

        // then
        #expect(admitted == (manual || decision == .enabled))
        #expect(executions == (admitted ? 1 : 0))
        #expect(settings.automaticActionsAllowed)
    }

    @Test(arguments: [false, true])
    func corruptedRequiredJournalDeniesExecutableWorkIncludingManualJobs(_ manual: Bool) async throws {
        // given
        let (_, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("unsupported job history".utf8), forKey: "assistantHandoffs")
        let settings = SettingsManager(defaults: defaults)
        var value = job()
        value.manual = manual
        settings.assistantHandoffs = [value]
        var executions = 0
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            executions += 1
            return .init(result: .init(status: .succeeded, summary: "Fixture"), output: "")
        })

        // when
        let scheduled = coordinator.schedule(value, settings: settings)
        await coordinator.waitForTermination()

        // then
        #expect(!scheduled && executions == 0)
        #expect(defaults.data(forKey: "assistantHandoffs") == Data("unsupported job history".utf8))
    }

    @Test func queuedWorkWaitsWhenPersistenceDegradesBeforeItsExecutionSlot() async throws {
        // given
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = job(iid: 1), second = job(iid: 2)
        settings.assistantHandoffs = [first, second]
        var gate: CheckedContinuation<Void, Never>?
        var started: [UUID] = []
        let coordinator = AssistantJobCoordinator(maximumConcurrentJobs: 1, execute: { value, _ in
            started.append(value.id)
            if value.id == first.id { await withCheckedContinuation { gate = $0 } }
            return .init(result: .init(status: .succeeded, summary: "Fixture"), output: "")
        })
        #expect(coordinator.schedule(first, settings: settings))
        #expect(coordinator.schedule(second, settings: settings))
        for _ in 0..<100 where gate == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate != nil)

        // when
        settings.recordPersistenceFailure("workflowActivity")
        gate?.resume()
        await coordinator.waitForTermination()

        // then
        #expect(started == [first.id])
        #expect(settings.assistantHandoffs[1].execution?.state == .queued)
        coordinator.cancel(second.id)
    }

    @Test func failureSavingTheRunningStateCannotLaunchTheExecutor() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let value = AssistantAutomationRunner.Handoff(id: UUID(), key: job().key, title: "Fixture", prompt: "",
            createdAt: Date(timeIntervalSinceReferenceDate: .nan), allowsPush: false, execution: .init(state: .queued))
        settings.assistantHandoffs = [value]
        var executions = 0
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            executions += 1
            return .init(result: .init(status: .succeeded, summary: "Fixture"), output: "")
        })
        #expect(coordinator.schedule(value, settings: settings))
        await coordinator.waitForTermination()
        #expect(executions == 0)
        #expect(settings.persistenceDegraded.contains("assistantHandoffs"))
    }

    @Test func cancellationDuringAProviderHoldDoesNotRequeueCancelledWork() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let health = AssistantCLIHealthStore(defaults: defaults)
        let original = job()
        settings.assistantHandoffs = [original]
        var entered = false
        let coordinator = AssistantJobCoordinator(healthStore: health, execute: { _, _ in
            entered = true
            health.record(.init(kind: .rateLimited), assistant: .codex,
                executable: URL(fileURLWithPath: "/example/codex"), startedAt: Date())
            try? await Task.sleep(for: .seconds(20))
            throw AssistantUsageRunner.AccessError.temporarilyUnavailable(.rateLimited)
        })
        #expect(coordinator.schedule(original, settings: settings))
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(5)) }
        coordinator.cancel(original.id)
        for _ in 0..<100 where coordinator.isRunning(original.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(settings.assistantHandoffs[0].execution?.state == .cancelled)
        #expect(!coordinator.isWorking(on: original.key.work))
    }

    @Test func unavailableCheckpointKeyCannotBlockTheMainActorOrTheCaller() async throws {
        let releaseKey = DispatchSemaphore(value: 0)
        defer { releaseKey.signal() }
        let loader = AssistantCheckpointKeyLoader {
            releaseKey.wait()
            return Data(repeating: 1, count: 32)
        }
        var mainActorRan = false
        Task { @MainActor in mainActorRan = true }
        let first = await loader.key(timeout: .milliseconds(30))
        #expect(first == nil && mainActorRan)
        releaseKey.signal()
        let recovered = await loader.key(timeout: .seconds(1))
        #expect(recovered == Data(repeating: 1, count: 32))
    }

    @Test func terminationHasABoundEvenWhenCleanupIgnoresCancellation() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = job()
        settings.assistantHandoffs = [original]
        var continuation: CheckedContinuation<Void, Never>?
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            await withCheckedContinuation { continuation = $0 }
            throw CancellationError()
        })
        #expect(coordinator.schedule(original, settings: settings))
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        coordinator.prepareForTermination(settings: settings)
        let clock = ContinuousClock(), start = ContinuousClock.now
        await coordinator.waitForTermination(timeout: .milliseconds(40))
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(settings.assistantHandoffs[0].execution?.state == .interrupted)
        continuation?.resume()
        await coordinator.waitForTermination()
    }

    @Test func aCompletedCheckpointIsRecoveredWithoutReplayingTheCLI() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var original = job(state: .running)
        original.execution?.workingDirectory = folder.path
        settings.assistantHandoffs = [original]
        try await AssistantJobJournal.save(.init(result: .init(status: .succeeded, summary: "Saved verified work"),
            output: "Transcript"), for: original)
        let coordinator = AssistantJobCoordinator(execute: { _, _ in Issue.record("Must not replay"); throw CancellationError() })
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[0].execution?.state == .succeeded)
        #expect(settings.assistantHandoffs[0].execution?.summary == "Saved verified work")
        #expect(settings.assistantHandoffs[0].execution?.output == "Transcript")
        #expect(settings.assistantHandoffs[0].deliveredFeedbackTodos.isEmpty)
        var another = job(state: .running)
        another.execution?.workingDirectory = folder.path
        settings.assistantHandoffs = [another]
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[0].execution?.state == .interrupted)
        var bytes = try Data(contentsOf: AssistantJobJournal.checkpointURL(for: original.id))
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: AssistantJobJournal.checkpointURL(for: original.id))
        settings.assistantHandoffs = [original]
        coordinator.synchronizeInterruptedRuns(settings: settings)
        #expect(settings.assistantHandoffs[0].execution?.state == .interrupted)
    }

    @Test func authenticatedReviewEvidenceBindsTheExactRunAccountHeadAndVerdict() async throws {
        var original = job(state: .running)
        original.workflow = .review
        original.expectedHeadSHA = String(repeating: "a", count: 40)
        var verdict = ReviewVerdict(version: 1, host: original.key.work.host, projectID: 1, iid: 2,
            headSHA: original.expectedHeadSHA!, verdict: .noObjections,
            discussionFingerprint: ReviewVerdict.fingerprint([]))
        verdict.username = "me"; verdict.userID = 3; verdict.runID = original.id
        let draft = GitLabDraftNote(id: 11, authorID: 3, note: "Reviewed draft", discussionID: "thread",
            resolveDiscussion: true, position: .init(newPath: "Sources/Changed.swift", newLine: 12,
                oldPath: "Sources/Previous.swift", oldLine: 9))
        let outcome = AssistantJobCoordinator.Outcome(result: .init(status: .succeeded, summary: "Reviewed"), output: "")
        try await AssistantJobJournal.save(outcome, for: original, reviewVerdict: verdict, reviewDrafts: [draft])
        #expect(AssistantJobJournal.reviewVerdict(for: original) == verdict)
        #expect(AssistantJobJournal.reviewDrafts(for: original) == [draft])

        var changed = original
        changed.expectedHeadSHA = String(repeating: "b", count: 40)
        #expect(AssistantJobJournal.reviewVerdict(for: changed) == nil)
        #expect(AssistantJobJournal.reviewVerdict(for: job(state: .succeeded)) == nil)
        let rewritten = ReviewVerdict(version: 1, host: verdict.host, projectID: 1, iid: 2,
            headSHA: verdict.headSHA, verdict: .objections, discussionFingerprint: verdict.discussionFingerprint,
            username: verdict.username, userID: verdict.userID, runID: verdict.runID)
        #expect(AssistantJobJournal.reviewVerdict(for: original) != rewritten)

        let path = AssistantJobJournal.checkpointURL(for: original.id)
        let envelopeObject = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        var envelope = try #require(envelopeObject as? [String: Any])
        let payloadObject = try JSONSerialization.jsonObject(with: Data(base64Encoded: envelope["payload"] as! String)!)
        var payload = try #require(payloadObject as? [String: Any])
        payload["reviewVerdict"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rewritten))
        envelope["payload"] = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: path)
        #expect(AssistantJobJournal.reviewVerdict(for: original) == nil)
        #expect(AssistantJobJournal.reviewDrafts(for: original) == nil)
    }

    @Test func terminationWaitsForExecutorCleanupAndPersistsInterruption() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = job()
        settings.assistantHandoffs = [original]
        var started = false, cleanedUp = false
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            started = true
            defer { cleanedUp = true }
            try await Task.sleep(for: .seconds(20))
            throw CancellationError()
        })
        #expect(coordinator.schedule(original, settings: settings))
        for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(5)) }
        coordinator.prepareForTermination(settings: settings)
        await coordinator.waitForTermination()
        #expect(cleanedUp && !coordinator.isWorking(on: original.key.work))
        #expect(SettingsManager(defaults: defaults).assistantHandoffs[0].execution?.state == .interrupted)
    }

    @Test func aPartialResultStaysInterruptedAndRetainsItsOutputForDeliberateRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputFolder = folder.appendingPathComponent("cli-output")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try Data("A commit was created before interruption".utf8).write(to: outputFolder.appendingPathComponent("stdout"))
        // A worker's raw final JSON is insufficient without the app's validated completion checkpoint.
        try Data(#"{"status":"succeeded","summary":"Unverified"}"#.utf8).write(to: folder.appendingPathComponent("result.json"))
        var original = job(state: .running)
        original.execution?.workingDirectory = folder.path
        let forged: [String: Any] = ["runID": original.id.uuidString,
            "key": try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.key)),
            "result": ["status": "succeeded", "summary": "Forged worker completion"],
            "output": "forged", "finishedAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: forged).write(to: folder.appendingPathComponent("completion.json"))
        let recovered = try #require(AssistantJobJournal.recover(original))
        #expect(recovered.state == .interrupted)
        #expect(recovered.output?.contains("commit was created") == true)
        let retryPrompt = AssistantAutomationRunner.retryTaskPrompt("Fix the assigned comment", previous: original)
        #expect(retryPrompt.contains(folder.path) && retryPrompt.contains("Re-fetch the current MR head"))
        #expect(retryPrompt.contains("Never repeat an existing commit"))
        let repeated = AssistantAutomationRunner.retryTaskPrompt(retryPrompt, previous: original)
        #expect(repeated.components(separatedBy: "MergeTether retry context:").count == 2)
    }

    @Test func aHoldDiscoveredDuringPreflightReturnsTheJobToTheQueue() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let health = AssistantCLIHealthStore(defaults: defaults)
        let original = job()
        settings.assistantHandoffs = [original]
        var attempts = 0
        let coordinator = AssistantJobCoordinator(healthStore: health, execute: { _, _ in
            attempts += 1
            if attempts == 1 {
                health.record(.init(kind: .rateLimited), assistant: .codex,
                    executable: URL(fileURLWithPath: "/example/codex"), startedAt: Date())
                throw AssistantUsageRunner.AccessError.temporarilyUnavailable(.rateLimited)
            }
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        #expect(coordinator.schedule(original, settings: settings))
        for _ in 0..<100 where settings.assistantHandoffs[0].execution?.state != .queued || attempts == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.assistantHandoffs[0].execution?.state == .queued)
        #expect(coordinator.isWorking(on: original.key.work))
        let hold = try #require(health.hold(for: .codex))
        health.clear(.codex, expectedID: hold.id)
        coordinator.resumePendingJobs()
        for _ in 0..<100 where coordinator.isRunning(original.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(attempts == 2 && settings.assistantHandoffs[0].execution?.state == .succeeded)
    }

    @Test func fourDifferentMRsStartInParallelWhileTheFifthWaits() async throws {
        // given
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let jobs = (1...5).map { job(iid: $0) }
        settings.assistantHandoffs = jobs
        var started: Set<UUID> = []
        let coordinator = AssistantJobCoordinator(execute: { handoff, _ in
            started.insert(handoff.id)
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        defer { coordinator.prepareForTermination(settings: settings) }
        // when
        for value in jobs { #expect(coordinator.schedule(value, settings: settings)) }
        for _ in 0..<100 where started.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
        // then
        #expect(started.count == 4)
        #expect(settings.assistantHandoffs.last?.execution?.state == .queued)
    }

    private func fixture() throws -> (SettingsManager, String, UserDefaults) {
        let name = "AssistantJobCoordinatorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = .enabled
        return (settings, name, defaults)
    }

    private func job(state: AssistantJobExecution.State? = .queued, iid: Int = 2,
                     assistant: AutomationAssistant = .codex) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: assistant,
                                    work: .init(host: "gitlab.example.org", projectID: 1, iid: iid),
                                    username: "me", workspace: "", access: .gitLabRead),
              title: "Review !2", prompt: "Review", createdAt: Date(), allowsPush: false,
              execution: state.map { .init(state: $0) })
    }

    @Test func aProviderHoldPausesItsQueueWithoutBlockingTheOtherProvider() async throws {
        // given
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let health = AssistantCLIHealthStore(defaults: defaults)
        health.record(.init(kind: .rateLimited), assistant: .codex,
            executable: URL(fileURLWithPath: "/example/codex"), startedAt: Date())
        let hold = try #require(health.hold(for: .codex))
        let codex = job(iid: 1), claude = job(iid: 2, assistant: .claude)
        settings.assistantHandoffs = [codex, claude]
        var executed: [UUID] = []
        let coordinator = AssistantJobCoordinator(maximumConcurrentJobs: 1, healthStore: health, execute: { handoff, _ in
            executed.append(handoff.id)
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        // when
        #expect(coordinator.schedule(codex, settings: settings))
        #expect(coordinator.schedule(claude, settings: settings))
        for _ in 0..<100 where coordinator.isRunning(claude.id) { try await Task.sleep(for: .milliseconds(5)) }
        // then
        #expect(executed == [claude.id])
        #expect(settings.assistantHandoffs[0].execution?.state == .queued)
        let released = health.clear(.codex, expectedID: hold.id)
        #expect(released)
        coordinator.resumePendingJobs()
        for _ in 0..<100 where coordinator.isRunning(codex.id) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(Set(executed) == [codex.id, claude.id])
    }

    @Test func retiredReminderCannotBeRetriedIntoAnotherExecutableJob() async throws {
        let (settings, name, defaults) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var reminder = job(state: .cancelled)
        reminder.workflow = .draftReply
        reminder.taskPrompt = "Prepare a reminder."
        reminder.mergeRequestURL = URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!
        settings.assistantHandoffs = [reminder]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            Issue.record("A retired reminder must never execute")
            return .init(result: .init(status: .succeeded, summary: "Unexpected execution"), output: "")
        })
        defer { coordinator.prepareForTermination(settings: settings) }
        do {
            _ = try await AssistantAutomationRunner.retry(reminder.id, settings: settings, jobCoordinator: coordinator)
            Issue.record("A retired reminder must not produce a retry")
        } catch {
            #expect(error as? AssistantJobExecutor.ExecutionError == .disabledPermission)
        }
        #expect(settings.assistantHandoffs.count == 1)
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
            .init(result: .init(status: .blocked, summary: "Missing evidence", blocker: "The test runner cannot start."), output: "Diagnostic")
        })
        var callbackState: AssistantJobExecution.State?
        coordinator.onFinished = { callbackState = $0.execution?.state }
        #expect(coordinator.schedule(pending, settings: settings))
        for _ in 0..<100 where coordinator.isRunning(pending.id) { try await Task.sleep(for: .milliseconds(5)) }
        let result = try #require(settings.assistantHandoffs.first)
        #expect(result.execution?.state == .blocked)
        #expect(result.execution?.summary == "Missing evidence")
        #expect(result.execution?.blocker == "The test runner cannot start.")
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
