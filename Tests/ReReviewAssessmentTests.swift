import Foundation
import Testing
@testable import GitLabTodos

@Suite("Re-review assessment")
struct ReReviewAssessmentTests {
    private func discussions() throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
            [{"notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":false,"body":"Fix A"},
                       {"id":11,"author":{"id":3},"system":false,"body":"Fixed A"}]},
             {"notes":[{"id":12,"author":{"id":8},"system":false,"body":"No findings"}]},
             {"notes":[{"id":13,"author":{"id":9},"system":false,"resolvable":true,"resolved":false,"body":"Fix B"}]}]
            """.utf8))
    }

    @Test func informationalCommentsAndAnotherReviewersBlockerDoNotBlockAddressedReviewer() throws {
        let result = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "Current diff fixes A"),
            .init(noteID: 12, state: .informational, reason: "Review summary"),
            .init(noteID: 13, state: .blocking, reason: "B still needs work")])
        #expect(try result.reviewers(in: discussions(), authorID: 3) == [7: 10])
    }

    @Test func incompleteDuplicateOrUnknownNoteCoverageIsRejected() throws {
        let note = ReReviewAssessment.Note(noteID: 10, state: .addressed, reason: "Fixed")
        for notes in [[note], [note, note], [note, .init(noteID: 999, state: .informational, reason: "Unknown")]] {
            #expect(throws: ReReviewAssessment.ValidationError.self) {
                try ReReviewAssessment(notes: notes).reviewers(in: discussions(), authorID: 3)
            }
        }
    }

    @Test func unansweredResolvableFeedbackRemainsAManualBlockerButGeneralCommentsDoNot() throws {
        let threads = try discussions()
        #expect(ReReviewFeedback(discussions: Array(threads.prefix(2)), authorID: 3).hasUnansweredFeedback == false)
        #expect(ReReviewFeedback(discussions: threads, authorID: 3).hasUnansweredFeedback)
    }
}
