import Foundation
import Testing
@testable import MergeTether

@MainActor
struct TodoMonitorAutomaticRetryTests {
    @Test(arguments: ["current", "current-conflict"])
    func retryUsesFreshEvidenceAndTheSelectedProviderWithoutManualConsent(_ scenario: String) async throws {
        try await exercise(scenario)
    }

    @Test(arguments: ["closed", "head", "pipeline-passed", "pipeline-replaced", "user-stopped", "user-failed", "user-interrupted", "late-user-interrupted", "resolved-conflict"])
    func obsoleteWorkDoesNotCreateAnotherRun(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["disabled", "ignored", "scope", "tools", "workflow", "cli", "late-policy", "late-account", "late-stop", "busy", "foreign-conflict", "missing-head", "invalid-head"])
    func liveHoldsDeferBeforeCreatingAWorker(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["retry-busy", "retry-permission", "retry-unavailable", "retry-context", "retry-pipeline-unknown", "retry-pipeline-pending", "retry-pipeline-running"])
    func knownNoChildAdmissionRefusalsDeferWithoutSpendingTheBudget(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["retry-closed", "retry-head", "retry-pipeline-passed", "retry-pipeline-superseded"])
    func confirmedFinalSnapshotObsolescenceRetiresOnlyEffectFreeAdmissions(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["retry-child-permission", "retry-child-busy", "retry-child-context", "retry-unknown", "retry-child-pipeline-unknown", "retry-child-pipeline-pending", "retry-child-pipeline-running", "retry-child-pipeline-passed", "retry-child-pipeline-superseded"])
    func uncertainOrPostChildFailuresRemainChargeable(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["claim-dead", "claim-live", "claim-unknown"])
    func anUnreconciledPipelineClaimDefersBeforeFreshAdmission(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: ["mr-claim-dead", "mr-claim-live", "mr-claim-unknown"])
    func aReviewWithoutPipelineMetadataRespectsTheMRWideWorkerClaim(_ change: String) async throws {
        try await exercise(change)
    }

