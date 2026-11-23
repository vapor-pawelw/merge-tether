import Foundation
import Testing
@testable import MergeTether

@MainActor
struct AssistantWorkerAdmissionTests {
    @Test(arguments: AutomationAssistant.allCases, ["observed", "failed", "other-account", "changed-account", "allowed-resolution", "allowed-push", "missing-approvals"])
    func recordsGitLabChangesAroundTheWorkerWithoutChangingItsOutcome(_ assistant: AutomationAssistant, _ scenario: String) async throws {
        let f = try Fixture(assistant: assistant, scenario: "audit-\(scenario)")
        defer { f.clean() }
        do {
            let outcome = try await AssistantJobExecutor.execute(f.handoff, settings: f.settings,
                glab: f.glab, pipelineWorkDetector: f.claims, detectCLI: { _ in .ready(f.cli) })
            #expect(scenario != "failed" && outcome.result.status == .blocked)
        } catch {
            #expect(scenario == "failed" && error is AssistantJobFailure)
        }

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
        var labels = ["eligible"]
        var targetBranch = "main"
        var pipelineStatus = "failed"
        var pipelineID = 10

        init(assistant: AutomationAssistant, scenario: String) throws {
            self.scenario = scenario
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: assistant)
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
            import json,pathlib,sys
            args=sys.argv[1:]
            pathlib.Path(__file__+'.started').write_text('started')
            sys.stdin.read()
            if \(scenario == "audit-failed" ? "True" : "False"):
                sys.exit(12)
            result={'status':'blocked','summary':'Synthetic task; no external effects.','blocker':'Fixture finished.','generatedDrafts':[]}
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
            let authored = pipeline || allowedPush
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
                pipelineReservation: reservation, followUpPushAllowed: allowedPush ? true : nil,
                execution: .init(state: .running), taskPrompt: "Inspect current evidence",
                mergeRequestURL: URL(string: "https://\(host)/team/repo/-/merge_requests/11"), workflow: pipeline ? nil : (scenario.hasPrefix("new-discussion") || allowedPush ? .followUp : .review),
                resolvesOwnThreads: scenario == "audit-allowed-resolution" ? true : nil,
                manual: scenario.hasPrefix("manual-") || allowedPush, expectedHeadSHA: head, configurationSnapshot: settings.automation,
                taskIntent: pipeline ? .pipelineDiagnosis : .review(),
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
                let actorID = scenario == "audit-other-account" ? 2 : 1
                if call.endpoint == "/user" {
                    return try InMemoryGitLab.json(["id": workerRan && scenario == "audit-changed-account" ? 9 : 1, "username": "me"])
                }
                if call.endpoint == "/projects/7/merge_requests/11" {
                    var payload: [String: Any] = ["project_id":7,"iid":11,"source_project_id":7,"target_project_id":7,
                        "author":["id":authored ? 1 : 2,"username":authored ? "me" : "other","name":"Author"],
                        "title":"Fixture","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened",
                        "draft":false,"sha":workerRan && (fullEffectChange || allowedPush) ? String(repeating: "b", count: 40) : head,
                        "source_branch":"feature","target_branch":targetBranch,"labels":labels]
                    if pipeline && pipelineStatus != "missing" { payload["head_pipeline"] = ["id":pipelineID,"project_id":7,"status":pipelineStatus,"sha":head,"ref":"feature"] }
                    return try InMemoryGitLab.json(payload)
                }
                if call.endpoint.contains("/draft_notes") {
                    baselineReads += 1
                    if scenario == "late-claim" { try externalClaim() }
                    if scenario == "late-label" { labels = [] }
                    if scenario == "late-target" { targetBranch = "release" }
                    if scenario.hasPrefix("late-pipeline-") {
                        pipelineStatus = String(scenario.dropFirst("late-pipeline-".count))
                        if pipelineStatus == "passed" { pipelineStatus = "success" }
                        if pipelineStatus == "replaced" { pipelineStatus = "failed"; pipelineID = 11 }
                    }
                    return InMemoryGitLab.output("[]")
                }
                if call.endpoint == "/projects/7/pipelines/10" {
                    return try InMemoryGitLab.json(["id":10,"project_id":7,"status":"failed","sha":head,"ref":"feature"])
                }
                if call.endpoint == "/projects/7/repository/branches/feature" { return try InMemoryGitLab.json(["commit":["id":head]]) }
                if call.endpoint.hasSuffix("/approvals") {
                    if scenario == "audit-missing-approvals" && !workerRan { throw GlabError.timedOut }
                    let approvers = workerRan && (fullEffectChange || scenario == "audit-other-account")
                        ? [["user": ["id": actorID]]] : []
                    return try InMemoryGitLab.json(["approved_by": approvers])
                }
                if call.endpoint.contains("/discussions") {
                    guard scenario.hasPrefix("audit-") else { return InMemoryGitLab.output("[]") }
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
