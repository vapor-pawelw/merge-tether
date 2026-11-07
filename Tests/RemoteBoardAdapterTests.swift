import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteBoardAdapterTests {
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

}
