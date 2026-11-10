import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct CommentReviewSnapshotTests {
    @Test func anOlderDraftReadCannotReopenAFinishedCheckpoint() {
        let suite = "CommentReviewGeneration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let target = MRAutomationScope.Target(host: "example.test", username: "me", projectID: 1, iid: 2)
        let version = settings.commentReviewRevision(for: target)
        let draft = GitLabDraftNote(id: 11, authorID: 3, note: "Review", discussionID: nil, position: nil)
        settings.observeCommentReview([draft], for: target, revision: version)
        settings.completeCommentReview(for: target)
        settings.observeCommentReview([draft], for: target, revision: version)
        #expect(settings.pendingCommentReviews.isEmpty)
        settings.observeCommentReview([draft], for: target, revision: settings.commentReviewRevision(for: target))
        #expect(settings.pendingCommentReviews.contains(target))
    }

    @Test func automaticCompletionRequiresActualPublicationOfEveryObservedDraftAcrossRestarts() {
        let suite = "CommentReviewProgress.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let target = MRAutomationScope.Target(host: "example.test", username: "me", projectID: 1, iid: 2)
        let first = GitLabDraftNote(id: 11, authorID: 3, note: "First", discussionID: nil, position: nil)
        let second = GitLabDraftNote(id: 12, authorID: 3, note: "Second", discussionID: nil, position: nil)
        settings.observeCommentReview([first, second], for: target, revision: 0)
        settings.recordAutomaticCommentPublication([second], for: target)
        let reloaded = SettingsManager(defaults: defaults)
        #expect(!reloaded.canAutomaticallyFinishCommentReview(for: target))
        reloaded.recordAutomaticCommentPublication([first], for: target)
        #expect(reloaded.canAutomaticallyFinishCommentReview(for: target))
    }

    @Test func publicationAllowsOnlyItsOwnNewComments() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let original = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"body":"Please fix this","system":false}]}]"#)
        let published = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"body":"Please fix this","system":false},{"id":11,"author":{"id":3},"body":"Fixed","system":false}]}]"#)
        let snapshot = try #require(CommentReviewSnapshot(request: request, discussions: original))
        let draft = GitLabDraftNote(id: 91, authorID: 3, note: "Fixed", discussionID: "thread", position: nil)
        #expect(snapshot.matches(request, discussions: published, publishedDrafts: [draft], userID: 3))
        #expect(!snapshot.matches(request, discussions: published, userID: 3))
        let changed = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"body":"A different concern","system":false},{"id":11,"author":{"id":3},"body":"Fixed","system":false}]}]"#)
        #expect(!snapshot.matches(request, discussions: changed, publishedDrafts: [draft], userID: 3))
    }

    @Test func duplicateBodiesCannotHideMoreDiscussionChangesThanWerePublished() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let original = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"body":"Please fix this","system":false}]}]"#)
        let twoReplies = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"body":"Please fix this","system":false},{"id":11,"author":{"id":3},"body":"Fixed","system":false},{"id":12,"author":{"id":3},"body":"Fixed","system":false}]}]"#)
        let snapshot = try #require(CommentReviewSnapshot(request: request, discussions: original))
        let first = GitLabDraftNote(id: 91, authorID: 3, note: "Fixed", discussionID: "thread", position: nil)
        let second = GitLabDraftNote(id: 92, authorID: 3, note: "Fixed", discussionID: "thread", position: nil)
        #expect(!snapshot.matches(request, discussions: twoReplies, publishedDrafts: [first], userID: 3))
        #expect(snapshot.matches(request, discussions: twoReplies, publishedDrafts: [first, second], userID: 3))
    }

    @Test func aSameHeadContextEditRequiresAnotherCompletionDecision() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1, title: "Original")
        let changed = try MRDependencyPresentationTests().request(2, project: 1, title: "New acceptance criteria")
        let snapshot = try #require(CommentReviewSnapshot(request: request, discussions: []))
        #expect(snapshot.matches(request, discussions: [], userID: 3))
        #expect(!snapshot.matches(changed, discussions: [], userID: 3))
    }

    @Test func missingConversationEvidenceCannotOfferCompletion() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let incomplete = try discussions(#"[{"id":"thread","notes":[{"id":10,"author":{"id":8},"system":false}]}]"#)
        #expect(CommentReviewSnapshot(request: request, discussions: incomplete) == nil)
        #expect(CommentReviewSnapshot(request: request, discussions: nil) == nil)
    }

    private func discussions(_ text: String) throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(text.utf8))
    }
}
