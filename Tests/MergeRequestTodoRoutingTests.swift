import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct MergeRequestTodoRoutingTests {
    @Test(arguments: [AutomationPackageDecision.undecided, .disabled])
    func missingConsentKeepsAutomaticRoutingUnreadWhileManualAcceptanceRemainsAvailable(_ decision: AutomationPackageDecision) async throws {
        // given
        let f = try fixture(consent: decision); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1
            return UUID()
        })
        let event = todo()

        // when
        let automatic = await router.process([event], host: target.host, username: target.username, managed: [target])

        // then
        #expect(automatic.isEmpty && f.settings.mrActionIntents.isEmpty)
        #expect(f.settings.routedMRTodoReceipts.isEmpty && !f.gitlab.has("acks") && launches == 0)
        let manual = await router.process([event], host: target.host, username: target.username, managed: [target], automatically: false)
        #expect(manual == [event.id])
        let intent = try #require(f.settings.mrActionIntents.first)
        #expect(intent.state == .pending && launches == 0)
        await router.run(intent.id, manual: true)
        #expect(launches == 1 && f.settings.automation.packageDecision == decision)
    }

    @Test(arguments: ["ignoredOnly", "sameNoteRemaining", "restored"])
    func unboundFollowUpCanUseOnlyACurrentExactConcernDecision(_ scenario: String) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: false)
        f.settings.mrActionIntents[0].jobID = nil
        f.settings.mrActionIntents[0].state = .pending
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: f.gitlab.data("discussions"))
        let note = try #require(discussions.first?.notes.first)
        let decision = IgnoredFeedbackSuggestion(id: UUID(), target: target, sourceNoteID: note.id!, sourceAuthorID: note.author!.id,
            sourceBody: note.body!, sourceRevision: UserAttentionSnapshot.digest("\(note.author!.id)\n" + note.body!),
            concernSummary: "Decline this specific assumption.", concernReason: "All other comment obligations remain.", createdAt: Date())
        if scenario != "restored" {
            f.settings.feedbackSuggestionDecisions = try JSONDecoder().decode(FeedbackSuggestionDecisions.self,
                from: JSONEncoder().encode(["decisions": [decision]]))
        }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42,
            state: scenario == "sameNoteRemaining" ? .blocking : .ignoredByUser,
            reason: scenario == "sameNoteRemaining" ? "Another obligation in the same note remains." : "Only the declined precise concern remained.",
            ignoredDecisionIDs: [decision.id])]) }

        await router.refreshCompletionEvidence(host: target.host, username: target.username)

        #expect((f.settings.mrActionIntents[0].state == .completed) == (scenario == "ignoredOnly"))
        #expect(f.settings.assistantHandoffs[0].execution?.state == .succeeded)
        #expect(!f.gitlab.has("acks"))
    }

    @Test(arguments: ["exact", "missingCallback", "missingProof", "wrongRun", "changedBlocker", "changedBlockerDuringRead", "changedContext", "changedHead", "changedDiscussion", "unverifiedTool"])
    func blockedIntentCompletionRequiresTheExactFreshRunProof(_ scenario: String) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].execution = .init(state: .blocked, finishedAt: Date(),
            summary: "The assigned correction and published explanation are complete.",
            blocker: scenario == "unverifiedTool" ? "A required current verification tool is unavailable." : "Confirm a dependency before a later deployment.")
        f.settings.mrActionIntents[0].state = .failed
        let job = try #require(f.settings.assistantHandoffs.first)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: f.gitlab.data("mr"))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: f.gitlab.data("discussions"))
        var proof = AuthorFeedbackStatus(head: request.sha!, fingerprint: ReviewVerdict.fingerprint(discussions)!,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete, addressedNoteIDs: [42])
        if !["missingProof", "unverifiedTool"].contains(scenario) {
            proof.reconciledFollowUpJobIDs = [scenario == "wrongRun" ? UUID() : job.id]
            let context = try #require(AuthorFeedbackStatus.blockedContext(for: job))
            proof.reconciledBlockedContexts[job.id] = context
        }
        if scenario == "changedBlocker" { f.settings.assistantHandoffs[0].execution?.blocker = "A newly failed required verification step." }
        if scenario == "changedContext" || scenario == "changedHead" {
            let file = f.root.appending(path: "mr")
            let value = f.gitlab.text(file.lastPathComponent)
            try value.replacingOccurrences(of: scenario == "changedHead" ? request.sha! : "Example MR",
                with: scenario == "changedHead" ? String(repeating: "b", count: 40) : "Changed requirement")
                .store(in: f.gitlab, as: file.lastPathComponent)
        }
        if scenario == "changedDiscussion" {
            let file = f.root.appending(path: "discussions")
            try f.gitlab.text(file.lastPathComponent).replacingOccurrences(of: "Please fix this.", with: "Please also correct another case.")
                .store(in: f.gitlab, as: file.lastPathComponent)
        }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in
            if scenario == "changedBlockerDuringRead" {
                f.settings.assistantHandoffs[0].execution?.blocker = "A newly failed required verification step."
            }
            return .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current correction and published reply verified.")])
        }
        if scenario != "missingCallback" {
            router.blockedFollowUpCompletionProof = { checkedJob, live, liveDiscussions in
                proof.reconciles(checkedJob, request: live, discussionFingerprint: ReviewVerdict.fingerprint(liveDiscussions))
            }
        }

        await router.refreshCompletionEvidence(host: target.host, username: target.username)

        #expect((f.settings.mrActionIntents[0].state == .completed) == (scenario == "exact"))
        #expect(f.settings.assistantHandoffs[0].execution?.state == .blocked)
        #expect(!f.gitlab.has("acks"))
    }

    @Test(arguments: [false, true], [false, true])
    func trackedDraftStartsItsConfiguredWorkOnlyAfterExplicitOptIn(owned: Bool, forceOff: Bool) async throws {
        let f = try fixture(owned: owned); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        f.settings.automation.authorFeedback.isEnabled = true
        let file = f.root.appending(path: "mr")
        let ready = f.gitlab.text(file.lastPathComponent)
        try ready.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            .store(in: f.gitlab, as: file.lastPathComponent)
        if owned {
            try #"[{"id":"feedback","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"resolvable":true,"resolved":false,"body":"Please fix this behavior."}]}]"#
                .store(in: f.gitlab, as: "discussions")
        }
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, manual in
            launches += 1
            #expect(!manual && intent.request.draft == true)
            #expect(intent.kind == (owned ? .followUp : .review))
            return UUID()
        })
        let event = todo(action: owned ? .reviewSubmitted : .reviewRequested)
        #expect(await router.process([event], host: target.host, username: target.username, managed: []) == [event.id])
        #expect(launches == 0 && f.settings.mrActionIntents.first?.state == .pending)

        f.settings.automation.scope.setEnabled(true, for: target, isDraft: true)
        if forceOff { f.settings.automation.scope.setEnabled(false, for: target, isDraft: true) }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])

        #expect(launches == (forceOff ? 0 : 1))
        #expect(f.settings.mrActionIntents.first?.state == (forceOff ? .pending : .running))
        let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: f.gitlab.data(file.lastPathComponent))
        #expect(current.draft == true)
    }

    private final class Readiness { var ready = false }
    private enum LaunchFailure: Error { case rejected }
    private final class ProbeGate {
        var entered = false
        private var released = false
        var continuation: CheckedContinuation<Bool, Never>?
        func wait() async -> Bool {
            entered = true
            if released { return false }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(returning: false); continuation = nil }
    }

    @MainActor private struct Fixture {
        let settings: SettingsManager
        let defaults: UserDefaults
        let suite: String
        let root: URL
        let glab: GlabService
        let gitlab: InMemoryGitLab
        func cleanup() { gitlab.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(owned: Bool = false, acknowledgementFails: Bool = false,
                         consent: AutomationPackageDecision = .enabled) throws -> Fixture {
        let suite = "MRTodoRoutingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = consent
        let root = FileManager.default.temporaryDirectory.appending(path: "MRTodoRoutingTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gitlab = InMemoryGitLab()
        gitlab.handler = { request in
            if request.arguments[1] == "--method" {
                gitlab.append("acks", request.arguments[3] + "\n")
                return gitlab.has("fail-ack") ? InMemoryGitLab.output(code: 1) : InMemoryGitLab.output("{}")
            }
            switch request.endpoint {
            case "/user": return InMemoryGitLab.output(#"{"id":1,"username":"me"}"#)
            case let path where path.contains("/discussions"): return try gitlab.response("discussions")
            case let path where path.contains("/draft_notes"): return try gitlab.response("drafts")
            case let path where path.hasPrefix("/projects/7/pipelines/"):
                let object = try #require(JSONSerialization.jsonObject(with: gitlab.data("mr")) as? [String: Any])
                var pipeline = try #require(object["head_pipeline"] as? [String: Any])
                if pipeline["project_id"] == nil { pipeline["project_id"] = 7 }
                if pipeline["ref"] == nil { pipeline["ref"] = "feature" }
                return .init(stdout: try JSONSerialization.data(withJSONObject: pipeline), stderr: "", exitCode: 0)
            case "/projects/7/repository/branches/feature":
                let object = try #require(JSONSerialization.jsonObject(with: gitlab.data("mr")) as? [String: Any])
                return .init(stdout: try JSONSerialization.data(withJSONObject: ["commit": ["id": object["sha"]!]]), stderr: "", exitCode: 0)
            case let path where path.hasSuffix("/merge_requests/11"):
                try await gitlab.pause(ifPresent: "pause-mr", entered: "mr-entered", until: "release-mr")
                return try gitlab.response("mr")
            default: return try gitlab.unexpected(request)
            }
        }
        let author = owned ? "me" : "other"
        let id = owned ? 1 : 2
        let request = """
        {"project_id":7,"iid":11,"author":{"id":\(id),"username":"\(author)","name":"Example"},
         "title":"Example MR","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11",
         "state":"opened","sha":"\(String(repeating: "a", count: 40))","source_project_id":7,"target_project_id":7,
         "source_branch":"feature","target_branch":"main","draft":false,"labels":[],"has_conflicts":false}
        """
        try request.store(in: gitlab, as: "mr")
        try "[]".store(in: gitlab, as: "discussions")
        try "[]".store(in: gitlab, as: "drafts")
        if acknowledgementFails { try Data().store(in: gitlab, as: "fail-ack") }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        return .init(settings: settings, defaults: defaults, suite: suite, root: root, glab: glab, gitlab: gitlab)
    }

    private var target: MRAutomationScope.Target { .init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11) }

    private func completedFollowUp(_ fixture: Fixture, withReply: Bool = true) throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: fixture.gitlab.data("mr"))
        let jobID = UUID()
        fixture.settings.assistantHandoffs.append(.init(id: jobID,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .configuredTools), title: "Follow up", prompt: "Follow up",
            createdAt: Date(), allowsPush: false, feedbackNoteIDs: [42],
            execution: .init(state: .succeeded, summary: "Already addressed; no duplicate reply needed."),
            workflow: .followUp, expectedHeadSHA: request.sha))
        fixture.settings.mrActionIntents.append(.init(id: UUID(), target: target, kind: .followUp, state: .running,
            todoIDs: [], noteIDs: [42], sourceEvents: [], request: request, headSHA: request.sha!, jobID: jobID, updatedAt: Date()))
        let reply = withReply ? #",{"id":43,"author":{"id":1,"username":"me"},"system":false,"body":"Fixed with source and test evidence."}"# : ""
        try (#"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"resolvable":true,"resolved":false,"body":"Please fix this."}"#
            + reply + "]}]").store(in: fixture.gitlab, as: "discussions")
    }

    @Test func unboundDraftFollowUpReconcilesCurrentEvidenceWithoutRerunningWork() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.mrActionIntents[0].jobID = nil
        f.settings.mrActionIntents[0].state = .pending
        let file = f.root.appending(path: "mr")
        let text = f.gitlab.text(file.lastPathComponent)
        try text.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            .replacingOccurrences(of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40))
            .store(in: f.gitlab, as: file.lastPathComponent)
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current code and published response verified.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.mrActionIntents[0].jobID == nil)
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(launches == 0)
        #expect(!f.gitlab.has("acks"))
    }

    @Test func unboundFollowUpKeepsPendingWhenAddressedConcernStillNeedsAReply() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: false)
        f.settings.mrActionIntents[0].jobID = nil
        f.settings.mrActionIntents[0].state = .pending
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Code is fixed but no response exists.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .pending)
    }

    @Test func unboundEarlierAttemptFailureReconcilesOnlyFromCurrentNoWorkEvidence() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.mrActionIntents[0].jobID = nil
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "This event was attempted earlier."
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current remote code and published author reply verified.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.mrActionIntents[0].jobID == nil)
        #expect(f.settings.automationEvents.contains { $0.state == .failed && $0.message == "This event was attempted earlier." })
        #expect(launches == 0)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .interrupted, .cancelled],
          [ReReviewAssessment.Note.State.addressed, .informational])
    func stoppedFollowUpReconcilesFreshPostconditionsWithoutReplayingTheWorker(
        state: AssistantJobExecution.State, verdict: ReReviewAssessment.Note.State
    ) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: verdict == .addressed)
        f.settings.assistantHandoffs[0].execution = .init(state: state, error: "Original stopped attempt")
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Original stopped attempt"
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        router.followUpAssessment = { _, _ in .init(notes: [
            .init(noteID: 42, state: verdict, reason: "Current remote postconditions independently verified.")
        ]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.assistantHandoffs[0].execution?.state == state)
        #expect(f.settings.assistantHandoffs[0].execution?.error == "Original stopped attempt")
        #expect(f.settings.automationEvents.contains { $0.state == .failed && $0.message == "Original stopped attempt" })
        #expect(launches == 0 && f.settings.assistantHandoffs.count == 1)
        #expect(!f.gitlab.has("acks"))
    }

    @Test func stoppedFollowUpDoesNotCompleteWhileUnpublishedRemoteWorkRemains() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].execution = .init(state: .interrupted, error: "Stopped before completion")
        f.settings.mrActionIntents[0].state = .failed
        try #"[{"id":99,"author_id":1,"note":"An unpublished reply needs verification."}]"#
            .store(in: f.gitlab, as: "drafts")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in .init(notes: [
            .init(noteID: 42, state: .addressed, reason: "The source and existing reply are addressed.")
        ]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(f.settings.assistantHandoffs[0].execution?.state == .interrupted)
        #expect(f.gitlab.text("drafts").contains("unpublished reply"))
        #expect(!f.gitlab.has("acks"))
    }

    @Test func unrelatedBlockingFeedbackDoesNotKeepAnAddressedSelectedIntentFailed() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.mrActionIntents[0].jobID = nil
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Earlier attempt"
        let file = f.root.appending(path: "discussions")
        let text = f.gitlab.text(file.lastPathComponent)
        try text.replacingOccurrences(of: "]}]", with: #",{"id":44,"author":{"id":2,"username":"other"},"system":false,"resolvable":false,"body":"A separate concern remains."}]}]"#)
            .store(in: f.gitlab, as: file.lastPathComponent)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in .init(notes: [
            .init(noteID: 42, state: .addressed, reason: "Selected concern and its published reply verified."),
            .init(noteID: 44, state: .blocking, reason: "Separate concern remains unaddressed.")
        ]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.gitlab.text(file.lastPathComponent).contains("A separate concern remains."))
        #expect(!f.gitlab.has("acks"))
    }

    @Test func draftReviewRequestIsAdoptedThenStartsOnlyAfterReady() async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.reviewRequested.isEnabled = true
        let file = f.root.appending(path: "mr")
        let ready = f.gitlab.text(file.lastPathComponent)
        try ready.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            .store(in: f.gitlab, as: file.lastPathComponent)
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        #expect(await router.process([todo()], host: target.host, username: target.username, managed: []) == [10])
        #expect(f.settings.automation.scope[target] == .active)
        #expect(f.settings.mrActionIntents.first?.state == .pending)
        #expect(launches == 0)
        try ready.store(in: f.gitlab, as: file.lastPathComponent)
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(launches == 1)
        #expect(f.settings.mrActionIntents.first?.state == .running)
    }

    @Test func pausedDraftMentionRemainsUnreadWithoutPaidSemanticAssessment() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let text = f.gitlab.text(file.lastPathComponent)
        try text.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            .store(in: f.gitlab, as: file.lastPathComponent)
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me informational context."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        var assessments = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true })
        router.mentionDisposition = { _, _, _, _ in assessments += 1; return .informational }
        #expect(await router.process([todo(action: .mentioned, linked: true)], host: target.host,
                                     username: target.username, managed: []).isEmpty)
        #expect(assessments == 0)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!f.gitlab.has("acks"))
    }

    @Test func informationalMentionIsAcknowledgedWithoutAdoptingOrReviewingForeignDraft() async throws {
        // Global Draft automation allows notice classification without adopting the MR.
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.scope.pauseDraftsByDefault = false
        let file = f.root.appending(path: "mr")
        let text = f.gitlab.text(file.lastPathComponent)
        try text.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
            .store(in: f.gitlab, as: file.lastPathComponent)
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me review is deferred until the author finishes this draft."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        })
        router.mentionDisposition = { request, discussions, user, noteID in
            #expect(request.draft == true && user.username == "me")
            #expect(discussions.flatMap(\.notes).contains { $0.id == noteID })
            return .informational
        }
        let event = todo(action: .mentioned, linked: true)
        #expect(await router.process([event], host: target.host, username: target.username, managed: []) == [event.id])
        #expect(f.settings.automation.scope[target] == .inherit)
        #expect(f.settings.mrActionIntents.first?.kind == .refresh)
        #expect(f.settings.mrActionIntents.first?.state == .completed)
        #expect(launches == 0)
    }

    @Test func informationalReceiptDoesNotManageALaterForeignReviewRequest() async throws {
        let f = try fixture(); defer { f.cleanup() }
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me status update only."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.mentionDisposition = { _, _, _, _ in .informational }
        let notice = todo(action: .mentioned, linked: true)
        #expect(await router.process([notice], host: target.host, username: target.username, managed: []) == [notice.id])
        #expect(f.settings.mrActionIntents.first?.kind == .refresh)
        let request = todo(20, action: .reviewRequested)
        #expect(await router.process([request], host: target.host, username: target.username, managed: []).isEmpty)
        try #require(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.automation.scope[target] == .inherit)
    }

    @Test(arguments: [MRTodoMentionDisposition.actionable, .uncertain])
    func foreignMentionWithoutInformationalEvidenceRemainsUnread(disposition: MRTodoMentionDisposition) async throws {
        let f = try fixture(); defer { f.cleanup() }
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me please inspect this."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        f.settings.automation.reviewRequested.isEnabled = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true })
        router.mentionDisposition = { _, _, _, _ in disposition }
        #expect(await router.process([todo(action: .mentioned, linked: true)], host: target.host, username: target.username, managed: []).isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(f.settings.automation.scope[target] == .inherit)
    }

    @Test func changedDiscussionDuringMentionAssessmentPreservesUnreadEvent() async throws {
        let f = try fixture(); defer { f.cleanup() }
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me informational context."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true })
        router.mentionDisposition = { _, _, _, _ in
            try? #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me please fix this immediately."}]}]"#
                .store(in: f.gitlab, as: "discussions")
            return .informational
        }
        #expect(await router.process([todo(action: .mentioned, linked: true)], host: target.host, username: target.username, managed: []).isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
    }

    @Test(arguments: ["ready", "resolved"])
    func changedReadinessOrThreadStateDuringNoticeAssessmentPreservesUnreadEvent(change: String) async throws {
        let f = try fixture(); defer { f.cleanup() }
        f.settings.automation.scope.pauseDraftsByDefault = false
        let requestFile = f.root.appending(path: "mr")
        let ready = f.gitlab.text(requestFile.lastPathComponent)
        let draft = ready.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
        try draft.store(in: f.gitlab, as: requestFile.lastPathComponent)
        let threads = #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"body":"@me review once this is ready.","resolvable":true,"resolved":false}]}]"#
        try threads.store(in: f.gitlab, as: "discussions")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.mentionDisposition = { _, _, _, _ in
            if change == "ready" { try? ready.store(in: f.gitlab, as: requestFile.lastPathComponent) }
            else {
                try? threads.replacingOccurrences(of: #""resolved":false"#, with: #""resolved":true"#)
                    .store(in: f.gitlab, as: "discussions")
            }
            return .informational
        }
        let acknowledged = await router.process([todo(action: .mentioned, linked: true)], host: target.host,
                                                username: target.username, managed: [])
        #expect(acknowledged.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!f.gitlab.has("acks"))
    }

    @Test("An independently verified no-op follow-up completes without a draft publication receipt",
          arguments: [ReReviewAssessment.Note.State.addressed, .informational])
    func verifiedNoOpFollowUpCompletes(state: ReReviewAssessment.Note.State) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: state != .informational)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: state, reason: "Verified against current code and discussion.")]) }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.mrActionIntents[0].error == nil)
        let restoredIntent = try #require(SettingsManager(defaults: f.defaults).mrActionIntents.first)
        #expect(restoredIntent.state == .completed)
        #expect(!f.gitlab.has("proofs"))
    }

    @Test func recoveredNoOpKeepsThePreviousApplicationFailureInHistory() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        let previous = "This action needs a fresh check against the current merge request."
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = previous
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Existing reply and code verified.")]) }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .completed)
        let retained = SettingsManager(defaults: f.defaults).automationEvents.filter { $0.intentID == f.settings.mrActionIntents[0].id && $0.state == .failed }
        #expect(retained.count == 1)
        #expect(retained.first?.message == previous)
        #expect(retained.first?.jobID == f.settings.mrActionIntents[0].jobID)
    }

    @Test(arguments: ["crossThreadOnly", "ownReply", "ownReplyEditedDuringRead"])
    func feedbackCompletionRequiresAFreshReplyInItsOwnThread(_ scenario: String) async throws {
        // given
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: false)
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Current feedback evidence is missing."
        let ownReply = scenario == "crossThreadOnly" ? ""
            : #",{"id":44,"author":{"id":1,"username":"me"},"system":false,"body":"Corrected; see the earlier feedback and verified reply."}"#
        try #"[{"id":"d","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"resolvable":true,"resolved":false,"body":"Please fix shared access."}\#(ownReply)]},{"id":"other-thread","notes":[{"id":43,"author":{"id":1,"username":"me"},"system":false,"body":"Shared access is corrected; this also addresses note 42."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":42,"state":"addressed","reason":"Current code and the published reply in another thread cover the same concern.","publishedReplyNoteID":43}]}"#.utf8))
        var launches = 0
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            launches += 1; return UUID()
        }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in
            if scenario == "ownReplyEditedDuringRead" {
                try? f.gitlab.text("discussions").replacingOccurrences(of: "Corrected; see the earlier feedback and verified reply.",
                    with: "This reply now concerns an unrelated change.").store(in: f.gitlab, as: "discussions")
            }
            return assessment
        }
        // when
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        // then
        #expect(f.settings.mrActionIntents[0].state == (scenario == "ownReply" ? .completed : .failed))
        #expect((f.settings.mrActionIntents[0].error == nil) == (scenario == "ownReply"))
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(launches == 0)
        #expect(!f.gitlab.has("acks"))
    }

    @Test(arguments: [AssistantJobExecution.State.succeeded, .failed])
    func backgroundStatusChangesAreAutomaticEvenWhenTheWorkerWasStartedManually(state: AssistantJobExecution.State) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].manual = true
        if state == .failed { f.settings.assistantHandoffs[0].execution = .init(state: .failed, error: "The worker failed.") }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current feedback verified.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        let result = try #require(f.settings.automationEvents.first { $0.action == .followUp })
        #expect(result.state == .completed)
        #expect(result.origin == .automatic)
        #expect(SettingsManager(defaults: f.defaults).assistantHandoffs[0].manual == true)
    }

    @Test func reconciliationKeepsExistingHistoryAndDoesNotRelabelOldManualEvents() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].manual = true
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Earlier application failure."
        let intent = f.settings.mrActionIntents[0]
        f.settings.recordAutomationEvent(target: target, action: .followUp, origin: .manual, state: .failed,
            message: intent.error, intentID: intent.id, jobID: intent.jobID)
        let historical = try #require(f.settings.automationEvents.first)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current feedback verified.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.automationEvents.first { $0.id == historical.id } == historical)
        #expect(f.settings.automationEvents.filter { $0.state == .failed }.count == 1)
        #expect(f.settings.automationEvents.first { $0.state == .completed }?.origin == .automatic)
    }

    @Test func anExplicitRetryFailureStillRecordsTheUsersManualTrigger() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, manual in
            #expect(manual)
            throw LaunchFailure.rejected
        })
        await router.run(f.settings.mrActionIntents[0].id, manual: true)
        #expect(f.settings.automationEvents.first { $0.action == .retry && $0.state == .requested }?.origin == .manual)
        #expect(f.settings.automationEvents.first { $0.action == .followUp && $0.state == .failed }?.origin == .manual)
    }

    @Test func aManualFailureIsNotDeduplicatedAgainstAnEarlierAutomaticFailureWithTheSameReason() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].execution = .init(state: .failed, error: "rejected")
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "rejected"
        let intent = f.settings.mrActionIntents[0]
        f.settings.recordAutomationEvent(target: target, action: .followUp, origin: .automatic, state: .failed,
            message: "rejected", intentID: intent.id, jobID: intent.jobID)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { _, _ in
            throw LaunchFailure.rejected
        })
        await router.run(intent.id, manual: true)
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        let failures = f.settings.automationEvents.filter { $0.action == .followUp && $0.state == .failed }
        #expect(failures.count == 2)
        #expect(failures.filter { $0.origin == .manual }.count == 1)
        #expect(failures.filter { $0.origin == .automatic }.count == 1)
    }

    @Test func unchangedBackgroundObservationDoesNotDuplicateAnExistingManualFailureAsAutomatic() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].execution = .init(state: .failed, error: "Existing failure")
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Existing failure"
        let intent = f.settings.mrActionIntents[0]
        f.settings.recordAutomationEvent(target: target, action: .followUp, origin: .manual, state: .failed,
            message: intent.error, intentID: intent.id, jobID: intent.jobID)
        let original = try #require(f.settings.automationEvents.first)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.automationEvents == [original])
        #expect(f.settings.mrActionIntents[0].state == .failed)
    }

    @Test func aConcurrentManualRetryDoesNotMakeAnAutomaticReconciliationManual() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        let gate = ProbeGate()
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { await gate.wait() }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current feedback verified.")]) }
        let intentID = try #require(f.settings.mrActionIntents.first).id
        let retry = Task { await router.run(intentID, manual: true) }
        defer { gate.release(); retry.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.entered)
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.automationEvents.first { $0.state == .completed }?.origin == .automatic)
        #expect(f.settings.automationEvents.first { $0.action == .retry }?.origin == .manual)
        gate.release()
        await retry.value
    }

    @Test func blockedVerificationCannotBeClearedByANoWorkAssessment() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        f.settings.assistantHandoffs[0].execution = .init(state: .blocked, blocker: "Temporary-file creation was denied during tests.")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current code appears addressed.")]) }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(f.settings.mrActionIntents[0].error == "Temporary-file creation was denied during tests.")
    }

    @Test func coldStartWaitsForCurrentVerificationThenReconcilesWithoutAnotherWorkerOrManualRefresh() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        let verification = Readiness()
        verification.ready = true
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpVerificationPending = { _, _ in verification.ready }
        router.followUpAssessment = { _, _ in verification.ready ? nil : .init(notes: [.init(noteID: 42, state: .addressed, reason: "Current code and published response verified.")]) }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .running)
        #expect(f.settings.mrActionIntents[0].error == nil)
        #expect(!f.settings.automationEvents.contains { $0.state == .failed })
        verification.ready = false
        await router.refreshCompletionEvidence(host: target.host, username: target.username)
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.assistantHandoffs.count == 1)
    }

    @Test func completionRefreshDoesNotConsumeEvidenceForAnotherAccount() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        router.followUpAssessment = { _, _ in .init(notes: [.init(noteID: 42, state: .addressed, reason: "Verified.")]) }
        await router.refreshCompletionEvidence(host: target.host, username: "another")
        #expect(f.settings.mrActionIntents[0].state == .running)
        #expect(f.settings.automationEvents.isEmpty)
    }

    @Test("An early failed or missing old worker cannot overwrite a retry during the live MR read",
          arguments: ["failed", "blocked", "missing", "sameIDAppeared", "closedMR"])
    func replacingAWorkerWhileCompletionRefreshReadsTheMRPreservesTheReplacement(scenario: String) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f)
        if scenario == "missing" || scenario == "sameIDAppeared" { f.settings.assistantHandoffs.removeAll() }
        else { f.settings.assistantHandoffs[0].execution = .init(state: scenario == "blocked" ? .blocked : .failed, error: "Old worker stopped.") }
        if scenario == "closedMR" {
            let file = f.root.appending(path: "mr")
            let text = f.gitlab.text(file.lastPathComponent)
            try text.replacingOccurrences(of: #""state":"opened""#, with: #""state":"closed""#)
                .store(in: f.gitlab, as: file.lastPathComponent)
        }
        try Data().store(in: f.gitlab, as: "pause-mr")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let task = Task { await router.refreshCompletionEvidence(host: target.host, username: target.username) }
        defer { task.cancel(); try? Data().store(in: f.gitlab, as: "release-mr") }
        let deadline = ContinuousClock.now + .seconds(3)
        while !f.gitlab.has("mr-entered"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(f.gitlab.has("mr-entered"))
        let replacementID: UUID
        if scenario == "sameIDAppeared" { replacementID = try #require(f.settings.mrActionIntents[0].jobID) }
        else { replacementID = UUID() }
        let replacementHead = scenario == "sameIDAppeared" ? f.settings.mrActionIntents[0].headSHA : String(repeating: "b", count: 40)
        f.settings.assistantHandoffs.append(.init(id: replacementID,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                username: "me", workspace: "", access: .configuredTools), title: "Retry", prompt: "Retry",
            createdAt: Date(), allowsPush: false, execution: .init(state: .running),
            workflow: .followUp, expectedHeadSHA: replacementHead))
        f.settings.mrActionIntents[0].jobID = replacementID
        f.settings.mrActionIntents[0].headSHA = replacementHead
        f.settings.mrActionIntents[0].state = .running
        f.settings.mrActionIntents[0].error = nil
        try Data().store(in: f.gitlab, as: "release-mr")
        await task.value
        #expect(f.settings.mrActionIntents[0].jobID == replacementID)
        #expect(f.settings.mrActionIntents[0].headSHA == replacementHead)
        #expect(f.settings.mrActionIntents[0].state == .running)
        #expect(f.settings.mrActionIntents[0].error == nil)
        #expect(f.settings.automationEvents.isEmpty)
    }

    @Test("A successful worker cannot substitute for complete current no-work evidence",
          arguments: ["blocking", "uncertain", "missingAssessment", "missingNote", "missingReply", "newExpectation", "newHead", "newContext", "editedDiscussion", "wrongAccount", "replacementRun"])
    func unverifiedNoOpFollowUpRemainsFailed(scenario: String) async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try completedFollowUp(f, withReply: scenario != "missingReply")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false }, proofDirectory: f.root.appending(path: "proofs"))
        router.followUpAssessment = { _, _ in
            if scenario == "missingAssessment" { return nil }
            var notes: [ReReviewAssessment.Note] = [.init(noteID: 42,
                state: scenario == "blocking" ? .blocking : scenario == "uncertain" ? .uncertain : .addressed,
                reason: "Current evidence.")]
            if scenario == "missingNote" { notes = [] }
            if scenario == "newExpectation" {
                let file = f.root.appending(path: "discussions")
                let text = f.gitlab.text(file.lastPathComponent)
                try! text.replacingOccurrences(of: "]}]", with: #",{"id":44,"author":{"id":2,"username":"other"},"system":false,"body":"Also fix the new case."}]}]"#)
                    .store(in: f.gitlab, as: file.lastPathComponent)
            }
            if scenario == "newHead" || scenario == "newContext" {
                let file = f.root.appending(path: "mr")
                let text = f.gitlab.text(file.lastPathComponent)
                try! text.replacingOccurrences(of: scenario == "newHead" ? String(repeating: "a", count: 40) : "Example MR",
                    with: scenario == "newHead" ? String(repeating: "b", count: 40) : "Changed expectations")
                    .store(in: f.gitlab, as: file.lastPathComponent)
            }
            if scenario == "editedDiscussion" {
                let file = f.root.appending(path: "discussions")
                let text = f.gitlab.text(file.lastPathComponent)
                try! text.replacingOccurrences(of: "Please fix this.", with: "Please fix a different case.")
                    .store(in: f.gitlab, as: file.lastPathComponent)
            }
            if scenario == "wrongAccount" { f.glab.currentUsername = "another" }
            if scenario == "replacementRun" {
                let replacementID = UUID()
                var replacement = f.settings.assistantHandoffs[0]
                replacement = .init(id: replacementID, key: replacement.key, title: replacement.title,
                    prompt: replacement.prompt, createdAt: Date(), allowsPush: false,
                    execution: .init(state: .running), workflow: .followUp, expectedHeadSHA: replacement.expectedHeadSHA)
                f.settings.assistantHandoffs.append(replacement)
                f.settings.mrActionIntents[0].jobID = replacementID
                f.settings.mrActionIntents[0].state = .running
            }
            return .init(notes: notes)
        }
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state != .completed)
        if scenario == "replacementRun" { #expect(f.settings.mrActionIntents[0].state == .running) }
    }
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
        try #require(f.settings.mrActionIntents.count == 1)
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
        let updated = f.gitlab.text(file.lastPathComponent)
            .replacingOccurrences(of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40))
        try updated.store(in: f.gitlab, as: file.lastPathComponent)
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        try #require(f.settings.mrActionIntents.count == 1)
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
        let calls = f.gitlab.text("acks")
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
        try #require(f.settings.mrActionIntents.count == 1)
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
        try #require(f.settings.mrActionIntents.count == 1)
        f.settings.mrActionIntents[0].state = .completed; f.settings.save()
        f.gitlab.remove("fail-ack")
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
            .store(in: f.gitlab, as: "discussions")
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])
        #expect(acknowledged == [event.id])
        let intent = try #require(f.settings.mrActionIntents.first)
        #expect(intent.kind == .followUp)
        #expect(intent.noteIDs == [42])
    }
    @Test func manuallyAcceptedEventsRemainDurableWithoutAnAutomaticEventBanner() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        var banners = 0
        router.onAcceptedIntent = { _ in banners += 1 }
        let received = await router.process([todo()], host: target.host, username: target.username,
                                            managed: [target], automatically: false)
        #expect(received == [10])
        try #require(f.settings.mrActionIntents.count == 1)
        #expect(banners == 0)
    }

    @Test func acceptedEventBannerFollowsDurableIntentAndDoesNotRepeatOnAcknowledgementRetries() async throws {
        let f = try fixture(acknowledgementFails: true); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        var acceptedIDs: [UUID] = []
        router.onAcceptedIntent = { intent in
            #expect(SettingsManager(defaults: f.defaults).mrActionIntents.contains { $0.id == intent.id })
            acceptedIDs.append(intent.id)
        }
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        #expect(acceptedIDs.count == 1)
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        #expect(acceptedIDs.count == 1)
        f.gitlab.remove("fail-ack")
        _ = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        #expect(acceptedIDs.count == 1)
    }

    @Test func submittedReviewWithoutOpenFeedbackRefreshesOwnedMRAndAcknowledgesEvent() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let event = todo(action: .reviewSubmitted)
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])
        #expect(acknowledged == [event.id])
        let intent = try #require(f.settings.mrActionIntents.first)
        #expect(intent.kind == .refresh)
        #expect(intent.state == .completed)
        #expect(SettingsManager(defaults: f.defaults).mrActionIntents.first?.sourceEvents == [event.feedbackIdentity])
    }

    @Test func submittedGeneralReviewRefreshesBeforeSharedSemanticAssessment() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try #"[{"id":"general","notes":[{"id":42,"author":{"id":2,"username":"other"},"system":false,"resolvable":false,"body":"Please also check the documented edge case."}]}]"#
            .store(in: f.gitlab, as: "discussions")
        f.settings.automation.authorFeedback.isEnabled = true
        var launchedNotes: Set<Int> = []
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { true }, launcher: { intent, _ in
            launchedNotes = intent.noteIDs; return UUID()
        })
        let event = todo(action: .reviewSubmitted)
        let acknowledged = await router.process([event], host: target.host, username: target.username, managed: [])
        #expect(acknowledged == [event.id])
        #expect(f.settings.mrActionIntents.first?.kind == .refresh)
        #expect(f.settings.mrActionIntents.first?.state == .completed)
        #expect(launchedNotes.isEmpty)
    }

    @Test func submittedReviewOnManagedForeignMRRefreshesWithoutAuthorFollowUp() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let event = todo(action: .reviewSubmitted)
        #expect(await router.process([event], host: target.host, username: target.username, managed: [target]) == [event.id])
        #expect(f.settings.mrActionIntents.first?.kind == .refresh)
    }

    @Test func failedReviewEvidenceReadKeepsEventUnreadWithoutDurableAcceptance() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        try "unavailable".store(in: f.gitlab, as: "discussions")
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        #expect(await router.process([todo(action: .reviewSubmitted)], host: target.host, username: target.username, managed: []).isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!f.gitlab.has("acks"))
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
        try #require(f.settings.mrActionIntents.count == 2)
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
        try #require(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        #expect(launches == 0)
        await router.run(f.settings.mrActionIntents[0].id, manual: true)
        #expect(launches == 1)
    }

    @Test func mismatchedLiveMergeRequestIdentityRemainsUnread() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
        var object = try #require(decoded as? [String: Any])
        object["web_url"] = "https://another.example.test/team/repo/-/merge_requests/11"
        try JSONSerialization.data(withJSONObject: object).store(in: f.gitlab, as: file.lastPathComponent)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let ack = await router.process([todo()], host: target.host, username: target.username, managed: [target])
        #expect(ack.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
        #expect(!f.gitlab.has("acks"))
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
        try #require(f.settings.mrActionIntents.count == 1)
        #expect(f.settings.mrActionIntents[0].state == .failed)
        let intent = f.settings.mrActionIntents[0]
        let id = try #require(intent.jobID)
        f.settings.assistantHandoffs.append(.init(id: id,
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, feedbackTodos: intent.sourceEvents, execution: .init(state: .succeeded), workflow: .review, expectedHeadSHA: intent.headSHA))
        f.settings.mrActionIntents[0].state = .running
        let file = f.root.appending(path: "mr")
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
        var object = try #require(decoded as? [String: Any]); object["sha"] = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: object).store(in: f.gitlab, as: file.lastPathComponent)
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
        try #require(f.settings.mrActionIntents.count == 2)
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
        #expect(!f.gitlab.has("acks"))
    }

    @Test("configured assistant restrictions and title placeholders survive semantic routing", arguments: [MRTodoIntent.Kind.review, .followUp])
    func configuredInstructionsArePreserved(kind: MRTodoIntent.Kind) throws {
        let f = try fixture(owned: kind == .followUp); defer { f.cleanup() }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: f.gitlab.data("mr"))
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
        try #require(f.settings.mrActionIntents.count == 1)
        let oldID = UUID(), newID = UUID()
        f.settings.mrActionIntents[0].jobID = oldID
        f.settings.mrActionIntents[0].state = .failed
        f.settings.mrActionIntents[0].error = "Old failure"
        let original = try #require(f.settings.mrActionIntents.first)
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
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
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
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
        var object = try #require(decoded as? [String: Any])
        if kind == .pipeline { object["head_pipeline"] = ["id": 100, "project_id": 7, "sha": String(repeating: "a", count: 40), "status": "failed"] }
        if kind == .conflict { object["has_conflicts"] = true }
        try JSONSerialization.data(withJSONObject: object).store(in: f.gitlab, as: file.lastPathComponent)
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
        try JSONSerialization.data(withJSONObject: object).store(in: f.gitlab, as: file.lastPathComponent)
        _ = await router.process([], host: target.host, username: target.username, managed: [target])
        #expect(f.settings.mrActionIntents[0].state == .completed)
        #expect(f.settings.assistantHandoffs[0].execution?.state == .failed)
    }

    @Test func ownedFailedPipelineTabEventRoutesToCanonicalMRAction() async throws {
        let f = try fixture(owned: true); defer { f.cleanup() }
        let file = f.root.appending(path: "mr")
        var request = try #require(JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent)) as? [String: Any])
        request["head_pipeline"] = ["id": 99, "project_id": 7, "status": "failed", "sha": String(repeating: "a", count: 40)]
        try JSONSerialization.data(withJSONObject: request).store(in: f.gitlab, as: file.lastPathComponent)
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
        #expect(!f.gitlab.has("acks"))
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
        let original = try #require(f.settings.mrActionIntents.first)
        f.settings.assistantHandoffs.append(.init(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: target.host, projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Interrupted", prompt: "Interrupted",
            createdAt: Date(), allowsPush: false, feedbackTodos: original.sourceEvents,
            execution: .init(state: .interrupted), expectedHeadSHA: original.headSHA))
        f.settings.automation.reviewRequested.isEnabled = true
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        try #require(f.settings.mrActionIntents.count == 2)
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
        defer { gate.release(); refresh.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.entered)
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
        let intentID = try #require(f.settings.mrActionIntents.first).id
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
        let originalID = try #require(f.settings.mrActionIntents.first).id
        let manual = Task { await router.run(originalID, manual: true) }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(gate.entered)
        _ = await router.process([todo(20)], host: target.host, username: target.username, managed: [target])
        gate.release()
        await manual.value
        try #require(f.settings.mrActionIntents.count == 2)
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
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
        var request = try #require(decoded as? [String: Any])
        request["head_pipeline"] = ["id": 99, "project_id": 7, "status": "failed", "sha": String(repeating: "b", count: 40)]
        try JSONSerialization.data(withJSONObject: request).store(in: f.gitlab, as: file.lastPathComponent)
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
        let decoded = try JSONSerialization.jsonObject(with: f.gitlab.data(file.lastPathComponent))
        var request = try #require(decoded as? [String: Any])
        var pipeline: [String: Any] = ["id": 99, "status": "failed"]
        if includeEmptySHA { pipeline["sha"] = "" }
        request["head_pipeline"] = pipeline
        try JSONSerialization.data(withJSONObject: request).store(in: f.gitlab, as: file.lastPathComponent)
        let router = MergeRequestTodoRouter(settings: f.settings, glab: f.glab, canAutomate: { false })
        let acknowledged = await router.process([todo(action: .buildFailed, suffix: "/pipelines")],
                                                host: target.host, username: target.username, managed: [target])
        #expect(acknowledged.isEmpty)
        #expect(f.settings.mrActionIntents.isEmpty)
    }

}