    @Test(arguments: [false, true])
    func adoptingARecordedChildRebindsLocalWorkflowAndTodoLinksIdempotently(_ completed: Bool) throws {
        let suite = "TodoMonitorAutomaticRetryAdoptionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":9,"username":"author","name":"Author"},"title":"MR","web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"source_branch":"feature","target_branch":"main","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","labels":[]}"#.utf8))
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let parentID = UUID()
        let child = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: target.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Retry", prompt: "Retry", createdAt: .now, allowsPush: false,
            execution: .init(state: completed ? .succeeded : .queued), expectedHeadSHA: request.sha, retryOf: parentID)
        settings.assistantHandoffs = [child]
        settings.workflowActivity = [.init(id: "old", event: .init(kind: .reviewUpdate, mergeRequest: request,
            identity: "old", context: "Review update"), createdAt: .now, host: target.host,
            user: .init(id: 7, username: "me"), state: .failed, summary: "Old failure", assistantJobID: parentID)]
        settings.mrActionIntents = [.init(id: UUID(), target: target, kind: .review, state: .failed,
            todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: request.sha!, jobID: parentID,
            error: "Old failure", updatedAt: .now)]
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let monitor = TodoMonitorService(settings: settings, glab: gitlab.service(host: target.host, username: "me"),
            notifications: NotificationService(authorization: { .denied }, post: { _ in }),
            assistantDependencies: AssistantDependencyMonitor(probe: { _ in .missingCLI }))
        defer { monitor.stopTimer() }

        settings.assistantHandoffs = [child]
        settings.save()
        monitor.adoptAutomaticRetry(parentID: parentID, replacement: child)
        let eventCount = settings.automationEvents.count
        let intentDate = settings.mrActionIntents.first?.updatedAt
        monitor.adoptAutomaticRetry(parentID: parentID, replacement: child)

        #expect(settings.workflowActivity.first?.assistantJobID == child.id)
        #expect(settings.workflowActivity.first?.summary == nil)
        #expect(WorkflowExecutionProjection.entry(settings.workflowActivity[0], job: child).state == (completed ? .completed : .waitingForAssistant))
        #expect(settings.mrActionIntents.first?.jobID == child.id && settings.mrActionIntents.first?.error == nil)
        #expect(settings.mrActionIntents.first?.updatedAt == intentDate && settings.automationEvents.count == eventCount)
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.workflowActivity.first?.assistantJobID == child.id && reloaded.mrActionIntents.first?.jobID == child.id)
        #expect(gitlab.requests.isEmpty)
    }

    private func exercise(_ change: String) async throws {
        let suite = "TodoMonitorAutomaticRetryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.trusted, for: .codex)
        let host = "gitlab.example.test", source = String(repeating: "a", count: 40)
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let pipeline = change.hasPrefix("pipeline-") || change.hasPrefix("claim-")
        let conflict = change.hasSuffix("-conflict")
        if conflict { settings.automation.conflictTasksEnabled = true; settings.automation.allowConflictPush = false }
        let original = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .claude,
            work: work, username: "me", workspace: "", access: .configuredTools), title: "Repair",
            prompt: "Historical data", createdAt: .now, allowsPush: false,
            pipelineReservation: pipeline ? .init(host: host, projectID: 1, mergeRequestIID: 2, pipelineID: 10) : nil,
            execution: .init(state: change == "user-stopped" ? .cancelled : (change == "user-interrupted" ? .interrupted : .failed),
                finishedAt: .now, cancellationOrigin: change.hasPrefix("user-") ? .user : nil),
            taskPrompt: "Review current evidence", mergeRequestURL: URL(string: "https://\(host)/g/p/-/merge_requests/2"),
            workflow: pipeline || conflict ? nil : .review, expectedHeadSHA: source,
            taskIntent: conflict ? .conflictResolution : nil, workflowOriginKnown: true)
        settings.assistantHandoffs = [original]
        if change == "disabled" { settings.automation.packageDecision = .disabled }
        if change == "ignored" { settings.ignoredMergeRequests.insert(target) }
        if change == "scope" { settings.automation.scope.mode = .selected }
        if change == "tools" { settings.automation.allowAssistantTools = false }
        if change == "workflow" {
            settings.automation.reviewRequested.isEnabled = false
            settings.automation.autoReReviewEnabled = false
        }
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "me")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        gitlab.handler = { call in
            if call.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if call.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            #expect(call.method == "GET")
            if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"me"}"#) }
            if call.endpoint == "/projects/1/merge_requests/2" {
                if change == "late-policy" { settings.automation.packageDecision = .disabled }
                if change == "late-account" { glab.currentUsername = "other" }
                if change == "late-stop" || change == "late-user-interrupted" {
                    settings.assistantHandoffs[0].execution?.state = change == "late-stop" ? .cancelled : .interrupted
                    settings.assistantHandoffs[0].execution?.cancellationOrigin = .user
                }
                return try InMemoryGitLab.json([
                    "id": 2, "iid": 2, "project_id": 1, "title": "MR", "state": change == "closed" ? "closed" : "opened",
                    "author": ["id": conflict && change != "foreign-conflict" ? 7 : 9, "username": "author", "name": "Author"],
                    "web_url": "https://\(host)/g/p/-/merge_requests/2", "source_branch": "feature", "target_branch": "main",
                    "source_project_id": 1, "target_project_id": 1, "has_conflicts": conflict && change != "resolved-conflict",
                    "labels": [], "draft": false, "sha": change == "missing-head" ? NSNull() as Any : (change == "invalid-head" ? "invalid" : (change == "head" ? String(repeating: "b", count: 40) : source)),
                    "head_pipeline": ["id": change == "pipeline-replaced" ? 11 : 10, "project_id": 1,
                        "status": change == "pipeline-passed" ? "success" : "failed", "sha": source, "ref": "feature"]
                ])
            }
            return InMemoryGitLab.output("[]")
        }
        let dependencies = AssistantDependencyMonitor(probe: { _ in .missingCLI })
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }), assistantDependencies: dependencies)
        defer { monitor.stopTimer() }
        #expect(dependencies.onReady != nil)
        if change == "busy" {
            settings.assistantHandoffs.append(.init(id: UUID(), key: original.key, title: "Active", prompt: "Active",
                createdAt: .now, allowsPush: false, execution: .init(state: .running)))
        }
        let claimDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: claimDirectory) }
        let detector = ExistingPipelineWorkDetector(directory: claimDirectory, processState: { _ in
            change.hasSuffix("claim-dead") ? .dead : (change.hasSuffix("claim-live") ? .alive : .unknown)
        })
        if change.hasPrefix("claim-") || change.hasPrefix("mr-claim-") {
            let optionalClaim = try detector.registerRun(for: .init(host: host, projectID: 1, mergeRequestIID: 2, pipelineID: 10))
            let claim = try #require(optionalClaim)
            try detector.bindRun(original.id, to: claim)
            if !change.hasPrefix("mr-claim-") { settings.assistantHandoffs[0].pipelineReservation = claim }
        }
        let identity = AssistantAutomaticRetryIdentity(rootID: original.id, reservationID: UUID(), attempt: 1)
        if change.hasPrefix("retry-") {
            settings.assistantHandoffs[0].automaticRetryIdentity = identity
            settings.save()
        }
        var launches = 0
        let result: AssistantAutomaticRetryCoordinator.LaunchResult
        do {
        result = try await monitor.launchAutomaticRetry(original, identity: identity,
            assistantReady: change != "cli", pipelineWorkDetector: detector, retry: { previous, checkedIdentity, head in
                launches += 1
                #expect(settings.automation.assistant == .codex)
                #expect(previous.id == original.id && checkedIdentity == identity && head == source)
                #expect(gitlab.requests.contains { $0.endpoint == "/user" })
                #expect(gitlab.requests.contains { $0.endpoint == "/projects/1/merge_requests/2" })
                if change == "retry-busy" {
                    settings.assistantHandoffs.append(.init(id: UUID(), key: previous.key, title: "Concurrent worker", prompt: "Other work",
                        createdAt: .now, allowsPush: false, execution: .init(state: .running)))
                    settings.save()
                }
                if change.hasPrefix("retry-child-") {
                    let child = AssistantAutomationRunner.Handoff(id: UUID(), key: previous.key, title: "Recorded child", prompt: "Current work",
                        createdAt: .now, allowsPush: false, execution: .init(state: .queued), retryOf: previous.id,
                        automaticRetryIdentity: checkedIdentity)
                    settings.assistantHandoffs.append(child)
                    settings.save()
                }
                if change == "retry-busy" || change == "retry-child-busy" { throw AssistantAutomationRunner.HandoffError.mergeRequestBusy }
                if change == "retry-permission" || change == "retry-child-permission" { throw AssistantJobExecutor.ExecutionError.disabledPermission }
                if change == "retry-context" || change == "retry-child-context" { throw AssistantJobExecutor.ExecutionError.contextUnavailable }
                if change.hasSuffix("pipeline-unknown") { throw AssistantAutomationRunner.HandoffError.pipelineState(10, "unknown") }
                if change.hasSuffix("pipeline-pending") { throw AssistantAutomationRunner.HandoffError.pipelineState(10, "pending") }
                if change.hasSuffix("pipeline-running") { throw AssistantAutomationRunner.HandoffError.pipelineState(10, "running") }
                if change.hasSuffix("pipeline-passed") { throw AssistantAutomationRunner.HandoffError.pipelinePassed(10) }
                if change.hasSuffix("pipeline-superseded") { throw AssistantAutomationRunner.HandoffError.pipelineSuperseded(10) }
                if change == "retry-closed" { throw AssistantJobExecutor.ExecutionError.inactiveMergeRequest }
                if change == "retry-head" { throw AssistantJobExecutor.ExecutionError.headChanged }
                if change == "retry-unavailable" { throw AssistantAutomationRunner.HandoffError.executionUnavailable }
                if change == "retry-unknown" { throw GlabError.timedOut }
                return .init(id: UUID(), key: previous.key, title: "Retry", prompt: "Reconcile", createdAt: .now,
                    allowsPush: false, execution: .init(state: .queued), taskPrompt: previous.taskPrompt,
                    mergeRequestURL: previous.mergeRequestURL, workflow: previous.workflow, manual: false,
                    expectedHeadSHA: head, retryOf: previous.id, automaticRetryIdentity: checkedIdentity)
            })
        } catch {
            #expect(["retry-child-permission", "retry-child-busy", "retry-child-context", "retry-unknown", "retry-child-pipeline-unknown", "retry-child-pipeline-pending", "retry-child-pipeline-running", "retry-child-pipeline-passed", "retry-child-pipeline-superseded"].contains(change))
            #expect(launches == 1)
            return
        }
        #expect(!["retry-child-permission", "retry-child-busy", "retry-child-context", "retry-unknown", "retry-child-pipeline-unknown", "retry-child-pipeline-pending", "retry-child-pipeline-running", "retry-child-pipeline-passed", "retry-child-pipeline-superseded"].contains(change))
        if change.hasPrefix("claim-") || change.hasPrefix("mr-claim-") {
            let holds = settings.automationEvents.filter { $0.action == .retry && $0.jobID == original.id && $0.state == .blocked }
            #expect(holds.count == 1)
            #expect(SettingsManager(defaults: defaults).automationEvents.contains { $0.action == .retry && $0.jobID == original.id && $0.state == .blocked })
            #expect(!gitlab.requests.contains { $0.endpoint == "/user" || $0.endpoint == "/projects/1/merge_requests/2" })
            #expect(!monitor.canAutomaticallyRetry(original, assistantReady: true, pipelineWorkDetector: detector))
            #expect(settings.automationEvents.filter { $0.action == .retry && $0.jobID == original.id && $0.state == .blocked }.count == 1)
            #expect(settings.assistantAutomaticRetryAttempts.isEmpty && launches == 0)
        }
        switch result {
        case .started(let child): #expect(["current", "current-conflict"].contains(change) && launches == 1 && child.retryOf == original.id)
        case .obsolete: #expect(["closed", "head", "pipeline-passed", "pipeline-replaced", "user-stopped", "user-failed", "user-interrupted", "late-user-interrupted", "late-stop", "resolved-conflict", "retry-closed", "retry-head", "retry-pipeline-passed", "retry-pipeline-superseded"].contains(change) && launches == (change.hasPrefix("retry-") ? 1 : 0))
        case .deferred: #expect(!["current", "current-conflict"].contains(change) && !["closed", "head", "pipeline-passed", "pipeline-replaced", "user-stopped", "user-failed", "user-interrupted", "late-user-interrupted", "retry-closed", "retry-head", "retry-pipeline-passed", "retry-pipeline-superseded"].contains(change) && launches == (change.hasPrefix("retry-") ? 1 : 0))
        case .failed: Issue.record("Unexpected retry failure")
        }
    }
}
