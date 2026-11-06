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
              execution: .init(state: state), workflow: .review)
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

}
