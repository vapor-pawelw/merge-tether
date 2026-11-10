import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteBoardAdapterTests {
    @Test func aSafetyStorageFailureIsVisibleWithoutInvalidatingManualReadiness() throws {
        let suite = "RemoteStorageStatusTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.onboardingCompleted = false
        settings.automation.applyPreset(.manual, for: .codex)
        settings.save()
        let monitor = TodoMonitorService(settings: settings, glab: GlabService())
        defer { monitor.stopTimer() }
        let session = UUID()
        let ready = RemoteBoardAdapter.board(monitor: monitor, session: session, account: "me@host")
        let original = settings.automation
        settings.recordPersistenceFailure("mergeSubmissions")
        let paused = RemoteBoardAdapter.board(monitor: monitor, session: session, account: "me@host")
        let readyWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as? [String: Any])
        let pausedWire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(paused)) as? [String: Any])
        #expect(readyWire["automationPaused"] as? Bool == false)
        #expect(pausedWire["automationPaused"] as? Bool == true)
        #expect(ready.partial == false && paused.partial == false)
        #expect(settings.automation == original)
    }

    @Test func phoneCompletionBindsTheCurrentCommentReviewAndDiscussionText() throws {
        var item = try item()
        item.drafts = []; item.draftCount = 0
        item.mergeRequest = try MRDependencyPresentationTests().request(2, project: 1)
        item.requiresCommentReview = true
        item.observedDiscussionFingerprint = "comments"
        item.commentReviewSnapshot = CommentReviewSnapshot(request: item.mergeRequest, discussions: [])
        let pending = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org")
        #expect(pending.actions.contains { $0.kind == .finishCommentReview })
        let displayed = RemoteBoardAdapter.presentation(pending, row: .init(item: item, latestJob: nil, intents: []))
        #expect(displayed.primaryCTA?.title == String(localized: .CommentReview.commentReviewFinish))
        item.observedDiscussionFingerprint = "changed comments"
        let changed = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org")
        #expect(changed.actions != pending.actions)
        item.requiresCommentReview = false
        #expect(!RemoteBoardAdapter.card(item, account: "me@gitlab.example.org").actions.contains { $0.kind == .finishCommentReview })
    }

    @Test func phoneDeletionActionsAreBoundToEachExactDraft() throws {
        var item = try item()
        item.drafts = [.init(id: 11, authorID: 3, note: "Draft", discussionID: nil, position: nil)]
        item.draftCount = 1
        let before = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org")
        let deletion = try #require(before.actions.first { $0.kind == .deleteDraft })
        #expect(deletion.id == "deleteDraft:11")
        item.drafts = [.init(id: 11, authorID: 3, note: "Edited", discussionID: nil, position: nil)]
        #expect(RemoteBoardAdapter.card(item, account: "me@gitlab.example.org").actions.first { $0.kind == .deleteDraft }?.token != deletion.token)
    }
    @Test(arguments: ["head", "title", "discussion", "draftBody", "draftPosition", "draftResolution"])
    func changedWriteContextRejectsTheEarlierActionToken(_ change: String) async throws {
        var item = try item()
        item.mergeRequest = try MRDependencyPresentationTests().request(2, project: 1)
        let before = RemoteBoardAdapter.card(item, account: "me@host", extraActions: [.prepare])
        let action = try #require(before.actions.first { $0.kind == .prepare })
        let session = UUID()
        let initialBoard = RemoteBoard(hostSession: session, account: "me@host", lanes: [.init(id: .own, cards: [before])])
        let valid = await RemoteCommandGate().execute(.init(hostSession: session, cardID: before.id, actionID: action.id, token: action.token),
            board: initialBoard) { _, _ in .completed }
        #expect(valid.status == .completed)
        switch change {
        case "head", "title":
            var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item.mergeRequest)) as? [String: Any])
            raw[change == "head" ? "sha" : "title"] = "changed-context"
            item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: raw))
        case "discussion": item.observedDiscussionFingerprint = "new-discussion"
        case "draftBody":
            item.drafts = [.init(id: 11, authorID: 3, note: "Changed body", discussionID: nil, position: item.drafts[0].position)]
        case "draftPosition":
            item.drafts = [.init(id: 11, authorID: 3, note: item.drafts[0].note, discussionID: nil,
                position: .init(newPath: "Sources/Other.swift", newLine: 4, oldPath: nil, oldLine: nil))]
        case "draftResolution": item.drafts[0].resolveDiscussion = true
        default: Issue.record("Unknown context")
        }
        let after = RemoteBoardAdapter.card(item, account: "me@host", extraActions: [.prepare])
        let board = RemoteBoard(hostSession: session, account: "me@host", lanes: [.init(id: .own, cards: [after])])
        let stale = await RemoteCommandGate().execute(.init(hostSession: session, cardID: before.id, actionID: action.id, token: action.token),
            board: board) { _, _ in Issue.record("Stale action executed"); return .completed }
        #expect(stale.status == .changed)
    }

    @Test func optionalApprovalsKeepTheLegacyWireCountsValid() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!)
        item.approvalProgress = MergeRequestApprovalProgress(completed: 3, required: 0)
        let card = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org")
        #expect(card.approvals?.completed == 0 && card.approvals?.required == 0)
        #expect(card.approvals?.received == 3)
        let decoded = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card))
        #expect(decoded.approvals == card.approvals)
    }
    @Test func excessApprovalsKeepTheLegacyNumeratorBoundedAndTheCurrentNumeratorComplete() throws {
        var item = try item()
        item.approvalProgress = MergeRequestApprovalProgress(completed: 5, required: 2)
        let card = RemoteBoardAdapter.card(item, account: "me@host")
        #expect(card.approvals?.completed == 2 && card.approvals?.required == 2)
        #expect(card.approvals?.received == 5)
    }

    @Test func approvalCountChangesCannotInvalidateAnOtherwiseCurrentPhoneAction() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!)
        item.approvalProgress = MergeRequestApprovalProgress(completed: 1, required: 2)
        let before = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org", extraActions: [.markDone])
        item.approvalProgress = MergeRequestApprovalProgress(completed: 2, required: 2)
        let after = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org", extraActions: [.markDone])
        #expect(before.approvals != after.approvals)
        #expect(!before.actions.isEmpty && before.actions == after.actions)
        item.approvalProgress = nil
        #expect(RemoteBoardAdapter.card(item, account: "me@gitlab.example.org", extraActions: [.markDone]).actions == before.actions)
    }
    @Test func requiredApprovalProgressReachesThePhoneAsReadOnlyMetadata() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!)
        item.approvalProgress = MergeRequestApprovalProgress(completed: 1, required: 2)
        let card = RemoteBoardAdapter.card(item, account: "me@gitlab.example.org")
        #expect(card.approvals?.completed == 1 && card.approvals?.required == 2)
        #expect(card.actions.isEmpty)
        let decoded = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card))
        #expect(decoded.approvals == card.approvals)
    }
    @Test(arguments: [AssistantJobExecution.State.failed, .blocked], ["completed", "unrelatedCompleted", "independentFailure", "obsoletePipeline", "obsoleteWithIndependentIntent"])
    func phoneActionsRespectCompletedHistoricalJobs(state: AssistantJobExecution.State, scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "RemoteHistoricalJobTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.manual, for: .codex)
        settings.onboardingCompleted = false
        var requestJSON = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.org/group/project/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","labels":[],"has_conflicts":false,"blocking_discussions_resolved":true}"#
        if scenario.hasPrefix("obsolete") {
            requestJSON = requestJSON.replacingOccurrences(of: "\"labels\":[]", with:
                "\"labels\":[],\"head_pipeline\":{\"id\":10,\"project_id\":1,\"status\":\"success\",\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}")
        }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
        try Data(requestJSON.utf8).write(to: directory.appending(path: "mr.json"))
        let drafts = scenario == "independentFailure" ? "[]" : #"[{"id":11,"author_id":3,"note":"My manual draft"}]"#
        try Data(drafts.utf8).write(to: directory.appending(path: "drafts.json"))
        let executable = directory.appending(path: "glab")
        try Data("""
            #!/bin/sh
            root="${0%/*}"
            case "$*" in
              'config get host') printf '%s' 'gitlab.example.org' ;;
              'auth status') printf '%s' 'Logged in to gitlab.example.org as me' >&2 ;;
              'api /user '*) printf '%s' '{"id":3,"username":"me"}' ;;
              'api /merge_requests?scope=created_by_me&'*) printf '['; cat "$root/mr.json"; printf ']' ;;
              'api /projects/1/merge_requests/2 --hostname '*) cat "$root/mr.json" ;;
              'api /projects/1/merge_requests/2/draft_notes?'*) cat "$root/drafts.json" ;;
              *) printf '[]' ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
        settings.resolvedHost = "gitlab.example.org"
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
        var job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex, work: work,
            username: "me", workspace: "", access: .gitLabRead), title: "Historical run", prompt: "Inspect",
            createdAt: Date(), allowsPush: false, execution: .init(state: state, error: "Historical failure"),
            taskPrompt: "Inspect", mergeRequestURL: request.webURL, expectedHeadSHA: request.sha)
        if scenario.hasPrefix("obsolete") {
            job.pipelineReservation = .init(host: work.host, projectID: 1, mergeRequestIID: 2, pipelineID: 10)
        }
        settings.assistantHandoffs = [job]
        let target = MRAutomationScope.Target(host: work.host, username: "me", projectID: 1, iid: 2)
        settings.mrActionIntents = [.init(id: UUID(), target: target, kind: .pipeline, state: scenario.hasPrefix("obsolete") ? .failed : .completed,
            todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: request.sha!,
            jobID: scenario == "unrelatedCompleted" ? UUID() : job.id, updatedAt: Date())]
        if scenario == "independentFailure" || scenario == "obsoleteWithIndependentIntent" {
            settings.mrActionIntents.append(.init(id: UUID(), target: target, kind: .conflict, state: .failed,
                todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: request.sha!,
                error: "Conflict verification failed", updatedAt: Date()))
        }
        let monitor = TodoMonitorService(settings: settings, glab: GlabService())
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        monitor.attention.refresh(host: work.host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.attention.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!monitor.attention.isLoading && !monitor.attention.hasError)
        let board = RemoteBoardAdapter.board(monitor: monitor, session: UUID(), account: "me@host")
        #expect(board.partial == false)
        let card = try #require(board.lanes.first { $0.id == .own }?.cards.first { $0.id == "mr:1:2" })
        let expectedDestination: RemoteCardCTA.Destination = switch scenario {
        case "completed", "obsoletePipeline", "obsoleteWithIndependentIntent": .drafts
        case "unrelatedCompleted": .assistantRuns
        default: monitor.availableAssistants.contains(settings.automation.assistant) ? .overview : .setup
        }
        #expect(card.needsAttention == true)
        #expect(card.primaryCTA?.destination == expectedDestination)
        #expect(card.actions.contains { $0.kind == .retryJob } == (scenario == "unrelatedCompleted"))
        if scenario == "obsoletePipeline" { #expect(!card.actions.contains { $0.kind == .prepare }) }

    }

    @Test func aPhoneMustCheckTheConcreteResolutionScopeBeforeReceivingAResolveCommand() throws {
        let suite = "RemoteResolutionPreview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.resolvedHost = "gitlab.example.test"
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: "gitlab.example.test", username: "me")
        settings.glabPath = glab.glabPath
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"discussions_not_resolved","has_conflicts":false,"blocking_discussions_resolved":false,"user":{"can_merge":true}}"#.utf8))
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL,
            needsDiscussion: true, mergeRequest: request, isAuthored: true)
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"checked","notes":[{"id":10,"author":{"id":7},"body":"Please fix","system":false,"resolvable":true,"resolved":false},{"id":11,"author":{"id":3},"body":"Fixed and verified","system":false,"resolvable":true,"resolved":false}]}]"#.utf8))
        item.observedDiscussionFingerprint = ReviewVerdict.fingerprint(threads)
        let card = RemoteBoardAdapter.mergeActions(RemoteBoardAdapter.card(item, account: "me@host"),
            item: item, status: nil, monitor: monitor, account: "me@host")
        #expect(card.actions.contains { $0.kind == .checkThreads })
        #expect(!card.actions.contains { $0.kind == .resolveThreads })
        let prepared = ManualDiscussionResolution.Prepared(request: request, user: .init(id: 3, username: "me"), host: "gitlab.example.test",
            revision: glab.accountRevision, configuration: try MergeSubmissionFingerprint.configuration(settings),
            plan: ManualDiscussionResolution.plan(discussions: threads,
                assessment: .init(notes: [.init(noteID: 10, state: .addressed, reason: "Verified", publishedReplyNoteID: 11)]),
                authorID: 3, pendingDraftCount: 0), reviewFingerprint: item.observedDiscussionFingerprint)
        let checked = RemoteBoardAdapter.resolutionPreview(card, item: item, prepared: prepared, monitor: monitor)
        #expect(checked.actions.contains { $0.kind == .resolveThreads && $0.id == "resolveThreads:checked" && $0.confirmationText?.contains("Please fix") == true })
        settings.automation.autoMergeEnabled = true
        let changed = RemoteBoardAdapter.resolutionPreview(card, item: item, prepared: prepared, monitor: monitor)
        #expect(!changed.actions.contains { $0.kind == .resolveThreads })
    }

    func item() throws -> MergeRequestAttentionMonitor.Item {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Fix a crash",
            url: URL(string: "https://gitlab.example.org/group/project/-/merge_requests/2")!)
        item.drafts = try JSONDecoder().decode([GitLabDraftNote].self,
            from: Data(#"[{"id":11,"author_id":3,"note":"Please handle nil","position":{"new_path":"Sources/A.swift","new_line":12}}]"#.utf8))
        item.draftCount = 1
        return item
    }
    @Test func cardPreservesTheExactDraftTextAndBindsActionsToAccountAndContext() throws {
        let item = try item()
        let card = RemoteBoardAdapter.card(item, account: "me@host", extraActions: [.prepare], context: ["head-v1"])
        #expect(card.id == "mr:1:2")
        #expect(card.title == "Fix a crash")
        #expect(card.drafts.first?.body == "Please handle nil")
        #expect(card.drafts.first?.context == "Sources/A.swift:12")
        let token = try #require(card.actions.first?.token)
        #expect(RemoteBoardAdapter.card(item, account: "other@host", extraActions: [.prepare], context: ["head-v1"]).actions.first?.token != token)
        #expect(RemoteBoardAdapter.card(item, account: "me@host", extraActions: [.prepare], context: ["head-v2"]).actions.first?.token != token)
        var edited = item
        edited.drafts = []
        #expect(RemoteBoardAdapter.card(edited, account: "me@host", extraActions: [.prepare], context: ["head-v1"]).actions.first?.token != token)
    }
    @Test func phoneUsesTheSameThreeLanesAndPinnedOrderingAsTheMacBoard() throws {
        let first = try item()
        var pinned = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 3), title: "Pinned MR",
            url: URL(string: "https://gitlab.example.org/group/project/-/merge_requests/3")!)
        pinned.isAuthored = true
        let proposal = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 4), title: "Review proposal",
            url: URL(string: "https://gitlab.example.org/group/project/-/merge_requests/4")!)
        let pin = try #require(BoardCardPin.mergeRequest(host: "gitlab.example.org", username: "me", projectID: 1, iid: 3))
        let board = MergeRequestBoardSnapshot(own: [first, pinned], reviewed: [], todos: [], attention: [proposal],
            handoffs: [], host: "gitlab.example.org", username: "me", pinnedCards: [pin])
        let other = board.otherCards(jobs: [], host: "gitlab.example.org", username: "me", pinnedCards: [pin])
        let phone = RemoteBoardAdapter.project(board: board, other: other, session: UUID(), account: "me@gitlab.example.org")
        #expect(phone.lanes.map(\.id) == [.own, .reviewed, .other])
        #expect(phone.lanes[0].cards.map(\.title) == board.own.map { $0.item.title })
        #expect(phone.lanes[0].cards.first?.title == "Pinned MR")
        #expect(phone.lanes[2].cards.map(\.title) == ["Review proposal"])
        #expect(phone.lanes[2].cards.first?.actions.isEmpty == true)
    }

    @Test func anAgentCardWithoutAGitLabLinkIsStillVisibleOnThePhone() throws {
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Inspect old job", prompt: "", createdAt: Date(), allowsPush: false)
        let pin = try #require(BoardCardPin.mergeRequest(host: work.host, username: "me", projectID: 1, iid: 2))
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [], host: work.host, username: "me")
        let phone = RemoteBoardAdapter.project(board: board, other: [.init(id: pin, content: .job(job))], session: UUID(), account: "me@host")
        #expect(phone.lanes[2].cards.map(\.title) == ["Inspect old job"])
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running], [false, true])
    func activeOtherLaneJobsShareQueuedAndRunningProgress(state: AssistantJobExecution.State, proposal: Bool) throws {
        let item = try item()
        let target = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 1, iid: 2)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: target.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Follow-up", prompt: "", createdAt: Date(), allowsPush: false,
            execution: .init(state: state), mergeRequestURL: item.url, workflow: .followUp)
        let pin = try #require(BoardCardPin.mergeRequest(host: target.host, username: "me", projectID: 1, iid: 2))
        let content: MergeRequestBoardSnapshot.OtherCard.Content = proposal
            ? .proposal(.init(target: target, title: item.title, url: item.url, item: item, todos: [], intents: [], latestJob: job))
            : .job(job)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [], host: target.host, username: "me")
        let phone = RemoteBoardAdapter.project(board: board, other: [.init(id: pin, content: content)], session: UUID(), account: "me@host")
        let card = try #require(phone.lanes[2].cards.first)
        #expect(card.presentation?.status == (state == .queued ? "Queued for agent" : "Handling feedback"))
        #expect(card.presentation?.working == true)
        #expect(card.needsAttention == false && card.primaryCTA == nil && card.actions.isEmpty)
    }

    private func projected(_ item: MergeRequestAttentionMonitor.Item,
                           jobs: [AssistantAutomationRunner.Handoff] = []) throws -> [String: Any] {
        let board = MergeRequestBoardSnapshot(own: item.isAuthored ? [item] : [], reviewed: item.isAuthored ? [] : [item], todos: [], attention: [],
            handoffs: jobs, host: "gitlab.example.org", username: "me",
            humanAttention: item.humanActionRequired == false ? .empty : nil)
        let phone = RemoteBoardAdapter.project(board: board, other: [], session: UUID(), account: "me@host")
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(phone.cards[0])) as? [String: Any])
    }

    @Test func attentionAndReviewCommentsCTAReachThePhoneEvenWhenPublicationIsUnavailable() throws {
        var item = try item()
        item.isAuthored = true
        item.requiresDiscussionRecheck = true
        let card = try projected(item)
        #expect(card["needsAttention"] as? Bool == true)
        let cta = try #require(card["primaryCTA"] as? [String: Any])
        #expect(cta["title"] as? String == String(localized: .MRHumanAction.mrHumanActionActionReviewDrafts))
        #expect(cta["destination"] as? String == "drafts")
        let actions = try #require(card["actions"] as? [[String: Any]])
        #expect(actions.allSatisfy { $0["kind"] as? String == "deleteDraft" })
    }

    @Test func pipelineOwnershipOffersReviewHandoffWithoutInventingAWrite() throws {
        var item = try item()
        item.drafts = []; item.draftCount = 0
        item.isAuthored = true
        item.needsPipelineHandoff = true
        let card = try projected(item)
        #expect(card["needsAttention"] as? Bool == true)
        let cta = try #require(card["primaryCTA"] as? [String: Any])
        #expect(cta["title"] as? String == String(localized: .MRHumanAction.mrHumanActionActionReviewHandoff))
        #expect(cta["destination"] as? String == "overview")
        #expect((card["actions"] as? [Any])?.isEmpty == true)
    }

    @Test func neutralCardPreservesTheMacAttentionDecisionDespiteDrafts() throws {
        var item = try item()
        item.isAuthored = true
        item.humanActionRequired = false
        let card = try projected(item)
        #expect(card["needsAttention"] as? Bool == false)
        #expect(card["primaryCTA"] == nil)
    }

    @Test func stoppedRunCarriesTheMacRetryCTAAndReason() throws {
        var item = try item()
        item.isAuthored = true
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.org", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Retry fixture", prompt: "", createdAt: Date(), allowsPush: false,
            execution: .init(state: .blocked, blocker: "Tests could not start."),
            taskPrompt: "Review this MR", mergeRequestURL: item.url)
        let card = try projected(item, jobs: [job])
        #expect(card["needsAttention"] as? Bool == true)
        #expect(card["detail"] as? String == "Tests could not start.")
        let cta = try #require(card["primaryCTA"] as? [String: Any])
        #expect(cta["title"] as? String == String(localized: .MRHumanAction.mrHumanActionActionRetryRun))
        #expect(cta["destination"] as? String == "assistantRuns")
    }

    @Test func workingAndPublishingCardsKeepReadOnlyContentWithoutOfferingATask() throws {
        var item = try item()
        item.isAuthored = true
        item.humanActionRequired = true
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let original = RemoteBoardAdapter.card(item, account: "me@host", extraActions: [.prepare])
        #expect(!original.actions.isEmpty)
        let working = RemoteBoardAdapter.presentation(original, row: row, busy: true)
        #expect(working.needsAttention == false)
        #expect(working.actions.isEmpty)
        #expect(working.primaryCTA == nil)
        #expect(working.drafts == original.drafts)
        let publishing = RemoteBoardAdapter.presentation(original, row: row, confirmationState: .publishing)
        #expect(publishing.actions.isEmpty)
        #expect(publishing.primaryCTA == nil)
    }

    @Test func neutralReviewedCardUsesTheExactMacStatusAndNextStepTexts() throws {
        var item = try item()
        item.drafts = []; item.draftCount = 0
        item.humanActionRequired = false
        item.reviewingProgress = .waitingForOtherDiscussions
        let card = try projected(item)
        let texts = try #require(card["presentation"] as? [String: Any])
        #expect(texts["status"] as? String == String(localized: .ReviewingContext.reviewingOtherThreadsOpen))
        #expect(texts["nextStep"] as? String == String(localized: .ReviewingContext.reviewingWaitingOtherThreads))
        #expect(card["detail"] as? String == "")
        let cta = try #require(card["primaryCTA"] as? [String: Any])
        #expect(cta["title"] as? String == String(localized: .ReviewingContext.reviewingViewDiscussions))
    }

    @Test(arguments: [false, true])
    func phoneTextsAreTheMacPresentationForHumanAndNeutralCards(_ needsAttention: Bool) throws {
        var item = try item()
        item.isAuthored = true
        item.humanActionRequired = needsAttention
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let mac = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: mac)
        #expect(phone.detail == mac.message)
        #expect(phone.needsAttention == (mac.humanAction != nil))
        #expect(phone.presentation?.status == mac.status)
        #expect(phone.presentation?.nextStep == mac.nextStep)
        #expect(phone.presentation?.chips.map(\.title) == mac.chips.map { String(localized: $0.title) })
        #expect(phone.primaryCTA?.title == mac.actionLabel.map { String(localized: $0) })
    }

    @Test func ownLaneDoesNotAcquireReviewedStatusFromAnAuthorsIdentity() throws {
        var item = try item()
        item.drafts = []; item.draftCount = 0
        let board = MergeRequestBoardSnapshot(own: [item], reviewed: [], todos: [], attention: [],
            handoffs: [], host: "gitlab.example.org", username: "me", humanAttention: .empty)
        let phone = RemoteBoardAdapter.project(board: board, other: [], session: UUID(), account: "me@host")
        let card = try #require(phone.lanes.first?.cards.first)
        #expect(card.presentation?.status == "Monitoring MR")
        #expect(card.presentation?.nextStep == nil)
        #expect(card.primaryCTA == nil)
    }

    @Test func dependencyCheckingKeepsTheMacSetupLabelUntilTheAssistantIsReady() throws {
        var item = try item()
        item.drafts = []; item.draftCount = 0; item.reviewingProgress = .needsReview
        item.humanActionRequired = false
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let context = ReviewingContext(row: row, assistantReady: false, assistantChecking: true)
        #expect(context.nextStep == .runReview)
        let model = MRCardPresentation(row: row, reviewingContext: context, allowsRemoval: true, assistantReady: false)
        #expect(model.actionLabel.map { String(localized: $0) } == String(localized: .Board.boardCompactSetupCli))
    }

    @Test func sharedCardKeepsAnIndependentBlockedRunVisibleDuringDraftProofRecovery() throws {
        var item = try item()
        item.isAuthored = true
        item.draftProofRecoveryChecking = true
        item.authorFeedbackStatus = .init(head: item.mergeRequest?.sha ?? "head", fingerprint: "discussion", phase: .checking)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.org", projectID: item.id.projectID, iid: item.id.iid),
            username: "me", workspace: "", access: .gitLabRead), title: "Independent fix", prompt: "Fix",
            createdAt: Date(), allowsPush: true, execution: .init(state: .blocked, blocker: "Tests could not run."),
            taskPrompt: "Fix", mergeRequestURL: item.url, expectedHeadSHA: item.mergeRequest?.sha)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false, assistantReady: true)
        #expect(!model.busy)
        #expect(model.humanAction?.kind == .blockedRun)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: model)
        #expect(phone.needsAttention == true)
        #expect(phone.primaryCTA != nil)
    }

    @Test func pipelineRefreshShowsSharedProgressUntilANewerPipelineIsVisible() throws {
        var item = try item()
        item.isAuthored = true
        item.drafts = []; item.draftCount = 0
        item.failedPipeline = true
        item.humanActionRequired = false
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, automaticPipelineProgress: true)
        #expect(model.busy && model.working)
        #expect(model.status == "Handling pipeline")
        #expect(model.actionLabel == nil)
        #expect(model.chips.map { String(localized: $0.title) }.contains(String(localized: .PipelineAutomation.pipelineHandling)))
        #expect(!model.chips.map { String(localized: $0.title) }.contains(String(localized: .Board.boardCompactPipelineFailed)))
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: model)
        #expect(phone.needsAttention == false && phone.primaryCTA == nil)
        #expect(phone.presentation?.status == model.status)
    }

}
