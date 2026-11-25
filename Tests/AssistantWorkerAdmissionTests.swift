import Foundation
import Testing
@testable import MergeTether

@MainActor
struct AssistantWorkerAdmissionTests {
    @Test(arguments: ["resolved", "late-resolved", "advanced-head", "open", "mixed", "missing", "unavailable"])
    func resumedFollowUpStartsOnlyWhenGitLabCannotConfirmAllThreadsAreResolved(_ evidence: String) async throws {
        let f = try Fixture(assistant: .codex, scenario: "follow-up-\(evidence)")
        defer { f.clean() }
        let health = AssistantCLIHealthStore(defaults: f.defaults)
        health.record(.init(kind: .rateLimited), assistant: .codex, executable: f.cli, startedAt: .now)
        let hold = try #require(health.hold(for: .codex))
        let queue = AssistantJobCoordinator(healthStore: health) { handoff, settings in
            try await AssistantJobExecutor.execute(handoff, settings: settings, glab: f.glab,
                pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
        }
        var queued = f.handoff
        queued.execution = .init(state: .queued)
        queued.verifiedFeedbackNotes = [1: "note-revision"]
        let work = queued.key.work
        let target = MRAutomationScope.Target(host: work.host, username: queued.key.username, projectID: work.projectID, iid: work.iid)
        let receipt = AuthorFeedbackAttempt(target: target, noteID: 1, revision: "note-revision")
        f.settings.authorFeedbackAttempts.insert(receipt)
        f.settings.assistantHandoffs = [queued]
        try #require(queue.schedule(queued, settings: f.settings))
        #expect(f.settings.assistantHandoffs[0].execution?.state == .queued)

        let shouldSkip = ["resolved", "late-resolved", "advanced-head"].contains(evidence)
        f.threadResolved = ["resolved", "advanced-head", "mixed"].contains(evidence)
        health.clear(.codex, expectedID: hold.id)
        queue.resumePendingJobs()
        await queue.waitForTermination()

        #expect(FileManager.default.fileExists(atPath: f.cli.path + ".started") == !shouldSkip)
        let restored = SettingsManager(defaults: f.defaults)
        #expect(restored.assistantHandoffs[0].execution?.state == (shouldSkip ? .feedbackResolved : .blocked))
        #expect(restored.authorFeedbackAttempts.contains(receipt) == !shouldSkip)
        if shouldSkip {
            #expect(AssistantAutomationRunner.unhandledFeedback([1], work: work, username: queued.key.username, settings: restored) == [1])
            let request = try await f.glab.fetchMergeRequest(projectID: work.projectID, iid: work.iid, host: work.host)
            restored.mrActionIntents = [.init(id: UUID(), target: target, kind: .followUp, state: .running,
                todoIDs: [], noteIDs: [1], sourceEvents: [], request: request, headSHA: f.head, jobID: queued.id, updatedAt: .now)]
            let router = MergeRequestTodoRouter(settings: restored, glab: f.glab, canAutomate: { false })
            await router.refreshCompletionEvidence(host: work.host, username: target.username)
            #expect(restored.mrActionIntents[0].state == .completed)
        }
    }

    @Test(arguments: AutomationAssistant.allCases, ["observed", "failed", "other-account", "changed-account", "allowed-resolution", "allowed-push", "missing-approvals"])
    func workerAuditHoldsOnlyTheAffectedMergeRequest(_ assistant: AutomationAssistant, _ scenario: String) async throws {
        let f = try Fixture(assistant: assistant, scenario: "audit-\(scenario)")
        defer { f.clean() }
        #expect(f.settings.automationGloballyEnabled && f.settings.automaticPublicWritesAllowed)
        let suspends = ["observed", "failed", "changed-account", "missing-approvals"].contains(scenario)
        do {
            let outcome = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings,
                glab: f.glab, pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            #expect(!suspends && outcome.result.status == .blocked)
        } catch let failure as AssistantJobFailure {
            #expect(suspends)
            let expected: AssistantJobExecutor.ExecutionError? = switch scenario {
            case "observed", "missing-approvals": .unexpectedRemoteEffects
            case "changed-account": .auditUnavailable
            default: nil
            }
            // A failed worker keeps its own error; only the out-of-bounds or unverifiable successes are replaced.
            if let expected { #expect(failure.description == expected.description) }
            else { #expect(failure.description.contains("CLI exit 12")) }
        }
        let target = MRAutomationScope.Target(host: f.host, username: "me", projectID: 7, iid: 11)
        let unrelated = MRAutomationScope.Target(host: f.host, username: "me", projectID: 7, iid: 12)
        let reopened = SettingsManager(defaults: f.defaults)
        #expect(reopened.automationGloballyEnabled && reopened.automaticPublicWritesAllowed)
        #expect((reopened.automation.scope[target] == .paused) == ["observed", "failed", "missing-approvals"].contains(scenario))
        #expect(reopened.automation.scope[unrelated] != .paused)
        #expect(FileManager.default.fileExists(atPath: f.cli.path + ".started"))

        let saved = try #require(SettingsManager(defaults: f.defaults).assistantHandoffs.first?.execution)
        let effects = Set(saved.remoteEffects ?? [])
        switch scenario {
        case "observed", "failed":
            #expect(effects == [.publishedComment, .approval, .resolvedDiscussion, .sourceHead])
        case "missing-approvals":
            #expect(effects == [.publishedComment, .resolvedDiscussion, .sourceHead])
        default:
            #expect(effects.isEmpty)
        }
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["external", "busy-project", "own-account", "wrong-ref", "wrong-project", "stale-event", "ambiguous", "truncated-window"])
    func onlyAnExactlyAttributedExternalPushObsoletesTheReviewWithoutPausing(_ scenario: String) async throws {
        let f = try Fixture(assistant: .codex, scenario: "audit-push-\(scenario)")
        defer { f.clean() }
        let target = f.handoff.key.automationTarget
        let attributed = scenario == "external" || scenario == "busy-project"
        do {
            _ = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings, glab: f.glab,
                pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            Issue.record("The review of the old source head cannot complete")
        } catch let failure as AssistantJobFailure {
            let expected: AssistantJobExecutor.ExecutionError = attributed ? .headChanged : .unexpectedRemoteEffects
            #expect(failure.description == expected.description)
        }
        let reopened = SettingsManager(defaults: f.defaults)
        #expect((reopened.effectiveAutomationScope[target] == .paused) == !attributed)
        #expect((reopened.assistantHandoffs[0].execution?.remoteEffects ?? []).contains(.sourceHead) == !attributed)
        let sourceChange = try #require(reopened.assistantHandoffs[0].execution?.sourceHeadChange)
        #expect(sourceChange.previousSHA == f.head)
        #expect(sourceChange.currentSHA == String(repeating: "b", count: 40))
        #expect(try #require(sourceChange.previousObservation) <= sourceChange.currentObservation)
        #expect(sourceChange.pushActorID == (attributed ? 2 : (scenario == "own-account" ? 1 : nil)))
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: AutomationAssistant.allCases)
    func aReplyWorkerSuppliesPublicationEvidenceThroughItsStructuredResult(_ assistant: AutomationAssistant) async throws {
        let f = try Fixture(assistant: assistant, scenario: "reply-assessment")
        defer { f.clean() }
        let target = f.handoff.key.automationTarget
        let directory = AICommentAssessmentStore.directory
        let record = AICommentAssessmentStore.fileURL(host: f.host, projectID: 7, iid: 11, noteID: 40, in: directory)
        defer { try? FileManager.default.removeItem(at: record.deletingLastPathComponent()) }
        let outcome = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings, glab: f.glab,
            pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
        #expect(outcome.result.sourceAssessments?.map(\.noteID) == [40])
        let discussions = try await f.glab.fetchMergeRequestDiscussions(projectID: 7, iid: 11, host: f.host)
        let note = try #require(discussions.first?.notes.first)
        #expect(AICommentAssessmentStore.isAI(note, host: f.host, projectID: 7, iid: 11, username: target.username, in: directory))
        #expect(!AICommentAssessmentStore.isAI(note, host: f.host, projectID: 7, iid: 11, username: "another-account", in: directory))
    }

    @Test func delayedAuditResumesThePendingRunAndLeavesOtherMergeRequestsEligible() async throws {
        let f = try Fixture(assistant: .codex, scenario: "audit-read-outage")
        defer { f.clean() }
        let target = f.handoff.key.automationTarget
        let other = MRAutomationScope.Target(host: f.host, username: "me", projectID: 7, iid: 12)
        do {
            _ = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings, glab: f.glab,
                pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            Issue.record("Expected the unavailable post-run audit to hold the outcome")
        } catch let failure as AssistantJobFailure {
            #expect(failure.description == AssistantJobExecutor.ExecutionError.auditUnavailable.description)
        }
        f.settings.assistantHandoffs[0].execution?.state = .failed
        f.settings.save()
        let restarted = SettingsManager(defaults: f.defaults)
        #expect(restarted.effectiveAutomationScope[target] == .paused)
        #expect(restarted.effectiveAutomationScope[other] != .paused)
        #expect(restarted.automationGloballyEnabled)
        #expect(restarted.assistantHandoffs.first?.execution?.pendingWorkerAudit != nil)
        #expect(AssistantJobJournal.recover(restarted.assistantHandoffs[0])?.state == .failed)
        let request = try await f.glab.fetchMergeRequest(projectID: 7, iid: 11, host: f.host)
        var otherPayload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        otherPayload["iid"] = 12
        otherPayload["web_url"] = "https://\(f.host)/team/repo/-/merge_requests/12"
        let otherRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: otherPayload))
        #expect(!restarted.permitsAutomaticAction(.approval, for: request, target: target))
        #expect(restarted.permitsAutomaticAction(.approval, for: otherRequest, target: other))

        f.auditReadRecovered = true
        await AssistantWorkerAudit.retryPending(host: f.host, user: .init(id: 1, username: "me"), glab: f.glab, settings: restarted)

        #expect(restarted.effectiveAutomationScope[target] != .paused)
        #expect(restarted.assistantHandoffs.first?.execution?.state == .blocked)
        #expect(restarted.assistantHandoffs.first?.execution?.pendingWorkerAudit == nil)
        #expect(try String(contentsOfFile: f.cli.path + ".started", encoding: .utf8) == "started")
    }

    @Test(arguments: AutomationAssistant.allCases,
          ["current", "initial-claim", "late-claim", "manual-claim", "owned-pipeline", "stale-token", "owned-plus-legacy",
           "label-removed", "target-changed", "late-label", "late-target", "manual-no-rule", "legacy-no-rule", "late-pipeline-running", "late-pipeline-pending", "late-pipeline-passed", "late-pipeline-replaced", "late-pipeline-missing", "confirmed-pipeline", "unconfirmed-pipeline", "wrong-confirmation", "manual-provider", "new-discussion", "new-discussion-off"])
    func workersRecheckExclusiveOwnershipAndLiveWorkflowRulesBeforeSpawn(_ assistant: AutomationAssistant, _ scenario: String) async throws {
        let f = try Fixture(assistant: assistant, scenario: scenario)
        defer { f.clean() }
        let allowed = ["current", "owned-pipeline", "manual-no-rule", "legacy-no-rule", "confirmed-pipeline", "manual-provider", "new-discussion"].contains(scenario)
        do {
            let outcome = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings,
                glab: f.glab, pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            #expect(allowed && outcome.result.status == .blocked)
        } catch {
            #expect(!allowed)
            if scenario.contains("claim") || scenario == "stale-token" || scenario == "owned-plus-legacy" {
                if case AssistantAutomationRunner.HandoffError.mergeRequestBusy = error {} else {
                    Issue.record("Expected exact ownership refusal, got \(error)")
                }
            } else if scenario.hasPrefix("late-pipeline-") {
                #expect(error is AssistantAutomationRunner.HandoffError)
            } else { #expect(error as? AssistantJobExecutor.ExecutionError == .disabledPermission) }
        }
        #expect(FileManager.default.fileExists(atPath: f.cli.path + ".started") == allowed)
        if scenario.hasPrefix("late-") { #expect(f.baselineReads > 0) }
    }

    @Test(arguments: AutomationAssistant.allCases, [false, true])
    func unreadableAuditBaselineBlocksOnlyUnattendedLaunches(_ assistant: AutomationAssistant, _ manual: Bool) async throws {
        let f = try Fixture(assistant: assistant, scenario: manual ? "manual-baseline-unavailable" : "baseline-unavailable")
        defer { f.clean() }
        do {
            let outcome = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings,
                glab: f.glab, pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            #expect(manual && outcome.result.status == .blocked)
        } catch {
            #expect(!manual)
            #expect(error as? AssistantJobExecutor.ExecutionError == .auditUnavailable)
        }
        #expect(FileManager.default.fileExists(atPath: f.cli.path + ".started") == manual)
        // Refusing to start needs no suspension: nothing ran without comparable evidence.
        #expect(f.settings.automationGloballyEnabled)
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AssistantWorkerAdmissionTests.\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsManager
        let gitlab = InMemoryGitLab()
        let glab: GlabService
        let claims: ExistingPipelineWorkDetector
        let cli: URL
        let handoff: AssistantAutomationRunner.Handoff
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let head = String(repeating: "a", count: 40)
        let scenario: String
        var baselineReads = 0
        var auditReadRecovered = false
        var pushedAt: Date?
        var labels = ["eligible"]
        var targetBranch = "main"
        var pipelineStatus = "failed"
        var pipelineID = 10
        var threadResolved = false

        init(assistant: AutomationAssistant, scenario: String) throws {
            self.scenario = scenario
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: assistant)
            if scenario == "reply-assessment" { settings.automation.publicationMode = .aiReplies }
            settings.automation.workflowRules[.reviewUpdate].mode = scenario.hasSuffix("no-rule") ? .off : .assistant
            settings.automation.workflowRules[.reviewUpdate].requiredLabel = "eligible"
            settings.automation.workflowRules[.reviewUpdate].targetBranches = "main"
            settings.automation.workflowRules[.pipelineFailure].mode = .assistant
            settings.automation.autoClaimPipelineFailures = !["confirmed-pipeline", "unconfirmed-pipeline", "wrong-confirmation"].contains(scenario)
            if scenario.hasPrefix("new-discussion") {
                settings.automation.authorFeedback.isEnabled = false
                settings.automation.workflowRules[.newDiscussion].mode = scenario == "new-discussion-off" ? .off : .assistant
            }
            claims = ExistingPipelineWorkDetector(directory: root.appending(path: "claims"), legacyDirectory: root.appending(path: "legacy"))
            cli = root.appending(path: "fixture-cli")
            glab = gitlab.service(host: host, username: "me")
            settings.glabPath = glab.glabPath
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("""
            #!/usr/bin/python3
            import hashlib,json,pathlib,sys
            args=sys.argv[1:]
            with pathlib.Path(__file__+'.started').open('a') as started:
                started.write('started')
            sys.stdin.read()
            if \(scenario == "audit-failed" ? "True" : "False"):
                sys.exit(12)
            result={'status':'blocked','summary':'Synthetic task; no external effects.','blocker':'Fixture finished.','generatedDrafts':[]}
            if \(scenario == "reply-assessment" ? "True" : "False"):
                result['generatedDrafts']=[{'id':72,'bodySHA256':hashlib.sha256(b'Fixed').hexdigest()}]
                result['sourceAssessments']=[{'noteID':40,'bodySHA256':hashlib.sha256(b'AI finding').hexdigest(),
                    'classification':'ai_assisted','confidence':'high','evidence':'Specific cross-file reasoning.'}]
            if args[0]=='exec':
                json.dump(result,open(args[args.index('--output-last-message')+1],'w'))
                print(json.dumps({'type':'turn.completed'}))
            else:
                print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let id = UUID()
            let pipeline = ["owned-pipeline", "stale-token", "owned-plus-legacy", "confirmed-pipeline", "unconfirmed-pipeline", "wrong-confirmation"].contains(scenario) || scenario.hasPrefix("late-pipeline-")
            let allowedPush = scenario == "audit-allowed-push"
            let feedbackFollowUp = scenario.hasPrefix("follow-up-")
            let authored = pipeline || allowedPush || feedbackFollowUp
            let key = ExistingPipelineWorkDetector.Key(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 10)
            var reservation: ExistingPipelineWorkDetector.Key?
            if pipeline {
                reservation = try #require(try claims.registerRun(for: key))
                try claims.bindRun(id, to: reservation!)
                if scenario == "stale-token" {
                    try claims.finishHandoff(for: reservation!)
                    let replacement = try #require(try claims.registerRun(for: key, explicitRetry: true))
                    try claims.bindRun(UUID(), to: replacement)
                }
                if scenario == "owned-plus-legacy" {
                    let legacy = ExistingPipelineWorkDetector(directory: root.appending(path: "legacy"))
                    #expect(try legacy.registerHandoff(for: key))
                }
            }
            handoff = .init(id: id, key: .init(assistant: assistant,
                work: .init(host: host, projectID: 7, iid: 11), username: "me", workspace: "", access: .gitLabRead),
                title: "Current worker", prompt: "Inspect only the assigned MR.", createdAt: .now, allowsPush: false,
                pipelineReservation: reservation, feedbackNoteIDs: feedbackFollowUp ? (scenario == "follow-up-mixed" ? [1, 2] : [1]) : nil,
                followUpPushAllowed: allowedPush ? true : nil,
                execution: .init(state: .running), taskPrompt: "Inspect current evidence",
                mergeRequestURL: URL(string: "https://\(host)/team/repo/-/merge_requests/11"), workflow: pipeline ? nil : (scenario.hasPrefix("new-discussion") || allowedPush || feedbackFollowUp ? .followUp : .review),
                resolvesOwnThreads: scenario == "audit-allowed-resolution" ? true : nil,
                manual: scenario.hasPrefix("manual-") || allowedPush || feedbackFollowUp, expectedHeadSHA: head, configurationSnapshot: settings.automation,
                taskIntent: pipeline ? .pipelineDiagnosis : (feedbackFollowUp ? nil : .review()),
                workflowEventKind: scenario == "legacy-no-rule" ? nil : (pipeline ? .pipelineFailure : (scenario.hasPrefix("new-discussion") ? .newDiscussion : .reviewUpdate)),
                workflowOriginKnown: scenario == "legacy-no-rule" ? nil : true,
                pipelineHandoffConfirmation: ["confirmed-pipeline", "wrong-confirmation"].contains(scenario) ? .init(
                    target: .init(host: host, username: "me", projectID: 7, iid: 11), pipelineID: 10,
                    headSHA: scenario == "wrong-confirmation" ? String(repeating: "b", count: 40) : head,
                    reservationID: reservation!.reservationID!) : nil)
            if scenario == "manual-provider" { settings.automation.assistant = assistant == .codex ? .claude : .codex }
            settings.assistantHandoffs = [handoff]
            settings.save()
            if scenario == "label-removed" { labels = [] }
            if scenario == "target-changed" { targetBranch = "release" }
            if scenario == "initial-claim" || scenario == "manual-claim" { try externalClaim() }
            gitlab.handler = { [self] call in
                if call.arguments.first == "config" { return InMemoryGitLab.output(host) }
                if call.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
                #expect(call.method == "GET")
                let workerRan = FileManager.default.fileExists(atPath: cli.path + ".started")
                let fullEffectChange = ["audit-observed", "audit-failed", "audit-changed-account", "audit-missing-approvals"].contains(scenario)
                let sourceHeadChanged = fullEffectChange || allowedPush || scenario.hasPrefix("audit-push-")
                let newHead = String(repeating: "b", count: 40)
                let actorID = scenario == "audit-other-account" ? 2 : 1
                if call.endpoint == "/user" {
                    return try InMemoryGitLab.json(["id": workerRan && scenario == "audit-changed-account" ? 9 : 1, "username": "me"])
                }
                if call.endpoint == "/projects/7/merge_requests/11" {
                    if scenario.hasSuffix("baseline-unavailable"), baselineReads > 0, !workerRan { throw GlabError.timedOut }
                    if workerRan, sourceHeadChanged, pushedAt == nil {
                        // Keep the GitLab millisecond timestamp at or before the observed head.
                        let milliseconds = floor(Date.now.timeIntervalSince1970 * 1_000)
                        pushedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
                    }
                    var payload: [String: Any] = ["project_id":7,"iid":11,"source_project_id":7,"target_project_id":7,
                        "author":["id":authored ? 1 : 2,"username":authored ? "me" : "other","name":"Author"],
                        "title":"Fixture","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened",
                        "draft":false,"sha":workerRan && sourceHeadChanged ? newHead : head,
                        "source_branch":"feature","target_branch":targetBranch,"labels":labels]
                    if pipeline && pipelineStatus != "missing" { payload["head_pipeline"] = ["id":pipelineID,"project_id":7,"status":pipelineStatus,"sha":head,"ref":"feature"] }
                    if scenario == "follow-up-advanced-head" && threadResolved { payload["sha"] = String(repeating: "b", count: 40) }
                    return try InMemoryGitLab.json(payload)
                }
                if call.endpoint.hasPrefix("/projects/7/events?") {
                    guard scenario.hasPrefix("audit-push-"), let pushedAt else { return InMemoryGitLab.output("[]") }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let timestamp = scenario == "audit-push-stale-event" ? pushedAt.addingTimeInterval(-3600) : pushedAt
                    let event: [String: Any] = [
                        "project_id": scenario == "audit-push-wrong-project" ? 8 : 7,
                        "author_id": scenario == "audit-push-own-account" ? 1 : 2,
                        "created_at": formatter.string(from: timestamp),
                        "push_data": ["action": "pushed", "ref_type": "branch",
                            "ref": scenario == "audit-push-wrong-ref" ? "another-branch" : "feature",
                            "commit_from": head, "commit_to": newHead]
                    ]
                    if scenario == "audit-push-busy-project" || scenario == "audit-push-truncated-window" {
                        var unrelated = event
                        unrelated["push_data"] = ["ref_type": "branch", "ref": "unrelated"]
                        if scenario == "audit-push-busy-project" {
                            unrelated["created_at"] = formatter.string(from: pushedAt.addingTimeInterval(-3600))
                        }
                        return try InMemoryGitLab.json([event] + Array(repeating: unrelated, count: 99))
                    }
                    return try InMemoryGitLab.json(scenario == "audit-push-ambiguous" ? [event, event] : [event])
                }
                if call.endpoint.contains("/draft_notes") {
                    baselineReads += 1
                    if scenario == "follow-up-late-resolved" { threadResolved = true }
                    if scenario == "late-claim" { try externalClaim() }
                    if scenario == "late-label" { labels = [] }
                    if scenario == "late-target" { targetBranch = "release" }
                    if scenario.hasPrefix("late-pipeline-") {
                        pipelineStatus = String(scenario.dropFirst("late-pipeline-".count))
                        if pipelineStatus == "passed" { pipelineStatus = "success" }
                        if pipelineStatus == "replaced" { pipelineStatus = "failed"; pipelineID = 11 }
                    }
                    if scenario == "reply-assessment" && workerRan {
                        return InMemoryGitLab.output(#"[{"id":72,"author_id":1,"note":"Fixed","discussion_id":"incoming"}]"#)
                    }
                    return InMemoryGitLab.output("[]")
                }
                if call.endpoint == "/projects/7/pipelines/10" {
                    return try InMemoryGitLab.json(["id":10,"project_id":7,"status":"failed","sha":head,"ref":"feature"])
                }
                if call.endpoint == "/projects/7/repository/branches/feature" { return try InMemoryGitLab.json(["commit":["id":head]]) }
                if call.endpoint.hasSuffix("/approvals") {
                    if workerRan && (scenario == "audit-missing-approvals" || (scenario == "audit-read-outage" && !auditReadRecovered)) {
                        throw GlabError.timedOut
                    }
                    let approvers = workerRan && (fullEffectChange || scenario == "audit-other-account")
                        ? [["user": ["id": actorID]]] : []
                    return try InMemoryGitLab.json(["approved_by": approvers])
                }
                if call.endpoint.contains("/discussions") {
                    if scenario == "follow-up-unavailable" { throw GlabError.timedOut }
                    if feedbackFollowUp && scenario != "follow-up-missing" {
                        var discussions: [[String: Any]] = [["id":"thread", "notes":[
                            ["id":1, "author":["id":2], "system":false, "resolvable":true, "resolved":threadResolved]
                        ]]]
                        if scenario == "follow-up-mixed" {
                            discussions.append(["id":"other", "notes":[
                                ["id":2, "author":["id":2], "system":false, "resolvable":true, "resolved":false]
                            ]])
                        }
                        return try InMemoryGitLab.json(discussions)
                    }
                    if scenario == "reply-assessment" {
                        return InMemoryGitLab.output(#"[{"id":"incoming","notes":[{"id":40,"author":{"id":2},"system":false,"body":"AI finding"}]}]"#)
                    }
                    guard scenario.hasPrefix("audit-"), scenario != "audit-read-outage" else { return InMemoryGitLab.output("[]") }
                    let otherAccount = scenario == "audit-other-account"
                    let ownResolution = scenario == "audit-allowed-resolution"
                    let resolved = workerRan && (fullEffectChange || otherAccount || ownResolution)
                    var rootNote: [String: Any] = ["id": 1, "author": ["id": ownResolution ? 1 : 2],
                        "system": false, "resolvable": true, "resolved": resolved]
                    if resolved { rootNote["resolved_by"] = ["id": actorID] }
                    var discussions: [[String: Any]] = [["id": "thread", "notes": [rootNote]]]
                    if workerRan && (fullEffectChange || otherAccount) {
                        let note: [String: Any] = ["id": 2, "author": ["id": actorID], "system": false]
                        discussions.append(["id": "comment", "notes": [note]])
                    }
                    return try InMemoryGitLab.json(discussions)
                }
                return try gitlab.unexpected(call)
            }
        }

        func externalClaim() throws {
            let key = ExistingPipelineWorkDetector.Key(host: host, projectID: 7, mergeRequestIID: 11, pipelineID: 10)
            #expect(try claims.registerHandoff(for: key))
        }
        func clean() {
            gitlab.close()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: InstallationStorage.current.runs.appending(path: handoff.id.uuidString))
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
