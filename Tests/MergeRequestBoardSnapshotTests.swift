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
                      type: TargetType = .mergeRequest, action: ActionName = .reviewRequested, suffix: String = "") -> Todo {
        .init(id: id, actionName: action, targetType: type,
              targetURL: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)" + suffix)!, body: "Review",
              createdAt: Date(), state: "pending", project: .init(id: projectID, nameWithNamespace: "G / P", pathWithNamespace: "g/p"),
              author: .init(id: 9, username: "author", name: "Author", avatarURL: nil),
              target: .init(id: id, iid: iid, title: "Review", state: "opened", draft: false, workInProgress: false))
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
    @Test func attentionFirstPreservesRelativeOrderAndUsesLatestJob() {
        let board = snapshot(own: [item(1), item(2, attention: true), item(3), item(4, attention: true)],
            handoffs: [job(3, state: .failed)])
        #expect(board.own.map(\.item.id.iid) == [2, 3, 4, 1])
        let recovered = snapshot(own: [item(1), item(3)],
            handoffs: [job(3, state: .failed, at: .distantPast), job(3, state: .succeeded)])
        #expect(recovered.own.map(\.item.id.iid) == [1, 3])
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

    private func intent(_ iid: Int = 42, state: MRTodoIntent.State = .pending) throws -> MRTodoIntent {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":\(iid),"title":"Review","author":{"id":9,"username":"author","name":"Author"},
         "web_url":"https://gitlab.example.org/g/p/-/merge_requests/\(iid)","state":"opened",
         "source_branch":"fix","target_branch":"main","labels":[],"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
        """.utf8))
        return .init(id: UUID(), target: .init(host: host, username: "me", projectID: 1, iid: iid), kind: .review,
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

    @Test func temporarilyMissingManagedCatalogKeepsDurableWorkInReviewing() throws {
        let durable = try intent()
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", intents: [durable])
        #expect(board.reviewed.first?.intents.map(\.id) == [durable.id])
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
