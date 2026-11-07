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
        if blocker == "summary" { stored.summary = "An earlier outcome is uncertain." }
        if blocker == "chat" { stored.chatURL = URL(string: "https://example.test/existing-session") }
        let key = ExistingPipelineWorkDetector.Key(host: stored.host, projectID: 7, mergeRequestIID: 11, pipelineID: 101)
        if blocker == "receipt" {
            let reserved = try detector.registerRun(for: key)
            let owned = try #require(reserved)
            try detector.finishHandoff(for: owned)
        } else if blocker == "active" {
            try FileManager.default.createDirectory(at: detector.externalRegistrationURL(for: key), withIntermediateDirectories: true)
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
        settings.workflowActivity = [stored]
        settings.save()
        var currentObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored.event.mergeRequest)) as? [String: Any])
        currentObject["sha"] = String(repeating: blocker == "stale-head" ? "b" : "a", count: 40)
        currentObject["head_pipeline"] = ["id": blocker == "different-pipeline" ? 102 : 101, "project_id": 7,
                                          "status": blocker == "successful-pipeline" ? "success" : "failed",
                                          "sha": String(repeating: "a", count: 40)]
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
        if blocker == "none" {
            #expect(automation.entries.first?.state == .queued)
            #expect(automation.entries.first?.assistantJobID == nil)
            #expect(automation.isAutomaticallyProcessingPipeline(current))
            #expect(SettingsManager(defaults: defaults).workflowActivity.first?.state == .queued)
        } else {
            #expect(automation.entries.first?.state != .queued)
        }
        #expect(automation.entries.count == 1)
        #expect(automation.entries.first?.id == stored.id)
        #expect(settings.assistantHandoffs.count == (["linked-failed", "linked-interrupted", "linked-completed", "unlinked-pipeline-job"].contains(blocker) ? 1 : 0))
        for _ in 0..<4 { await Task.yield() }
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
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        case "$*" in
          'config get host') printf '%s' '\(host)' ;;
          'auth status') printf '%s' 'Logged in to \(host) as me' >&2 ;;
          'api /user '*)
            if test -f "$0-user" && test '\(mutation ?? "")' = changedAccount; then
              printf '%s' '{"id":2,"username":"me"}'
            else printf '%s' '{"id":1,"username":"me"}'; fi
            touch "$0-user" ;;
          'api /projects/7/merge_requests/11 '*)
            if test -f "$0-request"; then printf '%s' '\(changedRequest)'; else printf '%s' '\(request)'; fi
            touch "$0-request" ;;
          'api /projects/7/pipelines/100 '*) printf '%s' '{"id":100,"project_id":\(pipelineProject),"status":"failed","sha":"\(pipelineSHA)","ref":"\(pipelineRef)"}' ;;
          'api /projects/7/repository/branches/feature '*) printf '%s' '{"commit":{"id":"\(branchSource)"}}' ;;
          'api /projects/7/repository/branches/main '*) printf '%s' '{"commit":{"id":"\(target)"}}' ;;
          'api /projects/7/repository/commits/'*) printf '%s' '{"id":"\(merged)","parent_ids":["\(targetParent)","\(sourceParent)"]}' ;;
          *) printf '%s' 'Unexpected glab command' >&2; exit 20 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
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
            retry = try await AssistantAutomationRunner.retry(id, settings: settings, expectedHeadSHA: source, jobCoordinator: coordinator)
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

    private func exercisePipelineRefresh(
        ambiguousResponse: Bool, wrongCreatedParents: Bool = false, priorReceipt: Bool = false, ownershipRace: Bool = false
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
        let oldTarget = String(repeating: "d", count: 40)
        let createdTarget = wrongCreatedParents ? oldTarget : target
        let request = """
        {"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},
        "title":"Example","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened","draft":false,
        "sha":"\(source)","source_project_id":7,"source_branch":"feature","target_project_id":7,
        "target_branch":"main","has_conflicts":false,"labels":[],"head_pipeline":{"id":100,"project_id":7,"status":"failed","sha":"\(merged)","ref":"refs/merge-requests/11/merge"}}
        """
        let executable = directory.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        case "$*" in
          'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
          'api /projects/7/merge_requests/11/pipelines '*'--method POST'*)
            printf x >> "$0-posted"
            if test '\(ambiguousResponse)' = true; then printf 'network response lost' >&2; exit 1; fi
            printf '%s' '{"id":101,"project_id":7,"status":"pending","sha":"\(currentMerged)","ref":"refs/merge-requests/11/merge"}' ;;
          'api /projects/7/merge_requests/11 '*) printf '%s' '\(request)' ;;
          'api /projects/7/pipelines/100 '*)
            if test '\(ownershipRace)' = true; then mkdir -p '\(directory.path)/claims/host-\(host)/project-7/mr-11/active'; fi
            printf '%s' '{"id":100,"project_id":7,"status":"failed","sha":"\(merged)","ref":"refs/merge-requests/11/merge"}' ;;
          'api /projects/7/pipelines/101 '*) printf '%s' '{"id":101,"project_id":7,"status":"pending","sha":"\(currentMerged)","ref":"refs/merge-requests/11/merge"}' ;;
          'api /projects/7/repository/branches/feature '*) printf '%s' '{"commit":{"id":"\(source)"}}' ;;
          'api /projects/7/repository/branches/main '*) printf '%s' '{"commit":{"id":"\(target)"}}' ;;
          'api /projects/7/repository/commits/\(currentMerged) '*) printf '%s' '{"id":"\(currentMerged)","parent_ids":["\(createdTarget)","\(source)"]}' ;;
          'api /projects/7/repository/commits/'*) printf '%s' '{"id":"\(merged)","parent_ids":["\(oldTarget)","\(source)"]}' ;;
          *) printf '%s' 'Unexpected glab command' >&2; exit 20 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let decoded = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
        let event = MergeWorkflowEvent(kind: .pipelineFailure, mergeRequest: decoded, identity: "refresh-stale",
                                       context: "Failed CI", pipelineProjectID: 7, pipelineID: 100)
        let claims = directory.appending(path: "claims")
        if priorReceipt {
            let detector = ExistingPipelineWorkDetector(directory: claims)
            let prior = try detector.registerRun(for: .init(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 100))
            let reservation = try #require(prior)
            try detector.finishHandoff(for: reservation)
        }
        for attemptIndex in 0..<2 {
            let settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: .codex)
            settings.workflowActivity = []
            let glab = GlabService()
            glab.glabPath = executable
            glab.resolvedHost = host
            glab.currentUsername = "me"
            let automation = MergeWorkflowAutomation(settings: settings, glab: glab, notifications: NotificationService(),
                                                    detector: .init(directory: claims))
            var remoteChanges = 0
            automation.onRemoteChange = { remoteChanges += 1 }
            automation.receive(event, host: host, user: .init(id: 1, username: "me"))
            automation.startNext()
            for _ in 0..<500 where automation.entries.first.map({ [.queued, .running].contains($0.state) }) == true {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(settings.assistantHandoffs.isEmpty)
            if attemptIndex == 0 {
                let expected: MergeWorkflowActivityState = ownershipRace ? .alreadyRegistered
                    : ambiguousResponse || wrongCreatedParents ? .failed : .completed
                #expect(automation.entries.first?.state == expected)
            }
            let confirmed = !ownershipRace && !ambiguousResponse && !wrongCreatedParents
            #expect(remoteChanges == (confirmed ? 1 : 0))
            #expect(automation.isAutomaticallyProcessingPipeline(decoded) == (confirmed || ownershipRace))
            var currentObject = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            currentObject["head_pipeline"] = ["id": 101, "project_id": 7, "status": "pending", "sha": currentMerged]
            let current = try JSONDecoder().decode(GitLabMergeRequest.self,
                from: JSONSerialization.data(withJSONObject: currentObject))
            if confirmed { #expect(!automation.isAutomaticallyProcessingPipeline(current)) }
            try? FileManager.default.removeItem(at: claims)
        }
        let posted = try? String(contentsOf: URL(fileURLWithPath: executable.path + "-posted"), encoding: .utf8)
        #expect(posted == (ownershipRace ? nil : "x"))
        let attempts = defaults.data(forKey: "pipelineRefreshAttempts")
        let attemptCount = try attempts.map { (try JSONSerialization.jsonObject(with: $0) as? [Any])?.count ?? 0 } ?? 0
        #expect(attemptCount == (ownershipRace ? 0 : 1))
    }

}
