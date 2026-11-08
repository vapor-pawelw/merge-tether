import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor
struct ConfirmedAttentionSnapshotTests {
    private let id = "host/me/mr/1/2"
    private func candidate(_ attention: Bool, working: Bool = false) -> UserAttentionSnapshot.Candidate {
        .init(id: id, title: "Example", actions: attention ? [.init(reason: .drafts, token: "same-reply")] : [], working: working)
    }

    @Test func refreshKeepsTheLastConfirmedAttentionAndNotificationIdentity() {
        var cache = ConfirmedAttentionSnapshot()
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        let before = cache.snapshot
        for _ in 0..<3 {
            cache.update(.init(account: "me", candidates: [candidate(false, working: true)], checkingIDs: [id]))
            #expect(cache.snapshot == before)
        }
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        #expect(cache.snapshot == before)
        cache.update(.init(account: "me", candidates: [candidate(false)]))
        #expect(!cache.snapshot.hasAttention)
    }

    @Test func aNewAttentionReasonMustWaitForTheCheckToFinish() {
        var cache = ConfirmedAttentionSnapshot()
        cache.update(.init(account: "me", candidates: [candidate(false)]))
        cache.update(.init(account: "me", candidates: [candidate(true)], checkingIDs: [id]))
        #expect(!cache.snapshot.hasAttention)
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        #expect(cache.snapshot.hasAttention)
    }

    @Test func firstLoadAndAnAccountSwitchCannotReuseUnconfirmedAttention() {
        var cache = ConfirmedAttentionSnapshot()
        cache.update(.init(account: "me", candidates: [candidate(true)], checkingIDs: [id]))
        #expect(!cache.snapshot.hasAttention)
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        cache.update(.init(account: "other", candidates: [candidate(true)], checkingIDs: [id]))
        #expect(!cache.snapshot.hasAttention)
        cache.update(.init(account: nil))
        #expect(!cache.snapshot.hasAttention)
    }

    @Test func realExecutionAndExplicitRemovalStillChangeAttentionImmediately() {
        var cache = ConfirmedAttentionSnapshot()
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        cache.update(.init(account: "me", candidates: [candidate(true, working: true)]))
        #expect(!cache.snapshot.hasAttention)
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        cache.update(.init(account: "me"))
        #expect(!cache.snapshot.hasAttention)
    }
    @Test func cardsAndPhoneKeepTheConfirmedExplanationWhileShowingReadProgress() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://host/group/repo/-/merge_requests/2")!)
        item.draftCount = 1
        item.humanActionRequired = true
        item.draftProofRecoveryFailure = "Missing test evidence"
        let previous = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let action = try #require(MRHumanAction(row: previous, assistantReady: true))
        var cache = ConfirmedAttentionSnapshot()
        cache.update(.init(account: "me", candidates: [candidate(true)], humanActions: [id: action]))
        item.draftProofRecoveryFailure = nil
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "notes", phase: .checking)
        let checking = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        cache.update(.init(account: "me", candidates: [candidate(false, working: true)], checkingIDs: [id]))
        let model = MRCardPresentation(row: checking, reviewingContext: ReviewingContext(row: checking),
            allowsRemoval: false, assistantReady: true, preservedHumanAction: cache.humanActions[id], isRefreshingAttention: true)
        #expect(model.working && model.humanAction != nil)
        #expect(model.message == action.explanation)
        #expect(model.status == "Checking feedback")
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me"), model: model)
        #expect(phone.needsAttention == true)
        #expect(phone.detail == action.explanation)
        #expect(phone.presentation?.working == true && phone.actions.isEmpty)
    }

    @Test(arguments: [false, true])
    func cachedReadChecksStayQuietWhilePreservingAttentionAndRemoteActionFences(_ visible: Bool) throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://host/group/repo/-/merge_requests/2")!)
        item.draftCount = 1
        item.humanActionRequired = true
        let before = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let action = try #require(MRHumanAction(row: before, assistantReady: true))
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "notes", phase: .checking)
        let checking = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: checking, reviewingContext: ReviewingContext(row: checking),
            allowsRemoval: false, assistantReady: true, preservedHumanAction: action, isRefreshingAttention: true,
            showsReadProgress: visible)
        #expect(model.working == visible)
        #expect(model.status == (visible ? "Checking feedback" : nil))
        #expect(model.busy && model.actionsBlocked)
        #expect(model.message == action.explanation && model.humanAction != nil)
        var original = RemoteBoardAdapter.card(item, account: "me")
        original.actions = [.init(id: "publish", kind: .publish, token: "current-token")]
        let phone = RemoteBoardAdapter.presentation(original, model: model)
        #expect(phone.needsAttention == true && phone.detail == action.explanation)
        #expect(phone.presentation?.working == visible && phone.actions.isEmpty)
    }

    @Test func aRecheckCannotMoveACardOutOfTheAttentionGroupBeforeItsResult() {
        var cache = ConfirmedAttentionSnapshot()
        let a = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "A",
            url: URL(string: "https://host/group/repo/-/merge_requests/2")!)
        let b = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 3), title: "B",
            url: URL(string: "https://host/group/repo/-/merge_requests/3")!)
        func order() -> [Int] {
            MergeRequestBoardSnapshot(own: [b, a], reviewed: [], todos: [], attention: [], handoffs: [],
                host: "host", username: "me", humanAttention: cache.snapshot).own.map { $0.id.iid }
        }
        cache.update(.init(account: "me", candidates: [candidate(true)]))
        #expect(order() == [2, 3])
        cache.update(.init(account: "me", candidates: [candidate(false, working: true)], checkingIDs: [id]))
        #expect(order() == [2, 3])
        cache.update(.init(account: "me", candidates: [candidate(false)]))
        #expect(order() == [3, 2])
    }

}
