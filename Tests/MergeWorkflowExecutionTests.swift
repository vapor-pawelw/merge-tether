import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct MergeWorkflowExecutionTests {
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
                                       "state": "opened", "sha": String(repeating: "a", count: 40),
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
        let glab = GlabService()
        glab.resolvedHost = "gitlab.example.test"
        glab.currentUsername = "me"
        let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService())
        #expect(automation.entries[0].state == .running)
        #expect(automation.entries[1].state == .waitingForAssistant)
        settings.assistantHandoffs[0].execution = .init(state: .succeeded, summary: "Fix verified")
        automation.synchronizeAssistantJobs()
        #expect(automation.entries[0].state == .completed)
        #expect(automation.entries[0].summary == "Fix verified")
        #expect(automation.entries[1].state == .waitingForAssistant)
        #expect(SettingsManager(defaults: defaults).workflowActivity[0].state == .completed)
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

}
