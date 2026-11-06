import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct MergeRequestTodoRoutingTests {
    private final class Readiness { var ready = false }
    private final class ProbeGate {
        var entered = false
        var continuation: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool {
            entered = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: false); continuation = nil }
    }

    private struct Fixture {
        let settings: SettingsManager
        let defaults: UserDefaults
        let suite: String
        let root: URL
        let glab: GlabService
        func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(owned: Bool = false, acknowledgementFails: Bool = false) throws -> Fixture {
        let suite = "MRTodoRoutingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsManager(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appending(path: "MRTodoRoutingTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "glab")
        let script = """
        #!/bin/sh
        root="${0%/*}"
        if [ "$2" = --method ]; then
          printf '%s\\n' "$4" >> "$root/acks"
          [ -f "$root/fail-ack" ] && exit 1
          printf '{}'; exit 0
        fi
        case "$2" in
          /user) printf '%s' '{"id":1,"username":"me"}' ;;
          */discussions*) cat "$root/discussions" ;;
          */merge_requests/11) cat "$root/mr" ;;
          *) exit 2 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let author = owned ? "me" : "other"
        let id = owned ? 1 : 2
        let request = """
        {"project_id":7,"iid":11,"author":{"id":\(id),"username":"\(author)","name":"Example"},
         "title":"Example MR","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11",
         "state":"opened","sha":"\(String(repeating: "a", count: 40))","source_project_id":7,
         "source_branch":"feature","target_branch":"main","draft":false,"labels":[],"has_conflicts":false}
        """
        try request.write(to: root.appending(path: "mr"), atomically: true, encoding: .utf8)
        try "[]".write(to: root.appending(path: "discussions"), atomically: true, encoding: .utf8)
        if acknowledgementFails { try Data().write(to: root.appending(path: "fail-ack")) }
        let glab = GlabService()
        glab.glabPath = executable; glab.resolvedHost = "gitlab.example.test"; glab.currentUsername = "me"
        return .init(settings: settings, defaults: defaults, suite: suite, root: root, glab: glab)
    }

    private var target: MRAutomationScope.Target { .init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11) }
    private func todo(_ id: Int = 10, action: ActionName = .reviewRequested, linked: Bool = false,
                      suffix: String = "", url: URL? = nil) -> Todo {
        .init(id: id, actionName: action, targetType: .mergeRequest,
              targetURL: url ?? URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11" + suffix + (linked ? "#note_42" : ""))!,
              body: "Event", createdAt: Date(timeIntervalSince1970: 100), state: "pending",
              project: .init(id: 7, nameWithNamespace: "Team / Repo", pathWithNamespace: "team/repo"),
              author: .init(id: 2, username: "other", name: "Other", avatarURL: nil),
              target: .init(id: 11, iid: 11, title: "Example MR", state: "opened", draft: false, workInProgress: false))
    }

    @Test func managedReviewEventIsPersistedBeforeAcknowledgementAndSurvivesRestartWithoutLaunchingAI() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let event = todo()
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [target])
        #expect(acknowledged == [event.id])
        #expect(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.mrActionIntents[0].kind == .review)
        #expect(f.settings.mrActionIntents[0].state == .pending)
        let restored = SettingsManager(defaults: f.defaults)
        #expect(restored.mrActionIntents.count == 1)
        #expect(restored.routedMRTodoReceipts.count == 1)
        let afterRestart = MergeRequestTodoRouter(settings: restored, glab: f.glab, canAutomate: { false })
        _ = await afterRestart.process([event], host: target.host, username: target.username, managed: [target])
        #expect(restored.mrActionIntents.count == 1)
    }

    @Test func pendingReviewRequestsAcrossHeadsBecomeOneCurrentReviewAction() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        _ = await router.process([todo(10)], host: target.host, username: target.username, managed: [target])
        let file = f.root.appending(path: "mr")
        let updated = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40))
        try updated.write(to: file, atomically: true, encoding: .utf8)
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.mrActionIntents[0].todoIDs == [10, 20])
        #expect(f.settings.mrActionIntents[0].headSHA == String(repeating: "b", count: 40))
    }

    @Test func unknownEventOnManagedMRRemainsUnreadWhileKnownEventRoutes() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true })
        let known = todo(), unknown = todo(20, action: .unknown("new_event"))
        let acknowledged = await router.process([known, unknown], host: target.host, username: target.username, managed: [target])
        #expect(acknowledged == [known.id])
        #expect(f.settings.mrActionIntents.flatMap(\.todoIDs) == [known.id])
        let calls = try String(contentsOf: f.root.appending(path: "acks"), encoding: .utf8)
        #expect(!calls.contains("/20/"))
    }

    @Test func automaticAdoptionRequiresEnabledHandlerReadyCLIAndUnpausedScope() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let readiness = Readiness()
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { readiness.ready }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [])
        #expect(f.settings.mrActionIntents.isEmpty)
        f.settings.automation.reviewRequested.isEnabled = true
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [])
        #expect(f.settings.mrActionIntents.isEmpty)
        readiness.ready = true
        f.settings.automation.scope[target] = .paused
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [])
        #expect(f.settings.mrActionIntents.isEmpty)
        f.settings.automation.scope[target] = .inherit
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [])
        #expect(f.settings.automation.scope[target] == .active)
        #expect(f.settings.mrActionIntents.count == 1)
        #expect(launches == 1)
        #expect(f.settings.mrActionIntents[0].state == .running)
    }

    @Test func acknowledgementFailureAndCompletedWorkerNeverReplayAcceptedEvent() async throws {
        let f = try fixture(acknowledgementFails: true); defer { f.cleanup() }
        var launches = 0
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        let event = todo()
        #expect(await router.process([event], host: target.host, username: target.username, managed: [target]).isEmpty)
        #expect(f.settings.routedMRTodoReceipts.count == 1)
        #expect(f.settings.mrActionIntents.count == 1)
        f.settings.mrActionIntents[0].state = .completed; f.settings.save()
        try FileManager.default.removeItem(at: f.root.appending(path: "fail-ack"))
        let restored = SettingsManager(defaults: f.defaults)
        let restarted = MergeRequestTodoRouter(settings: restored, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        let acknowledged = await restarted.process([event], host: target.host, username: target.username, managed: [target])
        #expect(acknowledged == [event.id])
        #expect(restored.mrActionIntents.count == 1)
        #expect(launches == 1)
    }

    @Test func discussionMentionNeedsLiveUnresolvedFeedbackEvenWhenTargetAuthorIsMissing() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let event = todo(action: .mentioned, linked: true)
        #expect(await router.process([event], host: target.host, username: target.username, managed: []).isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"resolvable":true,"resolved":false,"body":"Please fix this."}]}]"#
            .write(to: f.root.appending(path: "discussions"), atomically: true, encoding: .utf8)
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])
        #expect(acknowledged == [event.id])
        #expect(f.settings.mrActionIntents[0].kind == .followUp)
        #expect(f.settings.mrActionIntents[0].noteIDs == [42])
    }
    @Test func newEventDuringRunningReviewRemainsASeparatePendingAction() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var launches = 0
        var activeJob: UUID?
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, _ in
            launches += 1
            let id = UUID(); activeJob = id
            f.settings.assistantHandoffs.append(.init(id: id,
                key: .init(assistant: .codex, work: .init(host: intent.target.host, projectID: 7, iid: 11),
                           username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
                createdAt: Date(), allowsPush: false, feedbackTodos: intent.sourceEvents,
                execution: .init(state: .running), workflow: .review, expectedHeadSHA: intent.headSHA))
            return id
        })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents.count == 2)
        #expect(f.settings.mrActionIntents[0].jobID == activeJob)
        #expect(f.settings.mrActionIntents[1].state == .pending)
        #expect(f.settings.mrActionIntents[1].jobID == nil)
        #expect(launches == 1)
    }

    @Test func legacyAttemptIsReceivedButRequiresExplicitManualRun() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let event = todo()
        f.settings.automation.reviewRequested.isEnabled = true
        f.settings.automationAttemptReceipts.insert(.init(host: target.host, username: target.username, todoID: event.id))
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        _ = await router.process([event], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(launches == 0)
        await router.run(f.settings.mrActionIntents[0].id, manual: true)
        #expect(launches == 1)
    }

    @Test func mismatchedLiveMergeRequestIdentityRemainsUnread() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var object = try #require(decoded as? [String: Any])
        object["web_url"] = "https://another.example.test/team/repo/-/merge_requests/11"
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let ack = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        #expect(ack.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "acks").path))
    }

    @Test func interruptedRunWithUnboundIntentIsNeverAutomaticallyReplayed() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        let intent = try #require(f.settings.mrActionIntents.first)
        f.settings.assistantHandoffs.append(.init(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, feedbackTodos: intent.sourceEvents,
            execution: .init(state: .interrupted), workflow: .review, expectedHeadSHA: intent.headSHA))
        f.settings.automation.reviewRequested.isEnabled = true
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(launches == 0)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        await router.run(intent.id, manual: true)
        #expect(launches == 1)
    }

    @Test func missingRunAndChangedHeadSuccessBecomeVisibleFailures() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .failed)
        let intent = f.settings.mrActionIntents[0]
        let id = try #require(intent.jobID)
        f.settings.assistantHandoffs.append(.init(id: id,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, feedbackTodos: intent.sourceEvents, execution: .init(state: .succeeded), workflow: .review, expectedHeadSHA: intent.headSHA))
        f.settings.mrActionIntents[0].state = .running
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var object = try #require(decoded as? [String: Any]); object["sha"] = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .failed)
        await router.run(intent.id, manual: true)
        #expect(launches == 2)
        #expect(f.settings.mrActionIntents[0].jobID != id)
        #expect(f.settings.mrActionIntents[0].headSHA == String(repeating: "b", count: 40))
    }

    @Test func legacyAttemptCannotBeCoalescedIntoANewAutomaticAction() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        f.settings.automationAttemptReceipts.insert(.init(host: target.host, username: target.username, todoID: 10))
        var launchedTodoIDs: Set<Int> = []
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, _ in
            launchedTodoIDs.formUnion(intent.todoIDs); return UUID()
        })
        _ = await router.process([todo(20), todo(10)], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents.count == 2)
        #expect(launchedTodoIDs == [20])
        #expect(f.settings.mrActionIntents.first { $0.todoIDs.contains(10) }?.state == .failed)
    }

    @Test func accountChangeDuringReadinessCheckPreventsAdoptionAndAcknowledgement() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: {
            f.glab.currentUsername = "another-account"; return true
        })
        let acknowledged = await router.process([todo()], host: target.host, username: target.username, managed: [])
        #expect(acknowledged.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "acks").path))
    }

    @Test("configured assistant restrictions and title placeholders survive semantic routing", arguments: [MRTodoIntent.Kind.review, .followUp])
    func configuredInstructionsArePreserved(kind: MRTodoIntent.Kind) throws {
        let f = try fixture(owned: kind == .followUp); defer { f.cleanup() }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(contentsOf: f.root.appending(path: "mr")))
        let event = todo(action: kind == .review ? .reviewRequested : .mentioned)
        let intent = MRTodoIntent(id: UUID(), target: target, kind: kind, state: .pending, todoIDs: [event.id], noteIDs: [],
            sourceEvents: [event.feedbackIdentity], request: request, headSHA: request.sha!, updatedAt: Date(), sourceTodo: event)
        var configuration = f.settings.automation
        let task: TodoAutomationEvent = kind == .review ? .reviewRequested : .authorFeedback
        var rule = configuration[task]
        rule.promptTemplate = "Do not push. Restrict work to {project}; inspect {url} for {actorUsername}."
        rule.titleTemplate = "{repo} !{iid}"
        if task == .reviewRequested { configuration.reviewRequested = rule }
        else { configuration.authorFeedback = rule }
        let rendered = MergeRequestTodoRouter.configuredAssistantContext(intent, configuration: configuration)
        #expect(rendered.instructions.contains("Do not push."))
        #expect(rendered.instructions.contains("Restrict work to team/repo"))
        #expect(rendered.instructions.contains(event.targetURL.absoluteString))
        #expect(rendered.instructions.contains("for other."))
        #expect(rendered.title == "repo !11")
    }

    @Test func configuredShellActionIsNotSilentlyReplacedWithGenericAI() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.reviewRequested.runner = .shell
        f.settings.automation.reviewRequested.command = "echo manual"
        f.settings.automation.reviewRequested.projects = "team/repo"
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        let intent = try #require(f.settings.mrActionIntents.first)
        await router.run(intent.id, manual: true)
        #expect(launches == 0)
        #expect(f.settings.mrActionIntents[0].state == .failed)
    }

    @Test func jobControlsRetryRebindsOnlyUnfinishedIntentsToReplacementRun() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        let oldID = UUID(), newID = UUID()
        f.settings.mrActionIntents[0].jobID = oldID
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Old failure"
        let original = f.settings.mrActionIntents[0]
        f.settings.mrActionIntents.append(.init(id: UUID(), target: target, kind: .review, state: .completed,
            todoIDs: [], noteIDs: [], sourceEvents: [], request: original.request, headSHA: original.headSHA,
            jobID: oldID, updatedAt: Date()))
        let replacement = AssistantAutomationRunner.Handoff(id: newID,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Retry", prompt: "Retry",
            createdAt: Date(), allowsPush: false, execution: .init(state: .queued), expectedHeadSHA: "new-head")
        router.rebindJob(oldID: oldID, replacement: replacement)
        #expect(f.settings.mrActionIntents[0].jobID == newID)
        #expect(f.settings.mrActionIntents[0].state == .running)
        #expect(f.settings.mrActionIntents[0].headSHA == "new-head")
        #expect(f.settings.mrActionIntents[0].error == nil)
        #expect(f.settings.mrActionIntents[1].jobID == oldID)
        #expect(f.settings.mrActionIntents[1].state == .completed)
    }

    @Test func failedPipelineLaunchWithoutJobIDCanExplicitlyReacquireItsReceipt() throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var object = try #require(decoded as? [String: Any])
        object["head_pipeline"] = ["id": 100, "project_id": 7, "sha": String(repeating: "a", count: 40), "status": "failed"]
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        var intent = MRTodoIntent(id: UUID(), target: target, kind: .pipeline, state: .pending, todoIDs: [], noteIDs: [],
            sourceEvents: [], request: request, headSHA: request.sha!, updatedAt: Date())
        let detector = ExistingPipelineWorkDetector(directory: f.root.appending(path: "claims"))
        let firstClaim = try MergeRequestTodoRouter.reservePipeline(for: intent, manual: true, detector: detector)
        let first = try #require(firstClaim)
        try detector.finishHandoff(for: first)
        intent.state = .failed
        #expect(intent.jobID == nil)
        let retryClaim = try MergeRequestTodoRouter.reservePipeline(for: intent, manual: true, detector: detector)
        let retry = try #require(retryClaim)
        #expect(retry.reservationID != first.reservationID)
        try detector.finishHandoff(for: retry)
    }

    @Test("live GitLab resolution clears local actions while retaining failed execution history", arguments: [MRTodoIntent.Kind.review, .pipeline, .conflict])
    func resolvedLiveStateClearsFailedIntent(kind: MRTodoIntent.Kind) async throws {
        let f = try fixture(owned: kind != .review); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var object = try #require(decoded as? [String: Any])
        if kind == .pipeline { object["head_pipeline"] = ["id": 100, "project_id": 7, "sha": String(repeating: "a", count: 40), "status": "failed"] }
        if kind == .conflict { object["has_conflicts"] = true }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let action: ActionName = kind == .pipeline ? .buildFailed : (kind == .conflict ? .unmergeable : .reviewRequested)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        _ = await router.process([todo(action: action)], host: target.host, username: target.username, managed: [target])
        let intent = try #require(f.settings.mrActionIntents.first)
        let jobID = UUID()
        f.settings.mrActionIntents[0].jobID = jobID
        f.settings.mrActionIntents[0].state = .failed
        f.settings.assistantHandoffs.append(.init(id: jobID,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Failed", prompt: "Failed",
            createdAt: Date(), allowsPush: false, execution: .init(state: .failed), expectedHeadSHA: intent.headSHA))
        if kind == .pipeline { object["head_pipeline"] = ["id": 100, "project_id": 7, "sha": String(repeating: "a", count: 40), "status": "success"] }
        else if kind == .conflict { object["has_conflicts"] = false }
        else { object["state"] = "closed" }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.assistantHandoffs[0].execution?.state == .failed)
    }

    @Test func ownedFailedPipelineTabEventRoutesToCanonicalMRAction() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        var request = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        request["head_pipeline"] = ["id": 99, "project_id": 7, "status": "failed", "sha": String(repeating: "a", count: 40)]
        try JSONSerialization.data(withJSONObject: request).write(to: file)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let event = todo(action: .buildFailed, suffix: "/pipelines")

        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])

        #expect(acknowledged == [event.id])
        let intent = try #require(f.settings.mrActionIntents.first)
        #expect(intent.kind == .pipeline)
        #expect(intent.request.webURL.absoluteString == "https://gitlab.example.test/team/repo/-/merge_requests/11")
        #expect(intent.state == .pending)
    }

    @Test(arguments: ["/pipelines/extra", "/pipelines/pipelines", "/notes"])
    func pipelineEventWithUnexpectedAdditionalPathStaysUnread(suffix: String) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let acknowledged = await router.process([todo(suffix: suffix)], host: target.host,
            username: target.username, managed: [target])
        #expect(acknowledged.isEmpty && f.settings.mrActionIntents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "acks").path))
    }

    @Test(arguments: ["https://other.example.test/team/repo/-/merge_requests/11/pipelines",
                      "https://gitlab.example.test/team/repo/-/merge_requests/12/pipelines"])
    func pipelineEventWithDifferentHostOrIIDStaysUnread(address: String) async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let url = try #require(URL(string: address))
        let event = todo(url: url)
        #expect(await router.process([event], host: target.host, username: target.username, managed: [target]).isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
    }

    @Test func newEventCannotCoalesceIntoUnboundIntentWithAnInterruptedAttempt() async throws {
        let f = try fixture(); defer { f.cleanup() }
        var launchedIDs: Set<Int> = []
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, _ in
            launchedIDs.formUnion(intent.todoIDs); return UUID()
        })
        _ = await router.process([todo(10)], host: target.host, username: target.username, managed: [target])
        let original = f.settings.mrActionIntents[0]
        f.settings.assistantHandoffs.append(.init(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Interrupted", prompt: "Interrupted",
            createdAt: Date(), allowsPush: false, feedbackTodos: original.sourceEvents,
            execution: .init(state: .interrupted), expectedHeadSHA: original.headSHA))
        f.settings.automation.reviewRequested.isEnabled = true
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents.count == 2)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(launchedIDs == [20])
    }

    @Test func explicitRoutingPassWaitsForAnAlreadyRunningRefresh() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let gate = ProbeGate()
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: {
            if !gate.entered { return await gate.wait() }
            return false
        })
        let refresh = Task { await router.process([todo(10)], host: target.host, username: target.username, managed: []) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(gate.entered)
        let explicit = Task { await router.process([todo(20)], host: target.host, username: target.username, managed: [target]) }
        try await Task.sleep(for: .milliseconds(10))
        gate.release()
        _ = await refresh.value
        let received = await explicit.value
        #expect(received == [20])
        #expect(f.settings.mrActionIntents.contains { $0.todoIDs.contains(20) })
    }

    @Test func ignoringMRWhileManualLaunchAwaitsCancelsTheReturnedJob() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let jobID = UUID()
        var cancelled: UUID?
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, _ in
            f.settings.ignoredMergeRequests.insert(intent.target)
            return jobID
        }, cancelJob: { id, _ in cancelled = id })
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        let intentID = f.settings.mrActionIntents[0].id
        await router.run(intentID, manual: true)
        #expect(cancelled == jobID)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(f.settings.mrActionIntents[0].jobID == jobID)
    }

    @Test func newEventDoesNotCoalesceWhileTheOriginalActionIsAwaitingLaunch() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let gate = ProbeGate()
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            _ = await gate.wait(); return UUID()
        })
        _ = await router.process([todo(10)], host: target.host, username: target.username, managed: [target])
        let originalID = f.settings.mrActionIntents[0].id
        let manual = Task { await router.run(originalID, manual: true) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(gate.entered)
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        gate.release()
        await manual.value
        #expect(f.settings.mrActionIntents.count == 2)
        #expect(f.settings.mrActionIntents[0].todoIDs == [10])
        #expect(f.settings.mrActionIntents[1].todoIDs == [20])
        #expect(f.settings.mrActionIntents[1].jobID == nil)
    }

    @Test func cancellingAQueuedRoutingPassDoesNotBlockLaterPasses() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let gate = ProbeGate()
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: {
            if !gate.entered { return await gate.wait() }
            return false
        })
        let refresh = Task { await router.process([todo(10)], host: target.host, username: target.username, managed: []) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        let cancelled = Task { await router.process([todo(20)], host: target.host, username: target.username, managed: [target]) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        #expect(cancelledResult.isEmpty)
        gate.release()
        _ = await refresh.value
        let next = await router.process([todo(30)], host: target.host, username: target.username, managed: [target])
        #expect(next == [30])
    }

    @Test func mismatchedPipelineSHAIsReceivedAsRefreshWithoutStartingWork() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var request = try #require(decoded as? [String: Any])
        request["head_pipeline"] = ["id": 99, "project_id": 7, "status": "failed", "sha": String(repeating: "b", count: 40)]
        try JSONSerialization.data(withJSONObject: request).write(to: file)
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        let event = todo(action: .buildFailed, suffix: "/pipelines")
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])
        #expect(acknowledged == [event.id])
        let intent = try #require(f.settings.mrActionIntents.first)
        #expect(intent.kind == .refresh)
        #expect(intent.state == .completed)
        #expect(intent.jobID == nil)
        #expect(launches == 0)
    }

    @Test("pipeline events without a usable source SHA remain unread", arguments: [false, true])
    func missingPipelineSHARemainsUnknown(includeEmptySHA: Bool) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        var request = try #require(decoded as? [String: Any])
        var pipeline: [String: Any] = ["id": 99, "status": "failed"]
        if includeEmptySHA { pipeline["sha"] = "" }
        request["head_pipeline"] = pipeline
        try JSONSerialization.data(withJSONObject: request).write(to: file)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let acknowledged = await router.process([todo(action: .buildFailed, suffix: "/pipelines")],
                                                host: target.host, username: target.username, managed: [target])
        #expect(acknowledged.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
    }

}
