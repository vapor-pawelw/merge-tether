import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReviewingContextTests {
    private func request() throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice Author"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
    private func item() throws -> MergeRequestAttentionMonitor.Item {
        let request = try request()
        return .init(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL, mergeRequest: request)
    }
    private func note(_ id: Int?, user: Int?, resolved: Bool = false, system: Bool = false) -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: user.map { .init(id: $0, username: "user\($0)", name: nil) },
              system: system, resolvable: true, resolved: resolved, resolvedBy: nil, body: "Comment")
    }
    private func row(_ item: MergeRequestAttentionMonitor.Item, job: AssistantAutomationRunner.Handoff? = nil,
                     intents: [MRTodoIntent] = []) -> MergeRequestBoardSnapshot.Row {
        .init(item: item, latestJob: job, intents: intents)
    }
    private func reviewJob(_ state: AssistantJobExecution.State) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
              title: "Review", prompt: "", createdAt: Date(), allowsPush: false,
              execution: .init(state: state), workflow: .review, expectedHeadSHA: "abc")
    }

    @Test func unknownActivityDoesNotInventAFirstReviewOrARecentlyAddedReceipt() throws {
        let item = try item()
        let context = ReviewingContext(row: row(item))
        #expect(context.author?.username == "alice")
        #expect(context.presence == .tracked)
        #expect(context.status == .activityUnknown)
    }

    @Test func sourceRequestExplainsPresenceWithoutConfusingItsActorWithTheMRAuthor() throws {
        let item = try item()
        let todo = try GlabService.decodeTodos(Data(#"[{"id":5,"action_name":"review_requested","target_type":"MergeRequest","target_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","body":"Review","state":"pending","created_at":"2026-01-01T00:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"request-bot","name":"Request Bot"},"target":{"id":10,"iid":2,"title":"Example","state":"opened","draft":false}}]"#.utf8))[0]
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .review, state: .completed, todoIDs: [5], noteIDs: [], sourceEvents: [], request: try request(),
            headSHA: "abc", updatedAt: Date(), sourceTodo: todo)
        let context = ReviewingContext(row: row(item, intents: [intent]))
        #expect(context.author?.username == "alice")
        #expect(context.presence == .reviewRequested("request-bot"))
    }

    @Test func authorRepliesCountOnlyAfterOurLastCommentInTheSameThread() throws {
        let discussions: [GitLabMergeRequestDiscussion] = [
            .init(id: "our-thread", notes: [note(10, user: 3), note(11, user: 7)]),
            .init(id: "we-answered", notes: [note(20, user: 3), note(21, user: 7), note(22, user: 3)]),
            .init(id: "others-thread", notes: [note(30, user: 9), note(31, user: 7)]),
            .init(id: "system", notes: [note(40, user: 3), note(41, user: 7, system: true)])
        ]
        let activity = ReviewingActivity(discussions: discussions, reviewerID: 3, authorID: 7)
        #expect(activity.publishedCommentCount == 4)
        #expect(activity.openThreadCount == 3)
        #expect(activity.authorReplyCount == 1)
        #expect(activity.otherReplyCount == 0)
        #expect(activity.isComplete)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .authorReplied(1))
    }

    @Test func anotherReviewersReplyDoesNotBecomeAnAuthorReply() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [note(10, user: 3), note(11, user: 9)])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0 && activity.otherReplyCount == 1)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .otherReplied(1))
    }

    @Test func resolvedOwnCommentsAreStillRecordedWithoutAnOpenThread() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [note(10, user: 3, resolved: true)])], reviewerID: 3, authorID: 7)
        #expect(activity.publishedCommentCount == 1 && activity.openThreadCount == 0)
        var item = try item(); item.reviewingActivity = activity; item.humanActionRequired = false
        let original = row(item)
        #expect(ReviewingContext(row: original).status == .commented(1))
        #expect(!original.needsAttention)
    }

    @Test func malformedEvidenceDoesNotClaimWeHaveNeverCommented() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "incomplete", notes: [note(nil, user: nil)])], reviewerID: 3, authorID: 7)
        #expect(!activity.isComplete)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .activityUnknown)
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        #expect(ReviewingContext(row: row(item)).status == .noPublishedComments)
    }

    @Test func pendingDraftsAndActiveRunsExplainCurrentProgress() throws {
        var item = try item(); item.draftCount = 2
        #expect(ReviewingContext(row: row(item)).status == .drafts(2))
        #expect(ReviewingContext(row: row(item, job: reviewJob(.running))).status == .running)
        item.draftCount = 0
        #expect(ReviewingContext(row: row(item, job: reviewJob(.succeeded))).status == .reviewCompleted)
    }

    @Test func incompleteThreadCannotInventAnUnansweredReply() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [
            note(10, user: 3), note(11, user: 7), note(nil, user: 3)
        ])], reviewerID: 3, authorID: 7)
        #expect(!activity.isComplete)
        #expect(activity.authorReplyCount == 0 && activity.otherReplyCount == 0)
        #expect(activity.publishedCommentCount == 1)
    }

    @Test func requestIdentityMustMatchBeforeShowingItsAuthor() throws {
        let request = try request()
        let wrongItem = MergeRequestAttentionMonitor.Item(id: .init(projectID: 9, iid: 2),
            title: request.title, url: request.webURL, mergeRequest: request)
        #expect(ReviewingContext(row: row(wrongItem)).author == nil)
    }

    @Test func nonReviewJobDoesNotClaimAReviewWasCompleted() throws {
        var job = reviewJob(.succeeded)
        job.workflow = nil
        #expect(ReviewingContext(row: row(try item(), job: job)).status == .activityUnknown)
    }

    @Test func replyOrderUsesNoteIdentityRatherThanResponseArrayOrder() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [
            note(30, user: 3, resolved: true), note(20, user: 7), note(10, user: 3, resolved: true)
        ])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0)
        #expect(activity.publishedCommentCount == 2)
    }

    @Test func resolvedHistoricalAuthorRepliesDoNotLookLikePendingReviewWork() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "closed", notes: [
            note(10, user: 3, resolved: true), note(11, user: 7, resolved: true)
        ])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0)
        var item = try item(); item.reviewingActivity = activity; item.humanActionRequired = false
        let snapshot = row(item)
        let context = ReviewingContext(row: snapshot)
        #expect(context.status == .commented(1))
        #expect(context.nextStep == .monitoring)
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
        #expect(!snapshot.needsAttention)
    }

    @Test func untouchedOtherReviewersThreadsAreNotOurPendingAuthorReplies() throws {
        let activity = ReviewingActivity(discussions: [
            .init(id: "ours", notes: [note(10, user: 3, resolved: true), note(11, user: 7, resolved: true)]),
            .init(id: "other", notes: [note(20, user: 9)])
        ], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0 && activity.openThreadCount == 0)
        #expect(activity.otherOpenThreadCount == 1)
    }

    @Test func aKnownEmptyReviewHasAnExplicitManualAction() throws {
        var item = try item()
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        let context = ReviewingContext(row: row(item))
        #expect(context.nextStep == .runReview)
        #expect(String(localized: try #require(context.actionLabel)) == "Run review")
    }

    @Test(arguments: [MergeWorkflowActivityState.queued, .running, .waitingForAssistant])
    func queuedAutomaticReviewDoesNotAskForASecondManualRun(_ state: MergeWorkflowActivityState) throws {
        var item = try item()
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        item.humanActionRequired = false
        let context = ReviewingContext(row: row(item), workflowState: state)
        #expect(context.nextStep == .automaticReview)
        #expect(context.actionLabel == nil)
    }

    @Test func automaticallyHandledDraftsDoNotAskForManualReviewComments() throws {
        var item = try item(); item.draftCount = 2; item.humanActionRequired = false
        let context = ReviewingContext(row: row(item))
        #expect(context.nextStep == .automaticReview)
        #expect(context.actionLabel == nil)
    }

    @Test func staleSucceededJobIsNotProofOfAReviewOfTheCurrentHead() throws {
        var job = reviewJob(.succeeded); job.expectedHeadSHA = "old-head"
        let context = ReviewingContext(row: row(try item(), job: job))
        #expect(context.status != .reviewCompleted)
    }

    @Test func actualVerificationShowsProgressWithoutAskingForManualReview() throws {
        var item = try item(); item.reReviewReadiness = .checking
        let context = ReviewingContext(row: row(item))
        #expect(context.nextStep == .verifying)
        #expect(context.actionLabel == nil)
    }

    @Test func workflowProgressIgnoresOtherWorkflowsAndOlderHeads() throws {
        func entry(_ state: MergeWorkflowActivityState, head: String, kind: MergeWorkflowTrigger,
                   createdAt: Double) throws -> MergeWorkflowActivityEntry {
            var snapshot = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
            snapshot["sha"] = head
            let value: [String: Any] = [
                "id": "event-\(createdAt)", "createdAt": createdAt, "host": "gitlab.example.test",
                "user": ["id": 3, "username": "me"], "state": state.rawValue,
                "event": ["kind": kind.rawValue, "mergeRequest": snapshot, "identity": "event-\(createdAt)", "context": "Review update", "isInfrastructureFailure": false, "noteIDs": []]
            ]
            return try JSONDecoder().decode(MergeWorkflowActivityEntry.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let current = try entry(.queued, head: "abc", kind: .reviewUpdate, createdAt: 1)
        let obsolete = try entry(.failed, head: "old", kind: .reviewUpdate, createdAt: 9)
        let unrelated = try entry(.running, head: "abc", kind: .newDiscussion, createdAt: 10)
        let snapshot = row(try item())
        #expect(ReviewingContext.workflowState(for: snapshot, entries: [obsolete, unrelated, current]) == .queued)
        #expect(ReviewingContext.workflowState(for: snapshot, entries: [obsolete, unrelated]) == nil)
    }

    @Test func missingCurrentReviewEvidenceExposesAReviewActionUnlessAlreadyQueued() throws {
        var item = try item(); item.reviewingProgress = .needsReview
        let snapshot = row(item)
        #expect(ReviewingContext(row: snapshot).nextStep == .runReview)
        #expect(ReviewingContext(row: snapshot, workflowState: .queued).nextStep == .automaticReview)
    }

    @Test func waitingForOtherReviewThreadsIsReadOnlyAndDoesNotInventApproval() throws {
        var item = try item(); item.reviewingProgress = .waitingForOtherDiscussions
        item.humanActionRequired = false
        let snapshot = row(item)
        let context = ReviewingContext(row: snapshot)
        #expect(context.nextStep == .monitoring)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Waiting for other review threads to be resolved.")
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
        #expect(!snapshot.needsAttention && !item.canApprove && !item.autoApproveReady)
    }

    @Test func freshReviewEvidenceSupersedesAnOlderFailedWorkflow() throws {
        var item = try item(); item.reviewingProgress = .current
        item.humanActionRequired = false
        let context = ReviewingContext(row: row(item), workflowState: .failed, assistantReady: false)
        #expect(context.status == .reviewCompleted)
        #expect(context.nextStep == .monitoring)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Watching for updates.")
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
    }

    @Test func freshWaitingForOtherThreadsSupersedesAnOlderFailedWorkflow() throws {
        var item = try item(); item.reviewingProgress = .waitingForOtherDiscussions
        item.humanActionRequired = false
        let context = ReviewingContext(row: row(item), workflowState: .failed, assistantReady: false)
        #expect(context.status == .waitingForOtherDiscussions)
        #expect(context.nextStep == .monitoring)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Waiting for other review threads to be resolved.")
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
    }

    @Test func missingCLICannotPretendAQueuedReviewIsBeingHandled() throws {
        let context = ReviewingContext(row: row(try item()), workflowState: .waitingForAssistant,
            assistantReady: false, assistantChecking: false)
        #expect(context.nextStep == .setupAgent)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: try #require(context.actionLabel)) == "Open settings")
    }

    @Test func aPendingDependencyCheckKeepsActualQueuedWorkNeutral() throws {
        let context = ReviewingContext(row: row(try item()), workflowState: .queued,
            assistantReady: false, assistantChecking: true)
        #expect(context.nextStep == .automaticReview && context.isAutomaticProcessing)
        #expect(context.actionLabel == nil)
    }

}
