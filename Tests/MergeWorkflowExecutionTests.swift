import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct MergeWorkflowExecutionTests {
    @MainActor private final class ReadRetryClock { var date = Date() }

    @Test(arguments: ["cooldown", "dependency", "account-change"])
    func purePrelaunchFailurePreservesRestartAccountHeadAndRetryBoundaries(_ recovery: String) async throws {
        let suite = "WorkflowReadRetry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let original = try entry(jobID: nil)
        let request = original.event.mergeRequest
        let head = try #require(request.sha)
        let event = MergeWorkflowEvent(kind: .blockerChange, mergeRequest: request, identity: "read-retry", context: "Read-only admission")
        let encoder = JSONEncoder()
        let staleRequest = String(decoding: try encoder.encode(request), as: UTF8.self)
            .replacingOccurrences(of: head, with: String(repeating: "b", count: 40))
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.method != "GET" { gitlab.write("write"); return InMemoryGitLab.output(code: 9) }
            switch request.endpoint {
            case "/user":
                gitlab.append("reads", "x")
                return gitlab.has("available") ? InMemoryGitLab.output(#"{"id":1,"username":"me"}"#)
                    : InMemoryGitLab.output(error: "503 temporarily unavailable", code: 1)
            case "/projects/7/merge_requests/11": return InMemoryGitLab.output(staleRequest)
            default: return try gitlab.unexpected(request)
            }
        }
        let glab = gitlab.service(host: original.host, username: "me")
        let clock = ReadRetryClock()
        func make(_ state: SettingsManager) -> MergeWorkflowAutomation {
            MergeWorkflowAutomation(settings: state, glab: glab, notifications: NotificationService(),
                detector: .init(directory: directory.appending(path: "claims")),
                retryWait: { _ in
                    if recovery == "account-change" {
                        glab.currentUsername = "other-account"
                        glab.currentUsername = "me"
                    }
                    await Task.yield()
                }, now: { clock.date })
        }
        func settle(_ automation: MergeWorkflowAutomation) async throws {
            for _ in 0..<500 where automation.entries.first.map({ [.queued, .running].contains($0.state) }) == true {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func reads() -> String { gitlab.text("reads") }
        let automation = make(settings)
        automation.receive(event, host: original.host, user: original.user)
        automation.startNext()
        try await settle(automation)
        if recovery == "account-change" {
            #expect(reads() == "x")
            #expect(automation.entries.first?.state == .skipped)
            #expect(automation.entries.first?.isReadOnlyFailure == false)
            #expect(settings.assistantHandoffs.isEmpty && settings.pipelineRefreshAttempts.isEmpty)
            #expect(!gitlab.has("write"))
            return
        }
        #expect(reads() == "xxx")
        #expect(automation.entries.first?.isReadOnlyFailure == true)
        #expect(automation.hasReadOnlyFailure(for: request))
        let restoredSettings = SettingsManager(defaults: defaults)
        let restored = make(restoredSettings)
        #expect(restored.hasReadOnlyFailure(for: request))
        glab.currentUsername = "other-account"
        #expect(!restored.hasReadOnlyFailure(for: request))
        restored.startNext()
        #expect(reads() == "xxx")
        glab.currentUsername = "me"
        restored.startNext()
        #expect(reads() == "xxx")
        gitlab.write("available")
        if recovery == "cooldown" {
            clock.date = clock.date.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
            restored.startNext()
        } else { restored.retryReadOnlyFailures() }
        try await settle(restored)
        #expect(reads() == "xxxx")
        // The new source head invalidates this old event before any action can be entered.
        #expect(restored.entries.first?.state == .skipped)
        #expect(!restored.hasReadOnlyFailure(for: request))
        #expect(restoredSettings.assistantHandoffs.isEmpty && restoredSettings.pipelineRefreshAttempts.isEmpty)
        #expect(!gitlab.has("write"))
    }

    private func entry(jobID: UUID?) throws -> MergeWorkflowActivityEntry {
        let pipeline = jobID == nil ? 101 : 100
        let eventID = "pipeline:7:11:\(pipeline)"
        let object: [String: Any] = [
            "id": eventID, "createdAt": 0, "host": "gitlab.example.test",
            "user": ["id": 1, "username": "me"], "state": "waitingForAssistant",
            "assistantJobID": jobID?.uuidString as Any? ?? NSNull(),
            "event": ["kind": "pipelineFailure", "identity": eventID, "context": "Failed CI",
                      "pipelineID": pipeline, "noteIDs": [], "isInfrastructureFailure": false,
                      "mergeRequest": ["project_id": 7, "iid": 11,
                                       "author": ["id": 1, "username": "me", "name": "Me"],
                                       "title": "Example", "web_url": "https://gitlab.example.test/team/repo/-/merge_requests/11",
                                       "state": "opened", "draft": false, "sha": String(repeating: "a", count: 40),
                                       "source_branch": "feature", "target_branch": "main", "labels": []]]
        ]
        return try JSONDecoder().decode(MergeWorkflowActivityEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func workflowFollowsPersistedCLIExecutionAndKeepsDesktopHistoryUnverified() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let id = UUID()
        settings.workflowActivity = [try entry(jobID: id), try entry(jobID: nil)]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .running))]
        settings.save()
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        #expect(automation.entries[0].state == .running)
        #expect(automation.entries[1].state == .waitingForAssistant)
        settings.assistantHandoffs[0].execution = .init(state: .succeeded, summary: "Fix verified")
        settings.save()
        automation.synchronizeAssistantJobs()
        #expect(automation.entries[0].state == .completed)
        #expect(automation.entries[0].summary == "Fix verified")
        #expect(automation.entries[1].state == .waitingForAssistant)
        #expect(SettingsManager(defaults: defaults).workflowActivity[0].state == .waitingForAssistant)
    }

    @Test func linkedCompletionAppearsWithoutSynchronizationOrAnOutcomeMirror() throws {
        let suite = "WorkflowExecutionProjection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let id = UUID()
        let stored = try entry(jobID: id)
        settings.workflowActivity = [stored]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: stored.host, projectID: 7, iid: 11),
                username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .running))]
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: stored.host, username: "me")
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        #expect(automation.entries.first?.state == .running)
        #expect(settings.workflowActivity.first?.state == .waitingForAssistant)

        settings.assistantHandoffs[0].execution = .init(state: .succeeded, summary: "Verified run outcome")
        settings.save()

        #expect(automation.entries.first?.state == .completed)
        #expect(automation.entries.first?.summary == "Verified run outcome")
        #expect(settings.workflowActivity.first?.state == .waitingForAssistant)
        #expect(settings.workflowActivity.first?.summary == nil)
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.workflowActivity.first?.state == .waitingForAssistant)
        let restarted = MergeWorkflowAutomation(settings: restored, glab: glab, notifications: NotificationService())
        #expect(restarted.entries.first?.state == .completed)
    }

    @Test func aRetryLinkSurvivesAnUnrelatedAdmissionFailureAfterAwait() async throws {
        let suite = "WorkflowLiveMutation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let id = UUID()
        let stored = try entry(jobID: id)
        let request = stored.event.mergeRequest
        settings.workflowActivity = [stored]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: stored.host, projectID: 7, iid: 11),
                username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .failed), taskPrompt: "Review this source.",
            mergeRequestURL: request.webURL, workflow: .review, expectedHeadSHA: request.sha)]
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.write("hold-read")
        gitlab.handler = { call in
            guard call.endpoint == "/user", call.method == "GET" else { return try gitlab.unexpected(call) }
            try await gitlab.pause(ifPresent: "hold-read", entered: "read-started", until: "release-read")
            return InMemoryGitLab.output(error: "503 temporarily unavailable", code: 1)
        }
        let glab = gitlab.service(host: stored.host, username: "me")
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(), retryWait: { _ in })
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        automation.receive(.init(kind: .blockerChange, mergeRequest: request, identity: "unrelated-admission", context: "Read failure"),
            host: stored.host, user: stored.user)
        automation.startNext()
        try await gitlab.waitFor("read-started")
        let replacement = try await AssistantAutomationRunner.retry(id, settings: settings,
            expectedHeadSHA: request.sha, jobCoordinator: coordinator)
        defer { coordinator.cancel(replacement.id) }
        #expect(settings.workflowActivity.first { $0.id == stored.id }?.assistantJobID == replacement.id)
        gitlab.remove("hold-read")
        gitlab.write("release-read")
        let deadline = ContinuousClock.now + .seconds(5)
        while automation.entries.first(where: { $0.id == "unrelated-admission" })?.isReadOnlyFailure != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(automation.entries.first { $0.id == "unrelated-admission" }?.isReadOnlyFailure == true)
        #expect(settings.workflowActivity.first { $0.id == stored.id }?.assistantJobID == replacement.id)
        #expect(automation.entries.first { $0.id == stored.id }?.assistantJobID == replacement.id)
        #expect(SettingsManager(defaults: defaults).workflowActivity.first { $0.id == stored.id }?.assistantJobID == replacement.id)
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        coordinator.cancel(replacement.id)
        while coordinator.isRunning(replacement.id), ContinuousClock.now < deadline { await Task.yield() }
    }

    @Test(arguments: [MergeWorkflowActivityState.queued, .running])
    func restoredAdmissionIsDurablySkippedWithoutDispatch(_ state: MergeWorkflowActivityState) throws {
        let suite = "WorkflowStartupAdmission.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        var stored = try entry(jobID: nil)
        stored.state = state
        settings.workflowActivity = [stored]
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: stored.host, username: "me")
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        automation.startNext()
        #expect(automation.entries.first?.state == .skipped)
        #expect(SettingsManager(defaults: defaults).workflowActivity.first?.state == .skipped)
        #expect(settings.assistantHandoffs.isEmpty && gitlab.requests.isEmpty)
    }

    @Test(arguments: [MergeWorkflowActivityState.waitingForAssistant, .running], ["missing", "mismatched", "terminal"])
    func claimLineageIsPrunedOnlyForVerifiedTerminalExecution(_ state: MergeWorkflowActivityState, execution: String) throws {
        let suite = "WorkflowUnavailableLineage.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.workflowRules[.reviewWaiting].mode = .notify
        var parent = try entry(jobID: nil)
        parent.state = .skipped
        let id = UUID()
        var assessment = try entry(jobID: id)
        assessment.state = state
        assessment.pipelineClaimAssessment = .init(skippedActivityID: parent.id, skippedCreatedAt: parent.createdAt)
        settings.workflowActivity = [assessment, parent]
        if execution != "missing" {
            settings.assistantHandoffs = [.init(id: id,
                key: .init(assistant: .codex, work: .init(host: parent.host, projectID: 7, iid: 11),
                    username: execution == "mismatched" ? "other" : "me", workspace: "", access: .gitLabRead),
                title: "History", prompt: "History", createdAt: Date(), allowsPush: false,
                execution: .init(state: .succeeded, summary: "Terminal run outcome"))]
        }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: parent.host, username: "me")
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        for index in 0..<125 {
            automation.receive(.init(kind: .reviewWaiting, mergeRequest: parent.event.mergeRequest,
                identity: "passive-\(index)", context: "History"), host: parent.host, user: parent.user)
        }
        let protected = execution != "terminal"
        #expect(settings.workflowActivity.count == 120)
        #expect(settings.workflowActivity.contains { $0.id == assessment.id && $0.assistantJobID == id } == protected)
        #expect(settings.workflowActivity.contains { $0.id == parent.id } == protected)
        if protected { #expect(automation.entries.first { $0.id == assessment.id }?.state == .skipped) }
        let restored = SettingsManager(defaults: defaults)
        let restarted = MergeWorkflowAutomation(settings: restored, glab: glab, notifications: NotificationService())
        restarted.startNext()
        #expect(restored.workflowActivity.contains { $0.id == assessment.id && $0.pipelineClaimAssessment?.skippedActivityID == parent.id } == protected)
        #expect(restored.workflowActivity.contains { $0.id == parent.id } == protected)
        #expect(restored.assistantHandoffs.map(\.id) == (execution == "missing" ? [] : [id]))
        #expect(gitlab.requests.isEmpty)
    }

    @Test func interruptedLinkedRunIsFailedRatherThanCompletedOrAutomaticallyQueued() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let id = UUID()
        settings.workflowActivity = [try entry(jobID: id)]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .claude, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .interrupted))]
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        #expect(automation.entries[0].state == .failed)
        #expect(settings.assistantHandoffs.count == 1)
    }
    @Test(arguments: [false, true])
    func explicitRetryPreservesEveryFeedbackTodoAndRelinksWorkflowHistory(originallyManual: Bool) async throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let id = UUID()
        let url = try #require(URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11"))
        let feedback = [1, 2].map {
            Todo.FeedbackIdentity(id: $0, targetURL: url, actorID: 3, action: .mentioned,
                                  createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil)
        }
        settings.workflowActivity = [try entry(jobID: id)]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, feedbackTodos: feedback, execution: .init(state: .failed),
            taskPrompt: "Expected head: old\nReview the feedback.", mergeRequestURL: url, workflow: .review,
            manual: originallyManual, expectedHeadSHA: "old")]
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        let retry = try await AssistantAutomationRunner.retry(id, settings: settings, expectedHeadSHA: "new", jobCoordinator: coordinator)
        #expect(retry.id != id)
        #expect(retry.manual == true)
        #expect(retry.expectedHeadSHA == "new")
        #expect(retry.prompt.contains("Expected head: new"))
        #expect(!retry.prompt.contains("Expected head: old"))
        #expect(Set(retry.feedbackTodos ?? []) == Set(feedback))
        #expect(settings.workflowActivity[0].assistantJobID == retry.id)
        automation.synchronizeAssistantJobs()
        #expect(automation.entries[0].assistantJobID == retry.id)
        #expect(automation.entries[0].state == .waitingForAssistant || automation.entries[0].state == .running)
        coordinator.cancel(retry.id)
        for _ in 0..<100 where coordinator.isRunning(retry.id) { try await Task.sleep(for: .milliseconds(5)) }
    }


    @Test func fullProfileQueuesUnclaimedPipelineWithoutAnOwnershipCheckpoint() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(),
                                                detector: .init(directory: root))
        let pending = try entry(jobID: nil)
        automation.receive(pending.event, host: pending.host, user: pending.user)
        #expect(automation.entries.first?.state == .queued)
        #expect(automation.pendingPipelineHandoffs.isEmpty)
    }

    @Test func fullProfileReconsidersRestoredOwnershipCheckpointAfterAuthenticatedObservation() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        var pending = try entry(jobID: nil)
        pending.state = .awaitingPipelineHandoff
        settings.workflowActivity = [pending]
        let glab = GlabService()
        glab.resolvedHost = pending.host
        glab.currentUsername = pending.user.username
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(),
                                                detector: .init(directory: directory))
        automation.observe([pending.event.mergeRequest], host: pending.host, user: pending.user)
        #expect(automation.entries.first?.state == .queued)
        #expect(automation.pendingPipelineHandoffs.isEmpty)
    }

    @Test func fullProfileKeepsAnExternalPipelineReservationRegistered() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let pending = try entry(jobID: nil)
        let glab = GlabService()
        glab.resolvedHost = pending.host
        glab.currentUsername = pending.user.username
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detector = ExistingPipelineWorkDetector(directory: directory)
        let claim = try detector.externalRegistrationURL(for: .init(host: pending.host, projectID: 7,
                                                                  mergeRequestIID: 11, pipelineID: 101))
        try FileManager.default.createDirectory(at: claim, withIntermediateDirectories: true)
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(), detector: detector)
        automation.receive(pending.event, host: pending.host, user: pending.user)
        #expect(automation.entries.first?.state == .alreadyRegistered)
        #expect(settings.assistantHandoffs.isEmpty)
    }

    @Test(arguments: ["none", "receipt", "active", "linked-missing", "linked-failed", "linked-interrupted",
                      "linked-completed", "unlinked-pipeline-job", "routed-linked-job", "refresh-attempt", "chat", "summary", "stale-head",
                      "different-pipeline", "successful-pipeline", "wrong-account", "checkpoints", "paused", "failed-entry"])
    func fullProfileReconsidersOnlyCurrentSkippedPipelineWorkWithoutRecordedEffects(blocker: String) async throws {
        try await exerciseSkippedPipeline(blocker: blocker)
    }

    @Test(arguments: ["none", "active", "linked-missing", "linked-failed", "linked-interrupted", "linked-completed",
                      "unlinked-pipeline-job", "routed-linked-job", "refresh-attempt", "chat", "summary", "stale-head",
                      "different-pipeline", "successful-pipeline", "wrong-account", "checkpoints", "paused", "failed-entry",
                      "package-disabled", "ignored", "nonempty-receipt", "prior-assessment"])
    func anOrphanedReceiptAllowsOnlyOneSeparateCurrentAssessmentWithoutReplayingKnownWork(blocker: String) async throws {
        try await exerciseSkippedPipeline(blocker: blocker, seedReceipt: true)
    }

    @Test(arguments: [false, true])
    func aPausedDraftPipelineBecomingReadyReconsidersOnlyItsEffectFreeWork(_ priorReceipt: Bool) async throws {
        try await exerciseSkippedPipeline(blocker: "draft-became-ready", seedReceipt: priorReceipt)
    }

    private func exerciseSkippedPipeline(blocker: String, seedReceipt: Bool = false) async throws {
        let suite = "MergeWorkflowSkippedPipeline.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(blocker == "checkpoints" ? .checkpoints : .full, for: .codex)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detector = ExistingPipelineWorkDetector(directory: directory)
        var stored = try entry(jobID: nil)
        stored.state = blocker == "failed-entry" ? .failed : .skipped
        if blocker == "draft-became-ready" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
            var event = try #require(object["event"] as? [String: Any])
            var request = try #require(event["mergeRequest"] as? [String: Any])
            request["draft"] = true
            event["mergeRequest"] = request
            object["event"] = event
            stored = try JSONDecoder().decode(MergeWorkflowActivityEntry.self, from: JSONSerialization.data(withJSONObject: object))
        }
        if blocker == "summary" { stored.summary = "An earlier outcome is uncertain." }
        if blocker == "chat" { stored.chatURL = URL(string: "https://example.test/existing-session") }
        let key = ExistingPipelineWorkDetector.Key(host: stored.host, projectID: 7, mergeRequestIID: 11, pipelineID: 101)
        if blocker == "receipt" || seedReceipt {
            let reserved = try detector.registerRun(for: key)
            let owned = try #require(reserved)
            try detector.finishHandoff(for: owned)
        }
        if blocker == "active" {
            try FileManager.default.createDirectory(at: detector.externalRegistrationURL(for: key), withIntermediateDirectories: true)
        }
        if blocker == "nonempty-receipt" {
            let receipt = try detector.externalRegistrationURL(for: key).deletingLastPathComponent().appending(path: "pipeline-101")
            try Data("Unverified prior evidence".utf8).write(to: receipt.appending(path: "evidence"))
        }
        let jobID = UUID()
        if blocker.hasPrefix("linked-") { stored.assistantJobID = jobID }
        if ["linked-failed", "linked-interrupted", "linked-completed", "unlinked-pipeline-job"].contains(blocker) {
            let state: AssistantJobExecution.State = blocker == "linked-interrupted" ? .interrupted
                : blocker == "linked-completed" ? .succeeded : .failed
            settings.assistantHandoffs = [.init(id: jobID,
                key: .init(assistant: .codex, work: .init(host: stored.host, projectID: 7, iid: 11),
                           username: "me", workspace: "", access: .configuredTools), title: "CI work", prompt: "CI work",
                createdAt: Date(), allowsPush: false, pipelineReservation: key, execution: .init(state: state), workflow: .followUp)]
        }
        if blocker == "refresh-attempt" {
            settings.pipelineRefreshAttempts.insert(.init(
                target: .init(host: stored.host, username: "me", projectID: 7, iid: 11), userID: 1,
                oldPipelineID: 101, sourceProjectID: 7, sourceBranch: "feature", sourceSHA: String(repeating: "a", count: 40),
                targetProjectID: 7, targetBranch: "main", targetSHA: String(repeating: "b", count: 40)))
        }
        if blocker == "paused" {
            settings.automation.scope[.init(host: stored.host, username: "me", projectID: 7, iid: 11)] = .paused
        }
        if blocker == "package-disabled" { settings.automation.packageDecision = .disabled }
        if blocker == "ignored" { settings.ignoredMergeRequests.insert(.init(host: stored.host, username: "me", projectID: 7, iid: 11)) }
        if blocker == "prior-assessment" {
            settings.pipelineClaimAssessmentAttempts = [.init(
                target: .init(host: stored.host, username: "me", projectID: 7, iid: 11), userID: 1,
                lineage: .init(skippedActivityID: stored.id, skippedCreatedAt: stored.createdAt), assessmentActivityID: "prior",
                sourceProjectID: 7, sourceBranch: "feature", sourceSHA: String(repeating: "a", count: 40),
                targetProjectID: 7, targetBranch: "main", targetSHA: String(repeating: "b", count: 40), pipelineProjectID: 7,
                pipelineID: 101, pipelineSHA: String(repeating: "c", count: 40), createdAt: Date())]
        }
        settings.workflowActivity = [stored]
        settings.save()
        var currentObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored.event.mergeRequest)) as? [String: Any])
        currentObject["sha"] = String(repeating: blocker == "stale-head" ? "b" : "a", count: 40)
        if blocker == "draft-became-ready" { currentObject["draft"] = false }
        currentObject["head_pipeline"] = ["id": blocker == "different-pipeline" ? 102 : 101, "project_id": 7,
                                          "status": blocker == "successful-pipeline" ? "success" : "failed",
                                          "sha": String(repeating: seedReceipt ? "c" : "a", count: 40),
                                          "ref": seedReceipt ? "refs/merge-requests/11/merge" : "feature"]
        if seedReceipt {
            currentObject["source_project_id"] = 7
            currentObject["target_project_id"] = 7
            currentObject["draft"] = false
            currentObject["has_conflicts"] = false
        }
        let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: currentObject))
        if blocker == "routed-linked-job" {
            settings.mrActionIntents = [.init(id: UUID(),
                target: .init(host: stored.host, username: "me", projectID: 7, iid: 11), kind: .pipeline, state: .failed,
                todoIDs: [], noteIDs: [], sourceEvents: [], request: current, headSHA: current.sha ?? "",
                jobID: jobID, updatedAt: Date())]
            settings.save()
        }
        let glab = GlabService()
        glab.resolvedHost = stored.host
        glab.currentUsername = stored.user.username
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(), detector: detector)
        let user = GitLabAuthenticatedUser(id: blocker == "wrong-account" ? 2 : 1, username: "me")
        automation.observe([current], host: stored.host, user: user)
        let resumable = blocker == "none" || blocker == "draft-became-ready"
        let freshAssessment = seedReceipt && resumable || blocker == "receipt"
        if freshAssessment {
            #expect(automation.entries.first(where: { $0.id == stored.id })?.state == .skipped)
            let fresh = try #require(automation.entries.first { $0.id != stored.id })
            #expect(fresh.state == .queued)
            #expect(fresh.event.kind == .pipelineFailure)
            #expect(fresh.event.mergeRequest.sha == current.sha)
            #expect(fresh.assistantJobID == nil)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
            let lineage = try #require(encoded["pipelineClaimAssessment"] as? [String: Any])
            #expect(lineage["skippedActivityID"] as? String == stored.id)
            #expect(detector.status(for: key) == .registered)
            #expect(!detector.hasActiveReservation(for: key))
        } else if resumable {
            #expect(automation.entries.first?.state == .queued)
            #expect(automation.entries.first?.event.mergeRequest.draft == false)
            #expect(automation.entries.first?.assistantJobID == nil)
            #expect(automation.isAutomaticallyProcessingPipeline(current))
            #expect(SettingsManager(defaults: defaults).workflowActivity.first?.state == .queued)
        } else {
            #expect(automation.entries.first?.state != .queued)
        }
        #expect(automation.entries.count == (freshAssessment ? 2 : 1))
        #expect(automation.entries.contains { $0.id == stored.id })
        #expect(settings.assistantHandoffs.count == (["linked-failed", "linked-interrupted", "linked-completed", "unlinked-pipeline-job"].contains(blocker) ? 1 : 0))
        for _ in 0..<4 { await Task.yield() }
        if freshAssessment {
            let restored = SettingsManager(defaults: defaults)
            let restarted = MergeWorkflowAutomation(settings: restored, glab: glab, notifications: NotificationService(), detector: detector)
            restarted.observe([current], host: stored.host, user: user)
            #expect(restarted.entries.count == 2)
            #expect(restarted.entries.first(where: { $0.id == stored.id })?.state == .skipped)
            #expect(detector.status(for: key) == .registered)
            for _ in 0..<4 { await Task.yield() }
        }
    }

    @Test(arguments: ["none", "unrelated-scope", "pause", "permission", "capacity"])
    func orphanedClaimDispatchUsesFreshProofAndOneDurableAssessment(mutation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PipelineClaimAssessment.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let source = String(repeating: "a", count: 40), target = String(repeating: "b", count: 40)
        let merged = String(repeating: "c", count: 40)
        let request = """
        {"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},"title":"Fixture",
        "web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened","draft":false,"has_conflicts":false,
        "sha":"\(source)","source_project_id":7,"source_branch":"feature","target_project_id":7,"target_branch":"main","labels":[],
        "head_pipeline":{"id":101,"project_id":7,"status":"failed","sha":"\(merged)","ref":"refs/merge-requests/11/merge"}}
        """
        let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
        let id = "\(host)|1|pipelineFailure|7!11|101"
        let event = MergeWorkflowEvent(kind: .pipelineFailure, mergeRequest: current, identity: id,
            context: "OLD-FIX-COMMAND-MUST-NOT-BE-REPLAYED", pipelineProjectID: 7, pipelineID: 101)
        let old = MergeWorkflowActivityEntry(id: id, event: event, createdAt: Date(timeIntervalSince1970: 0),
                                            host: host, user: .init(id: 1, username: "me"), state: .skipped)
        settings.workflowActivity = [old]
        let detector = ExistingPipelineWorkDetector(directory: root.appending(path: "claims"))
        let key = ExistingPipelineWorkDetector.Key(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 101)
        let previous = try detector.registerRun(for: key)
        let priorToken = try #require(previous)
        try detector.finishHandoff(for: priorToken)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { call in
            gitlab.append("commands", call.command + "\n")
            if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            switch call.endpoint {
            case "/user": return InMemoryGitLab.output(#"{"id":1,"username":"me"}"#)
            case "/projects/7/merge_requests/11": return InMemoryGitLab.output(request)
            case "/projects/7/pipelines/101": return try InMemoryGitLab.json(["id": 101, "project_id": 7, "status": "failed", "sha": merged, "ref": "refs/merge-requests/11/merge"])
            case "/projects/7/repository/branches/feature": return try InMemoryGitLab.json(["commit": ["id": source]])
            case "/projects/7/repository/branches/main": return try InMemoryGitLab.json(["commit": ["id": target]])
            case let path where path.hasPrefix("/projects/7/repository/commits/"):
                return try InMemoryGitLab.json(["id": merged, "parent_ids": [target, source]])
            case let path where path.hasPrefix("/projects/7/merge_requests/11/diffs?"):
                gitlab.write("entered")
                if mutation != "none" && mutation != "capacity" { try await gitlab.waitFor("release") }
                return InMemoryGitLab.output("[]")
            case "/projects/7": return InMemoryGitLab.output(#"{"default_branch":"main"}"#)
            case let path where path.hasPrefix("/projects/7/merge_trains?")
                || path.hasPrefix("/projects/7/pipelines/101/jobs?")
                || path.hasPrefix("/projects/7/merge_requests?")
                || path.hasPrefix("/merge_requests?scope=all")
                || path.contains("/discussions?") || path.contains("/blocks?") || path.contains("/reviewers?"):
                #expect(call.method == "GET")
                return InMemoryGitLab.output("[]")
            default: return try gitlab.unexpected(call)
            }
        }
        let glab = gitlab.service(host: host, username: "me")
        settings.glabPath = glab.glabPath
        settings.save()
        var launched: [AssistantAutomationRunner.Handoff] = []
        var releaseAssessment = false
        defer { releaseAssessment = true }
        let coordinator = AssistantJobCoordinator(execute: { handoff, _ in
            let durable = SettingsManager(defaults: defaults).pipelineClaimAssessmentAttempts
            #expect(durable.count == 1)
            #expect(durable.first?.sourceSHA == source && durable.first?.targetSHA == target)
            #expect(durable.first?.pipelineSHA == merged && durable.first?.lineage.skippedActivityID == id)
            #expect(handoff.pipelineReservation?.reservationID != priorToken.reservationID)
            #expect(handoff.expectedHeadSHA == source)
            #expect(handoff.prompt.lowercased().contains("reconcile"))
            #expect(handoff.prompt.lowercased().contains("do not replay"))
            #expect(!handoff.prompt.contains("OLD-FIX-COMMAND"))
            #expect(handoff.workflow == .followUp && handoff.followUpPushAllowed == true)
            #expect(handoff.prompt.contains("the separately assigned failed-pipeline diagnosis and fix"))
            #expect(handoff.prompt.contains("Do not perform a fresh general code review of my own MR"))
            #expect(handoff.prompt.contains("Do not create merge requests"))
            launched.append(handoff)
            while mutation == "capacity" && !releaseAssessment { try await Task.sleep(for: .milliseconds(10)) }
            return .init(result: .init(status: .blocked, summary: "Fresh assessment fixture finished.",
                                      blocker: "Fixture does not execute remote corrections."), output: "")
        })
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(),
                                                detector: detector, jobCoordinator: coordinator)
        coordinator.onFinished = { [weak automation] handoff in
            if let reservation = handoff.pipelineReservation { try? detector.finishHandoff(for: reservation) }
            automation?.synchronizeAssistantJobs()
        }
        automation.observe([current], host: host, user: old.user)
        for _ in 0..<300 {
            if gitlab.has("entered") { break }
            if automation.entries.contains(where: { $0.id != id && $0.state == .alreadyRegistered }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if ["unrelated-scope", "pause", "permission"].contains(mutation) {
            #expect(gitlab.has("entered"))
            if mutation == "unrelated-scope" {
                settings.automation.scope[.init(host: host, username: "me", projectID: 99, iid: 22)] = .active
            } else if mutation == "pause" {
                settings.automation.scope[.init(host: host, username: "me", projectID: 7, iid: 11)] = .paused
            } else { settings.automation.allowFollowUpPush = false }
            gitlab.write("release")
        }
        if mutation == "capacity" {
            for _ in 0..<300 where launched.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            let assessment = try #require(automation.entries.first { $0.pipelineClaimAssessment != nil })
            #expect(assessment.state == .running)
            #expect(settings.workflowActivity.first { $0.id == assessment.id }?.state == .waitingForAssistant)
            for index in 0..<130 {
                automation.receive(.init(kind: .reviewWaiting, mergeRequest: current, identity: "passive-\(index)",
                                         context: "Passive history fixture"), host: host, user: old.user)
            }
            #expect(automation.entries.contains { $0.id == assessment.id })
            #expect(automation.entries.contains { $0.id == id })
            releaseAssessment = true
        }
        for _ in 0..<300 where automation.entries.contains(where: { [.queued, .running, .waitingForAssistant].contains($0.state) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let shouldLaunch = mutation == "none" || mutation == "unrelated-scope" || mutation == "capacity"
        #expect(launched.count == (shouldLaunch ? 1 : 0))
        #expect(settings.pipelineClaimAssessmentAttempts.count == (shouldLaunch ? 1 : 0))
        #expect(automation.entries.first(where: { $0.id == id })?.state == .skipped)
        #expect(detector.hasEmptyPipelineReceipt(for: key))
        #expect(!detector.hasActiveReservation(for: key))
        let restored = SettingsManager(defaults: defaults)
        let restarted = MergeWorkflowAutomation(settings: restored, glab: glab, notifications: NotificationService(),
                                               detector: detector, jobCoordinator: coordinator)
        restarted.observe([current], host: host, user: old.user)
        for _ in 0..<4 { await Task.yield() }
        #expect(restarted.entries.count == (mutation == "capacity" ? 120 : 2))
        if mutation == "capacity" {
            #expect(restarted.entries.contains { $0.pipelineClaimAssessment?.skippedActivityID == id })
            #expect(restarted.entries.contains { $0.id == id })
        }
        #expect(launched.count == (shouldLaunch ? 1 : 0))
        let commands = gitlab.text("commands")
        #expect(!commands.contains("--method POST") && !commands.contains("--method PUT"))
    }

    private func waitingEntry(jobID: UUID?, state: MergeWorkflowActivityState) throws -> MergeWorkflowActivityEntry {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry(jobID: jobID))) as? [String: Any])
        var event = try #require(object["event"] as? [String: Any])
        event["kind"] = "reviewWaiting"
        event["identity"] = "review-waiting"
        event["context"] = "Review wait exceeded 48 hours"
        object["id"] = "review-waiting"
        object["event"] = event
        object["state"] = state.rawValue
        return try JSONDecoder().decode(MergeWorkflowActivityEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func legacyWaitingRuleRecordsOnlyLocalActivityAndNeverQueuesAWorker() throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.workflowRules[.reviewWaiting].mode = .assistant
        let glab = GlabService()
        glab.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        let pending = try waitingEntry(jobID: nil, state: .queued)
        automation.receive(pending.event, host: pending.host, user: pending.user)
        #expect(automation.entries.first?.state == .preview)
        automation.startNext()
        #expect(automation.entries.first?.state == .preview)
        #expect(settings.assistantHandoffs.isEmpty)
    }

    @Test(arguments: [false, true], [AssistantJobExecution.State.queued, .running, .interrupted])
    func restoredReminderIsIdentifiedWithoutResumingItsAgent(legacyUnlabeled: Bool, state: AssistantJobExecution.State) throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.workflowRules[.reviewWaiting].mode = .assistant
        let id = UUID()
        settings.workflowActivity = [try waitingEntry(jobID: id, state: .waitingForAssistant)]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Waiting for review", prompt: "Old reminder",
            createdAt: Date(), allowsPush: false, execution: .init(state: state), workflow: legacyUnlabeled ? nil : .draftReply)]
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        automation.startNext()
        let mustStop = state == .queued || state == .running
        #expect(automation.entries.first?.state == (mustStop ? .preview : .failed))
        #expect(settings.assistantHandoffs.first?.execution?.state == (mustStop ? .cancelled : state))
        #expect(settings.assistantHandoffs.first?.workflow == .draftReply)
        #expect(settings.assistantHandoffs.count == 1)
    }


    @Test func authenticatedObservationClassifiesALegacyReminderAfterColdStart() async throws {
        let suite = "MergeWorkflowExecutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.workflowRules[.reviewWaiting].mode = .assistant
        let id = UUID()
        let pending = try waitingEntry(jobID: id, state: .waitingForAssistant)
        settings.workflowActivity = [pending]
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Waiting for review", prompt: "Old reminder",
            createdAt: Date(), allowsPush: false, execution: .init(state: .interrupted))]
        let glab = GlabService()
        glab.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        #expect(settings.assistantHandoffs.first?.workflow == nil)
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        automation.observe([], host: pending.host, user: pending.user)
        #expect(settings.assistantHandoffs.first?.workflow == .draftReply)
        #expect(settings.assistantHandoffs.first?.execution?.state == .interrupted)
        await Task.yield()
    }

    @Test(arguments: ["feature", "refs/merge-requests/11/head", "refs/merge-requests/11/merge"])
    func explicitPipelineRetryAcceptsCurrentSourceAndMergedResultPipelines(ref: String) async throws {
        try await exercisePipelineRetry(ref: ref)
    }

    @Test(arguments: ["staleSource", "staleTarget", "wrongProject", "wrongRef", "advancedSource", "changedHead", "changedTarget", "changedAccount"])
    func explicitPipelineRetryRejectsStaleUnrelatedAndChangedEvidence(mutation: String) async throws {
        try await exercisePipelineRetry(ref: "refs/merge-requests/11/merge", mutation: mutation)
    }

    private func exercisePipelineRetry(ref: String, mutation: String? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MergeWorkflowPipelineRetry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let source = String(repeating: "a", count: 40)
        let target = String(repeating: "b", count: 40)
        let merged = String(repeating: "c", count: 40)
        let pipelineSHA = ref.hasSuffix("/merge") ? merged : source
        let other = String(repeating: "d", count: 40)
        let sourceParent = mutation == "staleSource" ? other : source
        let targetParent = mutation == "staleTarget" ? other : target
        let branchSource = mutation == "advancedSource" ? other : source
        let pipelineProject = mutation == "wrongProject" ? 8 : 7
        let pipelineRef = mutation == "wrongRef" ? "refs/merge-requests/12/merge" : ref
        let request = """
        {"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},
        "title":"Example","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened",
        "sha":"\(source)","source_project_id":7,"source_branch":"feature","target_project_id":7,
        "target_branch":"main","labels":[],"head_pipeline":{"id":100,"project_id":7,"status":"failed","sha":"\(pipelineSHA)","ref":"\(ref)"}}
        """
        var changedRequest = request
        if mutation == "changedHead" {
            changedRequest = changedRequest.replacingOccurrences(of: "\"sha\":\"\(source)\"", with: "\"sha\":\"\(other)\"")
        }
        if mutation == "changedTarget" {
            changedRequest = changedRequest.replacingOccurrences(of: "\"target_branch\":\"main\"", with: "\"target_branch\":\"release\"")
        }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { call in
            if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            switch call.endpoint {
            case "/user":
                let changed = gitlab.has("user") && mutation == "changedAccount"
                gitlab.write("user")
                return try InMemoryGitLab.json(["id": changed ? 2 : 1, "username": "me"])
            case "/projects/7/merge_requests/11":
                let changed = gitlab.has("request")
                gitlab.write("request")
                return InMemoryGitLab.output(changed ? changedRequest : request)
            case "/projects/7/pipelines/100":
                return try InMemoryGitLab.json(["id": 100, "project_id": pipelineProject, "status": "failed", "sha": pipelineSHA, "ref": pipelineRef])
            case "/projects/7/repository/branches/feature": return try InMemoryGitLab.json(["commit": ["id": branchSource]])
            case "/projects/7/repository/branches/main": return try InMemoryGitLab.json(["commit": ["id": target]])
            case let path where path.hasPrefix("/projects/7/repository/commits/"):
                return try InMemoryGitLab.json(["id": merged, "parent_ids": [targetParent, sourceParent]])
            default: return try gitlab.unexpected(call)
            }
        }
        let glab = gitlab.service(host: host, username: "me")
        settings.glabPath = glab.glabPath
        let id = UUID()
        let url = try #require(URL(string: "https://\(host)/team/repo/-/merge_requests/11"))
        settings.assistantHandoffs = [.init(id: id,
            key: .init(assistant: .codex, work: .init(host: host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .configuredTools), title: "Failed CI", prompt: "Diagnose CI",
            createdAt: Date(), allowsPush: false,
            pipelineReservation: .init(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 100),
            execution: .init(state: .failed), taskPrompt: "Diagnose CI", mergeRequestURL: url, workflow: .followUp,
            expectedHeadSHA: source)]
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return .init(result: .init(status: .succeeded, summary: "Done"), output: "")
        })
        let retry: AssistantAutomationRunner.Handoff
        do {
            retry = try await AssistantAutomationRunner.retry(id, settings: settings, expectedHeadSHA: source, jobCoordinator: coordinator, glab: glab)
        } catch {
            guard mutation != nil else { throw error }
            #expect(error is CancellationError || error is GitLabPipelineEvidenceError)
            #expect(settings.assistantHandoffs.count == 1)
            return
        }
        #expect(mutation == nil)
        #expect(retry.id != id)
        #expect(retry.pipelineReservation?.pipelineID == 100)
        #expect(retry.expectedHeadSHA == source)
        coordinator.cancel(retry.id)
        for _ in 0..<100 where coordinator.isRunning(retry.id) { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(arguments: [false, true])
    func fullProfileRefreshesStaleTargetPipelineOnceAndRetainsAmbiguousAttempts(ambiguousResponse: Bool) async throws {
        try await exercisePipelineRefresh(ambiguousResponse: ambiguousResponse)
    }

    @Test func pipelineRefreshRejectsANewMergedPipelineWithUnrelatedParents() async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, wrongCreatedParents: true)
    }

    @Test func fullProfileRefreshesStaleCIWithoutRepeatingAnEarlierWorkerReceipt() async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, priorReceipt: true)
    }

    @Test func stalePipelineRefreshWaitsForAReservationWonDuringVerification() async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, ownershipRace: true)
    }

    @Test func transientPrelaunchReadFailureRecoversBeforeThePipelineRefreshAction() async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, prelaunchFailures: 1)
    }

    @Test(arguments: [2, 3])
    func becomingDraftDuringPipelineProofPreventsTheAutomaticWrite(_ firstDraftRead: Int) async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, draftAfterRead: firstDraftRead)
    }

    @Test(arguments: [false, true])
    func becomingDraftBeforeInfrastructureRetryPreventsTheWrite(_ duringJobRead: Bool) async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, draftAfterRead: duringJobRead ? nil : 2,
                                         infrastructureRetry: true, draftOnJobRead: duringJobRead)
    }

    @Test func persistenceFailureBeforeInfrastructureRetryPreventsTheWrite() async throws {
        try await exercisePipelineRefresh(ambiguousResponse: false, infrastructureRetry: true, persistenceOnJobRead: true)
    }

    private func exercisePipelineRefresh(
        ambiguousResponse: Bool, wrongCreatedParents: Bool = false, priorReceipt: Bool = false, ownershipRace: Bool = false,
        prelaunchFailures: Int = 0, draftAfterRead: Int? = nil, infrastructureRetry: Bool = false,
        draftOnJobRead: Bool = false, persistenceOnJobRead: Bool = false
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MergeWorkflowPipelineRefresh.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let source = String(repeating: "a", count: 40)
        let target = String(repeating: "b", count: 40)
        let merged = String(repeating: "c", count: 40)
        let currentMerged = String(repeating: "e", count: 40)
        let oldTarget = infrastructureRetry ? target : String(repeating: "d", count: 40)
        let createdTarget = wrongCreatedParents ? oldTarget : target
        let request = """
        {"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},
        "title":"Example","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened","draft":false,
        "sha":"\(source)","source_project_id":7,"source_branch":"feature","target_project_id":7,
        "target_branch":"main","has_conflicts":false,"labels":[],"head_pipeline":{"id":100,"project_id":7,"status":"failed","sha":"\(merged)","ref":"refs/merge-requests/11/merge"}}
        """
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        var userReads = 0, mrReads = 0
        var liveSettings: SettingsManager?
        gitlab.handler = { call in
            switch call.endpoint {
            case "/user":
                userReads += 1
                return userReads <= prelaunchFailures ? InMemoryGitLab.output(error: "503 temporarily unavailable", code: 1)
                    : InMemoryGitLab.output(#"{"id":1,"username":"me"}"#)
            case "/projects/7/jobs/200/retry":
                #expect(call.method == "POST")
                gitlab.append("posted", "x")
                return try InMemoryGitLab.json(["id": 200, "status": "pending", "allow_failure": false, "failure_reason": "runner_system_failure", "pipeline": ["id": 100]])
            case "/projects/7/jobs/200":
                if persistenceOnJobRead { liveSettings?.recordPersistenceFailure("workflowActivity") }
                if draftOnJobRead { gitlab.write("job-read") }
                return try InMemoryGitLab.json(["id": 200, "status": "failed", "allow_failure": false, "failure_reason": "runner_system_failure", "pipeline": ["id": 100]])
            case "/projects/7/merge_requests/11/pipelines":
                #expect(call.method == "POST")
                gitlab.append("posted", "x")
                if ambiguousResponse { return InMemoryGitLab.output(error: "network response lost", code: 1) }
                return try InMemoryGitLab.json(["id": 101, "project_id": 7, "status": "pending", "sha": currentMerged, "ref": "refs/merge-requests/11/merge"])
            case "/projects/7/merge_requests/11":
                mrReads += 1
                return InMemoryGitLab.output(mrReads >= (draftAfterRead ?? Int.max) || gitlab.has("job-read")
                    ? request.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#) : request)
            case "/projects/7/pipelines/100":
                if ownershipRace {
                    try FileManager.default.createDirectory(at: directory.appending(path: "claims/host-\(host)/project-7/mr-11/active"), withIntermediateDirectories: true)
                }
                return try InMemoryGitLab.json(["id": 100, "project_id": 7, "status": "failed", "sha": merged, "ref": "refs/merge-requests/11/merge"])
            case "/projects/7/pipelines/101":
                return try InMemoryGitLab.json(["id": 101, "project_id": 7, "status": "pending", "sha": currentMerged, "ref": "refs/merge-requests/11/merge"])
            case "/projects/7/repository/branches/feature": return try InMemoryGitLab.json(["commit": ["id": source]])
            case "/projects/7/repository/branches/main": return try InMemoryGitLab.json(["commit": ["id": target]])
            case "/projects/7/repository/commits/\(currentMerged)": return try InMemoryGitLab.json(["id": currentMerged, "parent_ids": [createdTarget, source]])
            case let path where path.hasPrefix("/projects/7/repository/commits/"):
                return try InMemoryGitLab.json(["id": merged, "parent_ids": [oldTarget, source]])
            default: return try gitlab.unexpected(call)
            }
        }
        let decoded = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
        let event = MergeWorkflowEvent(kind: .pipelineFailure, mergeRequest: decoded, identity: "refresh-stale",
                                       context: "Failed CI", pipelineProjectID: 7, pipelineID: 100,
                                       jobID: infrastructureRetry ? 200 : nil, isInfrastructureFailure: infrastructureRetry)
        let claims = directory.appending(path: "claims")
        if priorReceipt {
            let detector = ExistingPipelineWorkDetector(directory: claims)
            let prior = try detector.registerRun(for: .init(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 100))
            let reservation = try #require(prior)
            try detector.finishHandoff(for: reservation)
        }
        let draftPaused = draftAfterRead != nil || draftOnJobRead
        for attemptIndex in 0..<2 {
            let settings = SettingsManager(defaults: defaults)
            liveSettings = settings
            settings.automation.applyPreset(.full, for: .codex)
            if infrastructureRetry {
                settings.automation.workflowRules[.pipelineFailure].projects = "team/repo"
                settings.automation.workflowRules[.pipelineFailure].retryInfrastructureFailure = true
            }
            settings.workflowActivity = []
            let glab = gitlab.service(host: host, username: "me")
            var retryDelays: [Duration] = []
            let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(),
                                                    detector: .init(directory: claims), retryWait: { retryDelays.append($0) })
            var remoteChanges = 0
            automation.onRemoteChange = { remoteChanges += 1 }
            automation.receive(event, host: host, user: .init(id: 1, username: "me"))
            automation.startNext()
            for _ in 0..<500 where automation.entries.first.map({ [.queued, .running].contains($0.state) }) == true {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(settings.assistantHandoffs.isEmpty)
            if persistenceOnJobRead {
                #expect(!settings.automaticActionsAllowed && !gitlab.has("posted"))
                continue
            }
            if prelaunchFailures > 0 { #expect(retryDelays == (attemptIndex == 0 ? [.seconds(2)] : [])) }
            if attemptIndex == 0 {
                let expected: MergeWorkflowActivityState = draftPaused ? .skipped : ownershipRace ? .alreadyRegistered
                    : ambiguousResponse || wrongCreatedParents ? .failed : .completed
                #expect(automation.entries.first?.state == expected)
            }
            let confirmed = !draftPaused && !ownershipRace && !ambiguousResponse && !wrongCreatedParents
            #expect(remoteChanges == (confirmed ? 1 : 0))
            #expect(automation.isAutomaticallyProcessingPipeline(decoded) == (confirmed || ownershipRace))
            var currentObject = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            currentObject["head_pipeline"] = ["id": 101, "project_id": 7, "status": "pending", "sha": currentMerged]
            let current = try JSONDecoder().decode(GitLabMergeRequest.self,
                from: JSONSerialization.data(withJSONObject: currentObject))
            if confirmed { #expect(!automation.isAutomaticallyProcessingPipeline(current)) }
            try? FileManager.default.removeItem(at: claims)
        }
        let posted = gitlab.files["posted"]
        if persistenceOnJobRead { #expect(posted == nil); return }
        #expect(posted == (ownershipRace || draftPaused ? nil : "x"))
        let attempts = defaults.data(forKey: "pipelineRefreshAttempts")
        let attemptCount = try attempts.map { (try JSONSerialization.jsonObject(with: $0) as? [Any])?.count ?? 0 } ?? 0
        #expect(attemptCount == (ownershipRace || draftPaused ? 0 : 1))
    }

}
