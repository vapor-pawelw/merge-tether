import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct CommandCenterDisplayFrameTests {
    private let host = "gitlab.example.test"

    @Test func inboxSectionsKeepThePreparedCardOrderAndCountEveryCardOnce() throws {
        // given
        let proposal = item(42)
        let todo = todo(7)
        let job = job(90)
        let completion = MergeRequestLifecycleLedger.CompletionReceipt(id: UUID(),
            target: .init(host: host, username: "me", projectID: 1, iid: 91), kind: .merged,
            title: "Merged", url: item(91).url, observedAt: Date(), author: nil)
        let pin = try #require(BoardCardPin.todo(host: host, username: "me", id: todo.id))
        let pins: Set<BoardCardPin> = [pin]
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo], attention: [proposal],
            handoffs: [job], host: host, username: "me", pinnedCards: pins, completions: [completion])

        // when
        let frame = CommandCenterDisplayFrame(board: board, jobs: [job], host: host, username: "me", pinnedCards: pins)
        let expected = board.otherCards(jobs: [job], host: host, username: "me", pinnedCards: pins)

        // then
        #expect(frame.inbox.items.map(\.id) == expected.map(\.id))
        #expect(frame.inbox.items.count == 4)
        #expect(frame.inbox.triage.map(\.id) == Array(expected.prefix(2)).map(\.id))
        #expect(frame.inbox.jobs.count == 1 && frame.inbox.updates.count == 1)
        #expect(frame.inbox.triage.count + frame.inbox.jobs.count + frame.inbox.updates.count == frame.inbox.items.count)
        #expect(frame.inbox.items.first?.id == pins.first)
    }

    @Test func eachDisplayFrameUsesCurrentRowsWithoutMutatingTheEarlierFrame() throws {
        // given
        let original = try item(request(head: "head-a", title: "Before"))
        let changed = try item(request(head: "head-b", title: "After"))
        let first = CommandCenterDisplayFrame(board: board(reviewed: [original]), jobs: [],
            host: host, username: "me", pinnedCards: [])
        let next = CommandCenterDisplayFrame(board: board(own: [changed]), jobs: [],
            host: host, username: "me", pinnedCards: [])

        // when
        let before = CommandCenterDisplayFrame.Detail(item: original, board: first.board, host: host, username: "me")
        let after = CommandCenterDisplayFrame.Detail(item: original, board: next.board, host: host, username: "me")

        // then
        #expect(before.isReviewed && before.item.mergeRequest?.sha == "head-a")
        #expect(!after.isReviewed && after.item.mergeRequest?.sha == "head-b")
        #expect(after.row?.displayTitle == "After")
        #expect(first.board.reviewed.first?.item.mergeRequest?.sha == "head-a")
    }

    @Test func detailsKeepTheOriginalFallbackAfterRemovalAndRejectAnotherHost() {
        let original = item(42)
        let removed = CommandCenterDisplayFrame.Detail(item: original, board: board(), host: host, username: "me")
        #expect(removed.row == nil && !removed.isReviewed && removed.item.url == original.url)
        let switched = CommandCenterDisplayFrame.Detail(item: original, board: board(reviewed: [original]),
            host: "other.example.test", username: "me")
        #expect(switched.row == nil && !switched.isReviewed)
    }

    @Test func detailsResolveLinkedSelectionsBeforeCheckingReviewedMembership() {
        let current = item(42)
        var linked = current
        linked.url = URL(string: current.url.absoluteString + "#note_7")!
        let selected = CommandCenterDisplayFrame.Detail(item: linked, board: board(reviewed: [current]),
            host: host, username: "me")
        #expect(selected.item.url == current.url && selected.isReviewed)
    }

    @Test func aRetainedIntentRowDoesNotAcquireReviewedCatalogMembership() throws {
        // given
        let request = try request(head: "head-a", title: "Retained")
        let original = item(request)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: host, username: "me", projectID: 1, iid: 42),
            kind: .review, state: .pending, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
            headSHA: "head-a", updatedAt: Date())
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", intents: [intent])

        // when
        let selected = CommandCenterDisplayFrame.Detail(item: original, board: board, host: host, username: "me")

        // then
        #expect(board.reviewed.map(\.id) == [original.id])
        #expect(selected.row != nil && !selected.isReviewed)
    }

    @Test(arguments: ["idle", "pipeline", "conflict", "loading", "failed", "running"])
    func aPreparedCardInputRetainsBusyFailureAndActionDecisions(_ change: String) throws {
        // given
        let suite = "CommandCenterPreparedCardTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.onboardingCompleted = true
        let monitor = TodoMonitorService(settings: settings, glab: GlabService())
        defer { monitor.stopTimer() }
        var checkpoint = try item(request(head: "head-a", title: "Checked"))
        checkpoint.requiresCommentReview = true
        checkpoint.draftCount = 1
        var latest = job(42)
        if change == "running" { latest.execution = .init(state: .running) }
        let row = MergeRequestBoardSnapshot.Row(item: checkpoint, latestJob: change == "running" ? latest : nil, intents: [])
        var input = MRBoardProjector.RowInput(account: .init(host: host, username: "me", revision: 1),
            automation: settings.automation, workflowEntries: [])
        input.pipelineProcessing = change == "pipeline"
        input.conflictProcessing = change == "conflict"
        input.catalogLoading = change == "loading"
        input.catalogReadFailed = change == "failed"

        // when
        let model = MRCardPresentation(row: row, monitor: monitor, allowsRemoval: false, input: input)

        // then
        #expect(model.actionsBlocked == ["pipeline", "conflict", "loading", "running"].contains(change))
        #expect(model.working == ["pipeline", "conflict", "loading", "running"].contains(change))
        #expect(model.refreshFailed == (change == "failed"))
        if change == "idle" || change == "failed" { #expect(model.humanAction != nil && model.actionLabel != nil) }
    }

    @Test(arguments: ["host", "username", "revision"])
    func rebuildingAFrameForAnAccountChangeCannotReuseTheOldCatalog(_ change: String) throws {
        // given
        let original = try item(request(head: "head-a", title: "Before"))
        var input = MRBoardProjector.Input(account: .init(host: change == "host" ? "other.test" : host,
            username: change == "username" ? "other" : "me", revision: change == "revision" ? 2 : 1))
        input.attention = .init(host: host, username: "me", revision: 1,
            evidence: [original], attention: [original], catalog: [original])

        // when
        let frame = CommandCenterDisplayFrame(board: MRBoardProjector(input: input).board(), jobs: [],
            host: input.account.host, username: input.account.username, pinnedCards: [])
        let selected = CommandCenterDisplayFrame.Detail(item: original, board: frame.board,
            host: input.account.host, username: input.account.username)

        // then
        #expect(frame.board.own.isEmpty && frame.board.reviewed.isEmpty)
        #expect(selected.row == nil && !selected.isReviewed)
        #expect(frame.inbox.items.isEmpty)
    }

    @Test func preparedBoardKeepsPinnedAndPreservedLaneOrder() throws {
        let rows = [item(1), item(2), item(3)]
        let pin = try #require(BoardCardPin.mergeRequest(host: host, username: "me", projectID: 1, iid: 3))
        let board = MergeRequestBoardSnapshot(own: rows, reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", pinnedCards: [pin], preservedOrder: [rows[1].id: 1, rows[0].id: 2])
        let frame = CommandCenterDisplayFrame(board: board, jobs: [], host: host, username: "me", pinnedCards: [pin])
        #expect(frame.board.own.map(\.id.iid) == [3, 2, 1])
    }

    @Test func preservingOrderKeepsTheExistingEvidenceAndInbox() throws {
        // given
        var checkpoint = try item(request(head: "head-a", title: "Checked"))
        checkpoint.drafts = [.init(id: 7, authorID: 3, note: "Private reply", discussionID: nil, position: nil)]
        checkpoint.draftCount = 1
        checkpoint.observedDiscussionFingerprint = "checked-discussion"
        let other = item(43)
        let todo = todo(8)
        let job = job(90)
        let baseline = MergeRequestBoardSnapshot(own: [checkpoint, other], reviewed: [], todos: [todo],
            attention: [checkpoint], handoffs: [job], host: host, username: "me")

        // when
        let reordered = baseline.preservingOrder([other.id: 0], host: host, username: "me", pinnedCards: [])

        // then
        #expect(reordered.own.map(\.id.iid) == [43, 42])
        let preserved = try #require(reordered.own.last)
        #expect(preserved.item.drafts == checkpoint.drafts)
        #expect(preserved.item.observedDiscussionFingerprint == "checked-discussion")
        #expect(preserved.item.mergeRequest?.sha == "head-a")
        #expect(reordered.otherCards(jobs: [job], host: host, username: "me", pinnedCards: []).map(\.id)
            == baseline.otherCards(jobs: [job], host: host, username: "me", pinnedCards: []).map(\.id))
    }

    @Test(arguments: ["current", "missing-account", "read-failed", "drafts"])
    func reorderingPreparedRowsMatchesConstructionWithTheSameRanks(_ scenario: String) throws {
        // given
        var checkpoint = try item(request(head: "head-a", title: "Checked"))
        checkpoint.draftProofRecoveryReadFailure = scenario == "read-failed"
        checkpoint.requiresCommentReview = true
        var draft = item(43)
        draft.draftFromTodo = true
        let own = [checkpoint, item(44), item(45)]
        let reviewed = [draft, item(46)]
        let pins: Set<BoardCardPin> = [try #require(BoardCardPin.mergeRequest(host: host, username: "me", projectID: 1, iid: 45))]
        let positions = [own[1].id: 1, checkpoint.id: 2, reviewed[1].id: 0]
        let accountHost = scenario == "missing-account" ? nil : host
        let username: String? = scenario == "missing-account" ? nil : "me"
        var automation = AutomationSettings()
        automation.applyPreset(.full, for: .codex)
        let grouping: MRBoardGrouping = scenario == "drafts" ? .drafts : .withoutAutomation
        func make(_ ranks: [MergeRequestAttentionMonitor.Item.ID: Int]) -> MergeRequestBoardSnapshot {
            .init(own: own, reviewed: reviewed, todos: [todo(8)], attention: [checkpoint, item(47)],
                handoffs: [], host: accountHost, username: username, pinnedCards: pins, preservedOrder: ranks,
                automation: automation, grouping: grouping)
        }

        // when
        let prepared = make([:]).preservingOrder(positions, host: accountHost, username: username, pinnedCards: pins)
        let expected = make(positions)

        // then
        #expect(prepared.own.map(\.id) == expected.own.map(\.id))
        #expect(prepared.reviewed.map(\.id) == expected.reviewed.map(\.id))
        #expect(prepared.otherMergeRequests.map(\.id) == expected.otherMergeRequests.map(\.id))
        #expect(prepared.proposals.map(\.id) == expected.proposals.map(\.id))
        #expect(prepared.otherTodos == expected.otherTodos)
        #expect(prepared.own.first { $0.id == checkpoint.id }?.item.draftProofRecoveryReadFailure
            == (scenario == "read-failed"))
        #expect(prepared.otherCards(jobs: [], host: accountHost, username: username, pinnedCards: pins).map(\.id)
            == expected.otherCards(jobs: [], host: accountHost, username: username, pinnedCards: pins).map(\.id))
    }

    private func item(_ iid: Int) -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: 1, iid: iid), title: "MR \(iid)",
            url: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)")!)
    }

    private func item(_ request: GitLabMergeRequest) -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: request.projectID, iid: request.iid), title: request.title,
            url: request.webURL, mergeRequest: request)
    }

    private func request(head: String, title: String) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":42,"author":{"id":3,"username":"author","name":"Author"},"title":"\(title)",
         "web_url":"https://\(host)/g/p/-/merge_requests/42","state":"opened","sha":"\(head)",
         "source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
    }

    private func board(own: [MergeRequestAttentionMonitor.Item] = [], reviewed: [MergeRequestAttentionMonitor.Item] = []) -> MergeRequestBoardSnapshot {
        .init(own: own, reviewed: reviewed, todos: [], attention: [], handoffs: [], host: host, username: "me")
    }

    private func todo(_ id: Int) -> Todo {
        .init(id: id, actionName: .unknown("new_event"), targetType: .mergeRequest,
            targetURL: item(80).url, body: "Read", createdAt: Date(), state: "pending",
            project: .init(id: 1, nameWithNamespace: "Group / Project", pathWithNamespace: "g/p"),
            author: .init(id: 3, username: "author", name: "Author", avatarURL: nil),
            target: .init(id: 80, iid: 80, title: "Read", state: "opened", draft: nil, workInProgress: nil))
    }

    private func job(_ iid: Int) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: iid),
            username: "me", workspace: "", access: .gitLabRead), title: "Work", prompt: "", createdAt: Date(),
            allowsPush: false, execution: .init(state: .failed))
    }
}
