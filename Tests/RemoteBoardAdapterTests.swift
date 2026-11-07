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
        #expect((card["actions"] as? [Any])?.isEmpty == true)
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
        #expect(card.presentation?.status == nil)
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

}
