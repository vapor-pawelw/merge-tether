import Foundation
import Observation
import os
import Testing
@testable import GitLabTodos

@MainActor
struct BoardAttentionPresenterTests {
    @Test(arguments: ["reply", "question"], ["current", "head", "body", "discussion", "catalog", "account"])
    func semanticOnlyAttentionRequiresTheCurrentAccountAndFeedbackContext(_ kind: String, _ context: String) throws {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","web_url":"https://host/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
        item.observedDiscussionFingerprint = "conversation"
        item.authorFeedbackStatus = .init(head: context == "head" ? "old" : "head",
            fingerprint: context == "discussion" ? "old" : "conversation",
            semanticContextFingerprint: context == "body" ? "old" : request.semanticContextFingerprint,
            phase: .complete,
            codeReviewRequests: kind == "question" ? [.init(sourceNoteID: 20, sourceQuote: "Cover retries",
                kind: .potentialDefect, summary: "Check retry identity", question: "Does retrying preserve identity?")] : [],
            replyNoteIDs: kind == "reply" ? [20] : [])
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [],
            evidenceMatchesCatalogContext: context != "catalog")
        let result = BoardAttentionPresenter.project(.init(account: "host/me/1", host: "host",
            username: context == "account" ? "other" : "me", rows: [
                .init(row: row, item: item, confirmationState: nil, busy: false, automaticDraftIDs: [],
                    checking: false, automaticIntentIDs: [])
            ], proposals: [], otherTodos: [], inboxLoading: false, assessingMentionNoteIDs: [],
            assistantReady: true, assistantPreparing: true))
        #expect(UserAttentionSnapshot(candidates: result.candidates).hasAttention == (context == "current"))
    }

    @Test func confirmedAttentionIsObservableAndCannotCrossAnAccountEpoch() {
        let presenter = BoardAttentionPresenter()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = presenter.userAttention(account: "host/me/1") } onChange: {
            changed.withLock { $0 = true }
        }
        presenter.updateAttention(.init(account: "host/me/1", candidates: [
            .init(id: "mr", title: "Example", actions: [.init(reason: .drafts, token: "draft")])
        ]))
        #expect(changed.withLock { $0 })
        let confirmed = presenter.userAttention(account: "host/me/1")
        presenter.updateAttention(.init(account: "host/me/1", candidates: [
            .init(id: "mr", title: "Example", actions: [], working: true)
        ], checkingIDs: ["mr"]))
        #expect(presenter.userAttention(account: "host/me/1") == confirmed)
        #expect(!presenter.userAttention(account: "host/me/2").hasAttention)
        #expect(!presenter.userAttention(account: nil).hasAttention)
        presenter.updateAttention(.init(account: "host/me/2"))
        #expect(!presenter.userAttention(account: "host/me/1").hasAttention)
    }

    @Test func unchangedActivityDoesNotInvalidateObservationOrRestartTheStage() throws {
        let target = MRAutomationScope.Target(host: "host", username: "me", projectID: 1, iid: 2)
        let presenter = BoardAttentionPresenter()
        let activity = MRActivity(status: "Checking replies", jobID: UUID())
        presenter.updateActivities([target: activity], now: Date(timeIntervalSince1970: 100))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = presenter.activityStartedAt(target: target, activity: activity) } onChange: {
            changed.withLock { $0 = true }
        }
        presenter.updateActivities([target: activity], now: Date(timeIntervalSince1970: 200))
        #expect(!changed.withLock { $0 })
        #expect(presenter.activityStartedAt(target: target, activity: activity) == Date(timeIntervalSince1970: 100))
        let next = MRActivity(status: "Checking replies", jobID: UUID())
        presenter.updateActivities([target: next], now: Date(timeIntervalSince1970: 300))
        #expect(changed.withLock { $0 })
        #expect(presenter.activityStartedAt(target: target, activity: next) == Date(timeIntervalSince1970: 300))
        #expect(presenter.activityStartedAt(target: nil, activity: next) == nil)
    }

    @Test func projectionKeepsDraftContentIdentityAndAlreadyDecidedAutomaticOwnership() throws {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://host/group/repo/-/merge_requests/2")!)
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"author","name":"Author"},"title":"Example","web_url":"https://host/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.draftCount = 1
        item.drafts = [.init(id: 11, authorID: 7, note: "First reply", discussionID: "thread", position: nil)]
        func input(automatic: Set<Int> = [], checking: Bool = false, busy: Bool = false) -> BoardAttentionPresenter.ProjectionInput {
            .init(account: "host/me/1", host: "host", username: "me", rows: [
                .init(row: .init(item: item, latestJob: nil, intents: []), item: item,
                    confirmationState: nil, busy: busy, automaticDraftIDs: automatic,
                    checking: checking, automaticIntentIDs: [])
            ], proposals: [], otherTodos: [], inboxLoading: false, assessingMentionNoteIDs: [],
                assistantReady: true, assistantPreparing: true)
        }
        let presenter = BoardAttentionPresenter()
        presenter.updateAttention(BoardAttentionPresenter.project(input()))
        let confirmed = presenter.userAttention(account: "host/me/1")
        #expect(confirmed.hasAttention)
        #expect(!UserAttentionSnapshot(candidates: BoardAttentionPresenter.project(input(automatic: [11])).candidates).hasAttention)
        #expect(!UserAttentionSnapshot(candidates: BoardAttentionPresenter.project(input(busy: true)).candidates).hasAttention)
        item.drafts = [.init(id: 11, authorID: 7, note: "Edited reply", discussionID: "thread", position: nil)]
        presenter.updateAttention(BoardAttentionPresenter.project(input(checking: true)))
        #expect(presenter.userAttention(account: "host/me/1") == confirmed)
        presenter.updateAttention(BoardAttentionPresenter.project(input()))
        #expect(presenter.userAttention(account: "host/me/1").items.first?.signature != confirmed.items.first?.signature)
    }

    @Test func executionOwnsProgressWhileReadFailureKeepsTheConfirmedProjection() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://host/group/repo/-/merge_requests/2")!)
        item.draftProofRecoveryReadFailure = true
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let refreshing = BoardAttentionPresenter.RefreshState(catalogLoading: true, catalogReadFailed: true)
        #expect(BoardAttentionPresenter.attentionRefreshFailed(row: .init(row: row), refresh: refreshing))
        #expect(BoardAttentionPresenter.isRecheckingAttention(row: .init(row: row), refresh: refreshing))
        let executing = BoardAttentionPresenter.RowState(row: row, confirmationBusy: true)
        #expect(!BoardAttentionPresenter.attentionRefreshFailed(row: executing, refresh: refreshing))
        #expect(!BoardAttentionPresenter.isRecheckingAttention(row: executing, refresh: refreshing))
    }

}
