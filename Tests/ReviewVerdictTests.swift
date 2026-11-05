import Foundation
import Testing
@testable import GitLabTodos

@Suite struct ReviewVerdictTests {
    private let head = "0123456789012345678901234567890123456789"
    private let reviewer = 3

    private func discussions(_ notes: [(id: Int, author: Int, body: String)]) throws -> [GitLabMergeRequestDiscussion] {
        let json = notes.map { ["notes": [["id": $0.id, "author": ["id": $0.author], "system": false, "body": $0.body]]] }
        return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    private func verdict(for discussions: [GitLabMergeRequestDiscussion]) -> ReviewVerdict {
        ReviewVerdict(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2, headSHA: head,
                      verdict: .noObjections, discussionFingerprint: ReviewVerdict.fingerprint(discussions))
    }

    @Test func publishingTheReviewersOwnDraftsKeepsTheVerdict() throws {
        let recorded = verdict(for: try discussions([(10, 7, "Please rename this")]))
        let later = try discussions([(10, 7, "Please rename this"), (20, reviewer, "Thanks, looks good"),
                                     (21, reviewer, "Resolved by the rename")])
        let seen: Set = [AICommentAssessmentStore.digest("Thanks, looks good"), AICommentAssessmentStore.digest("Resolved by the rename")]

        #expect(!recorded.approves(head: head, discussions: later))
        #expect(recorded.approves(head: head, discussions: later, reviewerID: reviewer, publishedDrafts: seen))
    }

    @Test func newCommentsFromOthersStillInvalidateTheVerdict() throws {
        let recorded = verdict(for: try discussions([(10, 7, "Please rename this")]))
        let later = try discussions([(10, 7, "Please rename this"), (20, reviewer, "Thanks"), (22, 8, "One more thing")])
        #expect(!recorded.approves(head: head, discussions: later, reviewerID: reviewer,
                                   publishedDrafts: [AICommentAssessmentStore.digest("Thanks")]))
    }

    @Test func ownCommentsThatWereNeverDraftsInvalidateTheVerdict() throws {
        let recorded = verdict(for: try discussions([(10, 7, "Please rename this")]))
        let later = try discussions([(10, 7, "Please rename this"), (20, reviewer, "Actually, don't merge yet")])
        #expect(!recorded.approves(head: head, discussions: later, reviewerID: reviewer,
                                   publishedDrafts: [AICommentAssessmentStore.digest("Thanks")]))
    }

    @Test func seenDraftsArePersistedPerMergeRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = try JSONDecoder().decode(GitLabDraftNote.self, from: Data(#"{"id":5,"author_id":3,"note":"Thanks"}"#.utf8))
        ReviewVerdictStore.rememberDrafts([draft], host: "gitlab.example.org", projectID: 1, iid: 2, in: directory)
        #expect(ReviewVerdictStore.seenDrafts(host: "gitlab.example.org", projectID: 1, iid: 2, in: directory)
                == [AICommentAssessmentStore.digest("Thanks")])
        #expect(ReviewVerdictStore.seenDrafts(host: "gitlab.example.org", projectID: 1, iid: 3, in: directory).isEmpty)
        // The verdict itself is untouched by the draft list next to it.
        #expect(ReviewVerdictStore.verdict(host: "gitlab.example.org", projectID: 1, iid: 2, in: directory) == nil)
    }
}
