import Foundation
import Testing
@testable import GitLabTodos

@Suite("Re-review assessment")
struct ReReviewAssessmentTests {
    @Test func anIncidentalPrivateQuestionDoesNotRewriteTheOriginalCommentButHoldsReadiness() throws {
        let threads = try discussions()
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"A is corrected."},{"noteID":12,"state":"informational","reason":"Summary."},{"noteID":13,"state":"addressed","reason":"B is corrected."}],"codeReviewRequests":[{"sourceNoteID":10,"sourceQuote":"Fix A","kind":"potentialDefect","summary":"Check a related error path.","question":"Can the related error path leak caller data?"}]}"#.utf8))
        #expect(assessment.notes.first?.state == .addressed)
        #expect(!assessment.hasNoRemainingAuthorWork(in: threads, authorID: 3))
        #expect(try assessment.reviewers(in: threads, authorID: 3) == [9: 13])
        #expect(assessment.readinessBlockers.count == 1)
        #expect(assessment.readinessBlockers.first?.isPrivateCodeQuestion == true)
        #expect(assessment.readinessBlockers.first?.summary == "Check a related error path.")
    }

    @Test(arguments: ["wrongNote", "wrongQuote", "blankQuestion", "wrongKindState", "duplicate"])
    func technicalQuestionsCannotInventTheirSourceOrScope(_ scenario: String) throws {
        // given
        let id = scenario == "wrongNote" ? 11 : 10
        let quote = scenario == "wrongQuote" ? "A request no reviewer made" : "Fix A"
        let question = scenario == "blankQuestion" ? " " : "Does the related context identify the caller?"
        let kind = scenario == "wrongKindState" ? "feedbackVerification" : "potentialDefect"
        let request = #"{"sourceNoteID":\#(id),"sourceQuote":"\#(quote)","kind":"\#(kind)","summary":"Check the related path.","question":"\#(question)"}"#
        let extra = scenario == "duplicate" ? "," + request : ""
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"A is corrected."},{"noteID":12,"state":"informational","reason":"Summary."},{"noteID":13,"state":"addressed","reason":"B is corrected."}],"codeReviewRequests":[\#(request)\#(extra)]}"#.utf8))
        // when + then
        #expect(throws: ReReviewAssessment.ValidationError.self) { try assessment.reviewers(in: discussions(), authorID: 3) }
    }

    @Test func verifiedReplyInAnotherThreadSatisfiesOnlyItsAssessedConcern() throws {
        // given
        let threads = try discussions()
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"Verified correction and reply."},{"noteID":12,"state":"informational","reason":"Summary."},{"noteID":13,"state":"addressed","reason":"The same correction is explained in published reply 14.","publishedReplyNoteID":14}]}"#.utf8))
        let replyThread = try JSONDecoder().decode(GitLabMergeRequestDiscussion.self, from: Data(#"{"notes":[{"id":14,"author":{"id":3},"system":false,"body":"The shared correction also addresses the same concern in note 13."}]}"#.utf8))
        // when
        let current = threads + [replyThread]
        // then
        #expect(try assessment.reviewers(in: current, authorID: 3) == [7: 10, 9: 13])
        #expect(assessment.missingPublishedReplyNoteIDs(in: current, authorID: 3).isEmpty)
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [13])
    }

    @Test(arguments: ["missing", "reviewer", "system", "blank", "earlier", "duplicate", "wrongState"])
    func invalidCrossThreadReplyEvidenceIsRejected(_ scenario: String) throws {
        // given
        let author = scenario == "reviewer" ? 7 : 3
        let id = scenario == "earlier" ? 9 : 14
        let body = scenario == "blank" ? " " : "Verified shared correction."
        let reply = #"{"id":\#(id),"author":{"id":\#(author)},"system":\#(scenario == "system"),"body":"\#(body)"}"#
        let extra = scenario == "duplicate" ? "," + reply : ""
        let appended = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data((scenario == "missing" ? "[]" : #"[{"notes":[\#(reply)\#(extra)]}]"#).utf8))
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"Verified."},{"noteID":12,"state":"informational","reason":"Summary."},{"noteID":13,"state":"\#(scenario == "wrongState" ? "blocking" : "addressed")","reason":"Claimed shared reply.","publishedReplyNoteID":\#(id)}]}"#.utf8))
        let current = try discussions() + appended
        // when + then
        #expect(throws: ReReviewAssessment.ValidationError.self) {
            try assessment.reviewers(in: current, authorID: 3)
        }
        #expect(assessment.missingPublishedReplyNoteIDs(in: current, authorID: 3).contains(13) == (scenario != "wrongState"))
    }

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

    @Test func legacyUnconfirmedReviewRequestsCannotBeAutomaticallyReplayed() throws {
        let receipt = try JSONDecoder().decode(ReReviewReceipt.self, from: Data(#"{"noteID":40,"unconfirmed":true}"#.utf8))
        #expect(receipt.covers(noteID: 40, headSHA: String(repeating: "a", count: 40)))
    }

    @Test func unansweredResolvableFeedbackRemainsAManualBlockerButGeneralCommentsDoNot() throws {
        let threads = try discussions()
        #expect(ReReviewFeedback(discussions: Array(threads.prefix(2)), authorID: 3).hasUnansweredFeedback == false)
        #expect(ReReviewFeedback(discussions: threads, authorID: 3).hasUnansweredFeedback)
    }
}
