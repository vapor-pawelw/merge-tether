import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MergeRequestBoardSnapshotTests {
    private let host = "gitlab.example.org"
    private func item(_ iid: Int, attention: Bool = false) -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: 1, iid: iid), title: "MR \(iid)",
              url: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)")!, needsDiscussion: attention)
    }
    private func todo(_ id: Int, projectID: Int = 1, iid: Int = 42, host: String = "gitlab.example.org",
                      type: TargetType = .mergeRequest, action: ActionName = .reviewRequested, suffix: String = "", draft: Bool = false) -> Todo {
        .init(id: id, actionName: action, targetType: type,
              targetURL: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)" + suffix)!, body: "Review",
              createdAt: Date(), state: "pending", project: .init(id: projectID, nameWithNamespace: "G / P", pathWithNamespace: "g/p"),
              author: .init(id: 9, username: "author", name: "Author", avatarURL: nil),
              target: .init(id: id, iid: iid, title: "Review", state: "opened", draft: draft, workInProgress: false))
    }
    private func job(_ iid: Int, state: AssistantJobExecution.State, at: Date = Date()) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: iid),
            username: "me", workspace: "", access: .gitLabRead), title: "Run", prompt: "", createdAt: at,
            allowsPush: false, execution: .init(state: state))
    }
    private func snapshot(own: [MergeRequestAttentionMonitor.Item], reviewed: [MergeRequestAttentionMonitor.Item] = [],
                          todos: [Todo] = [], handoffs: [AssistantAutomationRunner.Handoff] = []) -> MergeRequestBoardSnapshot {
        .init(own: own, reviewed: reviewed, todos: todos, attention: [], handoffs: handoffs, host: host, username: "me")
    }

    @Test(arguments: ["pausedReady", "draft", "closed", "merged"])
    func pipelineTabNoticesUseCanonicalMRActivityAndDisplayMetadata(_ state: String) throws {
        let json = """
        {"project_id":1,"iid":42,"author":{"id":7,"username":"author","name":"Author"},"title":"MR",
         "web_url":"https://\(host)/g/p/-/merge_requests/42","state":"\(["closed", "merged"].contains(state) ? state : "opened")",
         "draft":\(state == "draft"),"source_branch":"feature","target_branch":"main","labels":[]}
        """
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        if state == "pausedReady" {
            configuration.scope.setEnabled(false, for: .init(host: host, username: "me", projectID: 1, iid: 42))
        }
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [],
            todos: [todo(1, action: .unknown("new_event"), suffix: "/pipelines")], attention: [], handoffs: [],
            host: host, username: "me", automation: configuration, displayRequests: [request])
        let cards = board.otherCards(jobs: [], host: host, username: "me", pinnedCards: [])
        #expect(board.otherTodos.count == 1 && board.proposals.isEmpty)
        #expect(cards.first?.activityGroup == (["closed", "merged"].contains(state) ? .finished : .inactive))
    }

    @Test(arguments: ["draft", "merged", "closed"])
    func jobOnlyCardsGroupUsingSharedDisplayMetadata(_ state: String) throws {
        let json = """
        {"project_id":1,"iid":42,"author":{"id":7,"username":"author","name":"Author"},"title":"MR",
         "web_url":"https://\(host)/g/p/-/merge_requests/42","state":"\(state == "draft" ? "opened" : state)","draft":\(state == "draft"),
         "source_branch":"feature","target_branch":"main","labels":[]}
        """
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        let run = job(42, state: .failed)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [run],
            host: host, username: "me", automation: configuration, displayRequests: [request])
        let cards = board.otherCards(jobs: [run], host: host, username: "me", pinnedCards: [])
        #expect(cards.count == 1)
        #expect(cards.first?.activityGroup == (state == "draft" ? .inactive : .finished))
    }

    @Test(arguments: [false, true])
    func todoOnlyProposalGroupingUsesFreshDisplayStateInsteadOfTheOlderTodoFlag(_ liveDraft: Bool) throws {
        let json = """
        {"project_id":1,"iid":42,"author":{"id":7,"username":"author","name":"Author"},"title":"MR",
         "web_url":"https://\(host)/g/p/-/merge_requests/42","state":"opened","draft":\(liveDraft),
         "source_branch":"feature","target_branch":"main","labels":[]}
        """
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo(1, draft: !liveDraft)], attention: [],
            handoffs: [], host: host, username: "me", automation: configuration, displayRequests: [request])
        let cards = board.otherCards(jobs: [], host: host, username: "me", pinnedCards: [])
        #expect(board.own.isEmpty && board.reviewed.isEmpty && board.proposals.count == 1)
        #expect(cards.first?.activityGroup == (liveDraft ? .inactive : .regular))
    }

    @Test(arguments: [false, true])
    func automationGroupsReadyAndDraftRowsByEffectiveActivityBeforePins(_ reviewedLane: Bool) throws {
        func mr(_ iid: Int, draft: Bool, state: String = "opened") throws -> MergeRequestAttentionMonitor.Item {
            var row = item(iid, attention: iid == 3)
            let json = """
            {"project_id":1,"iid":\(iid),"author":{"id":3,"username":"me","name":"Me"},"title":"MR",
             "web_url":"https://\(host)/g/p/-/merge_requests/\(iid)","state":"\(state)","draft":\(draft),
             "source_branch":"feature","target_branch":"main","labels":[]}
            """
            row.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
            return row
        }
        let rows = try [mr(2, draft: false), mr(4, draft: true), mr(1, draft: false), mr(3, draft: true), mr(5, draft: true, state: "closed")]
        let inactive = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.scope.setEnabled(false, for: inactive)
        configuration.scope.setEnabled(true, for: .init(host: host, username: "me", projectID: 1, iid: 3))
        let pin = try #require(BoardCardPin.mergeRequest(host: host, username: "me", projectID: 1, iid: 2))
        let board = MergeRequestBoardSnapshot(own: reviewedLane ? [] : rows, reviewed: reviewedLane ? rows : [],
            todos: [], attention: [], handoffs: [], host: host, username: "me", pinnedCards: [pin],
            preservedOrder: [rows[0].id: 0], automation: configuration)
        let displayed = reviewedLane ? board.reviewed : board.own
        #expect(displayed.map(\.id.iid) == [5, 3, 1, 2, 4])
        #expect(displayed.first { $0.id.iid == 3 }?.item.mergeRequest?.draft == true)
    }

    @Test func otherItemsUseTheSameInactiveGroupWithoutDimmingNonMRTodos() throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.scope.setEnabled(false, for: .init(host: host, username: "me", projectID: 1, iid: 2))
        let pin = try #require(BoardCardPin.todo(host: host, username: "me", id: 2))
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [],
            todos: [todo(2, iid: 2, action: .mentioned), todo(1, type: .issue)], attention: [], handoffs: [],
            host: host, username: "me", pinnedCards: [pin], automation: configuration)
        let cards = board.otherCards(jobs: [], host: host, username: "me", pinnedCards: [pin])
        #expect(cards.map(\.activityGroup) == [.regular, .inactive])
        #expect(cards.last?.id == pin)
    }

    @Test(arguments: ["merged", "closed"])
    func finishedRowsPrecedePinsAndPreservedNonterminalPositions(_ state: String) throws {
        var finished = item(2)
        let json = """
        {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Finished",
         "web_url":"https://\(host)/g/p/-/merge_requests/2","state":"\(state)","draft":false,
         "source_branch":"feature","target_branch":"main","labels":[]}
        """
        finished.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        var oldAttention = finished
        oldAttention.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(json.replacingOccurrences(of: "\"state\":\"\(state)\"", with: "\"state\":\"opened\"").utf8))
        oldAttention.needsDiscussion = true
        let pin = try #require(BoardCardPin.mergeRequest(host: host, username: "me", projectID: 1, iid: 1))
        let board = MergeRequestBoardSnapshot(own: [item(1, attention: true), finished, item(3)], reviewed: [],
            todos: [], attention: [oldAttention], handoffs: [], host: host, username: "me", pinnedCards: [pin],
            preservedOrder: [item(3).id: 0, item(1).id: 1])
        #expect(board.own.map(\.id.iid) == [2, 3, 1])
        #expect(board.own.first?.item.mergeRequest?.state == state)
    }

    @Test func cancelledRemindersRemainHistoryWithoutOperationalAttentionOrStandaloneRetryCards() throws {
        var reminder = job(42, state: .cancelled)
        reminder.workflow = .draftReply
        #expect(reminder.isObsoleteReminder)
        #expect(reminder.execution?.state == .cancelled)
        let board = snapshot(own: [item(42)], handoffs: [reminder])
        let row = try #require(board.own.first)
        #expect(!row.needsAttention)
        #expect(row.latestJob == nil)
        let direct = MergeRequestBoardSnapshot.Row(item: item(42), latestJob: reminder, intents: [])
        #expect(!direct.needsAttention)
        #expect(MRHumanAction(row: direct, assistantReady: true) == nil)
        let orphan = snapshot(own: [], handoffs: [reminder])
        #expect(orphan.otherCards(jobs: [reminder], host: host, username: "me", pinnedCards: []).isEmpty)
    }

    @Test func retiringANewerReminderDoesNotHideAnOlderGenuineReviewFailure() throws {
        var reminder = job(42, state: .cancelled, at: Date(timeIntervalSince1970: 200))
        reminder.workflow = .draftReply
        var review = job(42, state: .failed, at: Date(timeIntervalSince1970: 100))
        review.workflow = .review
        let row = try #require(snapshot(own: [item(42)], handoffs: [review, reminder]).own.first)
        #expect(row.latestJob?.id == review.id)
        #expect(row.needsAttention)
        var ordinaryCancellation = review
        ordinaryCancellation.execution = .init(state: .cancelled)
        #expect(!ordinaryCancellation.isObsoleteReminder)
        #expect(snapshot(own: [item(42)], handoffs: [ordinaryCancellation]).own.first?.needsAttention == true)
    }
    @Test func attentionFirstPreservesRelativeOrderAndUsesLatestJob() {
        let board = snapshot(own: [item(1), item(2, attention: true), item(3), item(4, attention: true)],
            handoffs: [job(3, state: .failed)])
        #expect(board.own.map(\.item.id.iid) == [2, 3, 4, 1])
        let recovered = snapshot(own: [item(1), item(3)],
            handoffs: [job(3, state: .failed, at: .distantPast), job(3, state: .succeeded)])
        #expect(recovered.own.map(\.item.id.iid) == [1, 3])
    }
    private func addressedFeedbackItem() throws -> MergeRequestAttentionMonitor.Item {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":42,"title":"My MR","author":{"id":3,"username":"me","name":"Me"},"web_url":"https://gitlab.example.org/g/p/-/merge_requests/42","state":"opened","draft":false,"source_branch":"feature","target_branch":"main","labels":[],"sha":"abc"}"#.utf8))
        let note = GitLabMergeRequestDiscussion.Note(id: 40, author: .init(id: 8, username: "reviewer", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Please handle the fallback.")
        var result = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 42), title: request.title,
            url: request.webURL, needsDiscussion: true, mergeRequest: request, isAuthored: true, feedback: [note])
        result.observedDiscussionFingerprint = "current-conversation"
        result.authorFeedbackStatus = .init(head: "abc", fingerprint: "current-conversation", phase: .complete,
            findings: [.init(id: 40, discussionID: "thread", reviewerID: 8, reviewerUsername: "reviewer",
                state: .waitingAcceptance, reason: "The correction is verified; awaiting the reviewer.", waitingForReviewers: ["reviewer"])],
            addressedNoteIDs: [40])
        return result
    }

    @Test func verifiedFeedbackAwaitingOnlyTheReviewerIsQuietOnCatalogFallback() throws {
        let original = try addressedFeedbackItem()
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(!row.needsAttention)
        #expect(!row.item.needsDiscussion && row.item.feedback.isEmpty)
        #expect(row.item.authorFeedbackStatus?.waitingForReviewer == true)
        #expect(original.needsDiscussion && !original.feedback.isEmpty)
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func activeAutomationDoesNotAskForHumanAttention(_ state: AssistantJobExecution.State) throws {
        let row = try #require(snapshot(own: [item(42, attention: true)], handoffs: [job(42, state: state)]).own.first)
        #expect(!row.needsAttention)
        #expect(row.latestJob?.execution?.state == state)
    }

    @Test func readOnlyVerificationIsProcessingRatherThanHumanAttention() throws {
        var original = try addressedFeedbackItem()
        original.authorFeedbackStatus?.phase = .checking
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(!row.needsAttention)
        #expect(row.item.authorFeedbackStatus?.phase == .checking)
    }

    @Test func boardUsesTheSameHumanActionsAsTheMenuIndicator() throws {
        let projection = UserAttentionSnapshot(candidates: [
            .init(id: "\(host)/me/mr/1/42", title: "Automatic reply", actions: [.init(reason: .drafts, token: "auto", automatic: true)]),
            .init(id: "\(host)/me/mr/1/43", title: "Needs publication", actions: [.init(reason: .drafts, token: "human")])])
        let board = MergeRequestBoardSnapshot(own: [item(42, attention: true), item(43)], reviewed: [],
            todos: [], attention: [], handoffs: [], host: host, username: "me", humanAttention: projection)
        #expect(board.own.map(\.id.iid) == [43, 42])
        #expect(board.own.first?.needsAttention == true)
        #expect(board.own.last?.needsAttention == false)
        #expect(board.own.last?.item.needsAttention == false)
        #expect(board.own.last?.item.needsDiscussion == true)
    }

    @Test func awaitingReviewerPreservesIndependentActions() throws {
        var original = try addressedFeedbackItem()
        original.draftCount = 2
        original.hasConflict = true
        original.failedPipeline = true
        original.needsChanges = true
        original.hasOtherUnresolvedDiscussions = true
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(row.needsAttention)
        #expect(row.item.draftCount == 2 && row.item.hasConflict && row.item.failedPipeline && row.item.needsChanges)
        #expect(row.item.needsDiscussion)
        #expect(row.item.feedback.isEmpty)
    }

    @Test func failedVerificationCannotHideUnresolvedFeedback() throws {
        var original = try addressedFeedbackItem()
        original.authorFeedbackStatus?.phase = .failed
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(row.needsAttention && row.item.needsDiscussion && !row.item.feedback.isEmpty)
    }

    @Test(arguments: ["new-conversation", "missing-snapshot"])
    func changedOrUnavailableDiscussionEvidenceCannotHideFeedback(_ snapshot: String) throws {
        var original = try addressedFeedbackItem()
        original.observedDiscussionFingerprint = snapshot == "missing-snapshot" ? nil : snapshot
        let row = try #require(self.snapshot(own: [original]).own.first)
        #expect(row.needsAttention && row.item.needsDiscussion && !row.item.feedback.isEmpty)
        #expect(row.item.authorFeedbackStatus == nil)
    }

    @Test(arguments: [AuthorFeedbackStatus.Phase.checking, .failed, .waitingPublication], ["new-conversation", "missing-snapshot"])
    func informativeFeedbackStatesRemainVisibleWithoutCompletedTextProof(_ phase: AuthorFeedbackStatus.Phase, _ text: String) throws {
        var original = try addressedFeedbackItem()
        original.authorFeedbackStatus?.phase = phase
        original.observedDiscussionFingerprint = text == "missing-snapshot" ? nil : text
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(row.item.authorFeedbackStatus?.phase == phase)
        #expect(row.item.needsDiscussion && row.item.feedback.map(\.id) == [40])
    }

    @Test func verdictForAnOlderSourceCannotHideFeedback() throws {
        var original = try addressedFeedbackItem()
        original.authorFeedbackStatus = .init(head: "previous-head", fingerprint: "current-conversation", phase: .complete,
            findings: original.authorFeedbackStatus!.findings, addressedNoteIDs: [40])
        let row = try #require(snapshot(own: [original]).own.first)
        #expect(row.needsAttention && row.item.needsDiscussion && !row.item.feedback.isEmpty)
        #expect(row.item.authorFeedbackStatus == nil)
    }

    @Test func waitingForReviewerDoesNotHideAnUnaddressedNoteOrMissingReply() throws {
        var original = try addressedFeedbackItem()
        let unassessed = GitLabMergeRequestDiscussion.Note(id: 41, author: .init(id: 8, username: "reviewer", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Also cover the timeout.")
        original.feedback.append(unassessed)
        var row = try #require(snapshot(own: [original]).own.first)
        #expect(row.needsAttention && row.item.feedback.map(\.id) == [41])
        original.feedback.removeLast()
        original.authorFeedbackStatus?.replyNoteIDs = [40]
        row = try #require(snapshot(own: [original]).own.first)
        #expect(row.needsAttention && row.item.feedback.map(\.id) == [40])
    }

    @Test func reviewedDraftMRsStayLastEvenWhenTheyNeedAttention() {
        var draft = item(1, attention: true)
        draft.draftFromTodo = true
        let board = snapshot(own: [draft, item(4)], reviewed: [draft, item(2), item(3, attention: true)])
        #expect(board.reviewed.map(\.item.id.iid) == [3, 2, 1])
        #expect(board.own.map(\.item.id.iid) == [1, 4])
    }
    @Test(arguments: [AssistantJobExecution.State.failed, .blocked, .interrupted, .cancelled])
    func problematicJobPromotesCard(state: AssistantJobExecution.State) {
        #expect(snapshot(own: [item(1), item(2)], handoffs: [job(2, state: state)]).own.map(\.item.id.iid) == [2, 1])
    }
    @Test func partitionsTodosByHostProjectIIDAndType() {
        let board = snapshot(own: [item(42)], reviewed: [item(43)], todos: [todo(1), todo(2, iid: 43),
            todo(3, host: "other.example.org"), todo(4, projectID: 9), todo(5, iid: 44), todo(6, type: .issue)])
        #expect(board.otherTodos.map(\.id) == [1, 2, 3, 6])
        #expect(board.proposals.flatMap(\.todos).map(\.id) == [4, 5])
    }
    @Test func rawManagedEventStaysReadableUntilDurablyRouted() {
        let board = snapshot(own: [item(1), item(42)], todos: [todo(1)])
        #expect(board.own.map(\.item.id.iid) == [1, 42])
        #expect(board.otherTodos.map(\.id) == [1])
        #expect(board.proposals.isEmpty)
    }
    @Test func attentionReasonsAndJobStayOnMRCardInsteadOfOtherLane() {
        let request = item(42)
        var attention = MergeRequestAttentionMonitor.Item(id: request.id, title: request.title,
            url: URL(string: request.url.absoluteString + "#note_40")!, draftCount: 2, canApprove: true,
            needsPipelineHandoff: true)
        attention.needsDiscussion = true
        let job = job(42, state: .failed)
        let board = MergeRequestBoardSnapshot(own: [request], reviewed: [], todos: [todo(1)], attention: [attention],
            handoffs: [job], host: host, username: "me", routedTodoIDs: [1])
        #expect(board.own.count == 1)
        #expect(board.own.first?.item.draftCount == 2)
        #expect(board.own.first?.item.canApprove == true)
        #expect(board.own.first?.item.needsPipelineHandoff == true)
        #expect(board.own.first?.latestJob?.id == job.id)
        #expect(board.otherMergeRequests.isEmpty && board.otherTodos.isEmpty)
    }

    private func intent(_ iid: Int = 42, state: MRTodoIntent.State = .pending, kind: MRTodoIntent.Kind = .review) throws -> MRTodoIntent {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":\(iid),"title":"Review","author":{"id":9,"username":"author","name":"Author"},
         "web_url":"https://gitlab.example.org/g/p/-/merge_requests/\(iid)","state":"opened",
         "source_branch":"fix","target_branch":"main","labels":[],"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        """.utf8))
        return .init(id: UUID(), target: .init(host: host, username: "me", projectID: 1, iid: iid), kind: kind,
            state: state, todoIDs: [1], noteIDs: [], sourceEvents: [], request: request,
            headSHA: request.sha!, updatedAt: Date())
    }

    @Test func unknownEventOnManagedMRStaysReadableOnlyInOther() {
        let board = snapshot(own: [item(42)], todos: [todo(1, action: .unknown("new_event"))])
        #expect(board.otherTodos.map(\.id) == [1])
        #expect(board.proposals.isEmpty)
    }

    @Test func routedNotificationLeavesDurableActionWithoutRawDuplicate() throws {
        let durable = try intent()
        let board = MergeRequestBoardSnapshot(own: [item(42)], reviewed: [], todos: [todo(1)], attention: [],
            handoffs: [], host: host, username: "me", intents: [durable], routedTodoIDs: [1])
        #expect(board.own.first?.intents.map(\.id) == [durable.id])
        #expect(board.own.first?.needsAttention == true)
        #expect(board.otherTodos.isEmpty && board.proposals.isEmpty)
    }

    @Test func oldIntentTodoIDCannotHideAnEventWithoutItsCurrentRoutingReceipt() throws {
        let durable = try intent(state: .completed)
        let board = MergeRequestBoardSnapshot(own: [item(42)], reviewed: [], todos: [todo(1)], attention: [],
            handoffs: [], host: host, username: "me", intents: [durable], routedTodoIDs: [])
        #expect(board.otherTodos.map(\.id) == [1])
    }

    @Test func foreignMRNotificationsBecomeOneProposalPerStrictTarget() {
        let board = snapshot(own: [], todos: [todo(1), todo(2), todo(3, projectID: 9),
            todo(4, host: "other.example.org")])
        #expect(board.proposals.count == 2)
        #expect(board.proposals.first?.todos.map(\.id) == [1, 2])
        #expect(board.otherTodos.map(\.id) == [4])
    }

    @Test(arguments: [MRTodoIntent.Kind.review, .followUp, .pipeline, .conflict])
    func temporarilyMissingManagedCatalogKeepsDurableWorkInReviewing(kind: MRTodoIntent.Kind) throws {
        let durable = try intent(kind: kind)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", intents: [durable])
        #expect(board.reviewed.first?.intents.map(\.id) == [durable.id])
        #expect(board.proposals.isEmpty)
    }

    @Test(arguments: [MRTodoIntent.State.pending, .completed])
    func refreshOnlyHistoryDoesNotRestoreUnmanagedForeignReviewingRows(state: MRTodoIntent.State) throws {
        let receipt = try intent(state: state, kind: .refresh)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", intents: [receipt])
        #expect(board.reviewed.isEmpty)
        #expect(board.proposals.isEmpty)
    }

    @Test func explicitIgnoreSuppressesOnlyTheMatchingMRIdentity() {
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 42)
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo(1), todo(2, iid: 43), todo(3, type: .issue)],
            attention: [], handoffs: [], host: host, username: "me", ignoredTargets: [target])
        #expect(board.proposals.count == 1 && board.proposals.first?.target.iid == 43)
        #expect(board.otherTodos.map(\.id) == [3])
    }

    @Test func pipelineTabEventsShareOneCanonicalMRProposal() {
        let board = snapshot(own: [], todos: [todo(1, action: .buildFailed, suffix: "/pipelines"), todo(2)])
        #expect(board.proposals.count == 1)
        #expect(board.proposals.first?.url.absoluteString == "https://gitlab.example.org/g/p/-/merge_requests/42")
        #expect(board.proposals.first?.todos.map(\.id) == [1, 2])
        #expect(board.otherTodos.isEmpty)
    }

    @Test func malformedPipelineSubpathRemainsReadableInsteadOfProposal() {
        let board = snapshot(own: [], todos: [todo(1, action: .buildFailed, suffix: "/pipelines/extra")])
        #expect(board.proposals.isEmpty)
        #expect(board.otherTodos.map(\.id) == [1])
    }

}
