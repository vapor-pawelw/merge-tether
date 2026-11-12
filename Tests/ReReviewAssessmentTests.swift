import Foundation
import Testing
@testable import GitLabTodos

@Suite("Re-review assessment")
struct ReReviewAssessmentTests {
    @Test func coveredSummaryValidationUsesTheSamePersonalNoReplyPreferenceAsReadiness() throws {
        let threads = try summaryDiscussions(withReply: false)
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The correction is verified."),
            .init(noteID: 20, state: .addressed, reason: "This summary repeats the corrected finding.",
                informationalPurpose: .reviewSummary, reviewSummaryCoverage: .init(referencedNoteIDs: [10], noIndependentExpectation: true))])
        let normalized = try assessment.normalizingCoveredReviewSummaries(in: threads, authorID: 3, excludedReplyAuthorIDs: [7])
        #expect(normalized.notes.last?.state == .informational)
        #expect(normalized.hasNoRemainingAuthorWork(in: threads, authorID: 3, excludedReplyAuthorIDs: [7]))
        #expect(normalized.missingPublishedReplyNoteIDs(in: threads, authorID: 3, excludedReplyAuthorIDs: [7]).isEmpty)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking])
    func aPersonalNoReplyDecisionIsConsistentAcrossReadinessWithoutWaivingCode(_ state: ReReviewAssessment.Note.State) throws {
        let threads = [GitLabMergeRequestDiscussion(id: "thread", notes: [
            .init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: "Fix overflow")])]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10, state: state, reason: "Overflow correction assessed.")])
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3, excludedReplyAuthorIDs: [7]).isEmpty)
        #expect(assessment.hasNoRemainingAuthorWork(in: threads, authorID: 3, excludedReplyAuthorIDs: [7]) == (state == .addressed))
        let findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: 3,
            approvedReviewerIDs: [], excludedReplyAuthorIDs: [7])
        #expect(findings.first?.state == (state == .blocking ? .needsChanges : .waitingAcceptance))
        #expect(findings.allSatisfy { !$0.canResolve })
    }

    @Test(arguments: ["pure", "mixed", "unknown"])
    func anOpenResolvableOptOutHasNoReviewerWaitWithoutWaivingOtherConcerns(_ scenario: String) throws {
        let quote = "Do not invite me to reviews"
        let threads = [GitLabMergeRequestDiscussion(id: "thread", notes: [
            .init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: quote + (scenario == "mixed" ? "; fix overflow" : ""))])]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10, state: scenario == "mixed" ? .blocking : .informational,
            reason: "Current review participation and technical obligations assessed.", informationalAcknowledgementSafe: false,
            informationalPurpose: .other, reviewerOptOut: scenario == "unknown" ? nil : .init(sourceQuote: quote))])
        let findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: 3, approvedReviewerIDs: [])
        #expect(findings.isEmpty == (scenario == "pure"))
        #expect(findings.allSatisfy { !$0.canResolve })
        if scenario == "mixed" { #expect(findings.first?.state == .needsChanges) }
        if scenario == "unknown" { #expect(findings.first?.state == .waitingAcceptance) }
        #expect(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: threads, assessment: assessment, authorID: 3).isEmpty)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.informational, .addressed, .blocking])
    func aSourceBoundOptOutNeverCreatesAReplyOrReviewInvitationButPreservesTechnicalWork(_ state: ReReviewAssessment.Note.State) throws {
        let quote = "Do not invite me to reviews."
        let threads = [GitLabMergeRequestDiscussion(id: "opt-out", notes: [
            .init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                resolvable: false, resolved: false, resolvedBy: nil, body: quote + (state == .blocking ? " Also fix overflow." : ""))]),
            .init(id: "technical", notes: [.init(id: 20, author: .init(id: 8, username: "other", name: "Other"),
                system: false, resolvable: false, resolved: false, resolvedBy: nil, body: "Fix retry handling")])]
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: state, reason: "The participant declined reviews.",
                informationalAcknowledgementSafe: false, informationalPurpose: .other,
                reviewerOptOut: .init(sourceQuote: quote)),
            .init(noteID: 20, state: .addressed, reason: "Retry handling was fixed.")])
        #expect(try assessment.reviewers(in: threads, authorID: 3) == [8: 20])
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [20])
        #expect(assessment.pureReviewerOptOutNoteIDs(in: threads, authorID: 3) == (state == .informational ? [10] : []))
        #expect(assessment.readinessBlockers.contains { $0.noteID == 10 } == (state == .blocking))
    }

    @Test func anOptOutRequiresTheExactCurrentSourceAndCannotGrantAcknowledgementOrAcceptance() throws {
        let source = GitLabMergeRequestDiscussion.Note(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"),
            system: false, resolvable: false, resolved: false, resolvedBy: nil, body: "Fix overflow")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10, state: .informational, reason: "Claimed opt-out",
            informationalAcknowledgementSafe: false, informationalPurpose: .other,
            reviewerOptOut: .init(sourceQuote: "Do not invite me"))])
        #expect(throws: ReReviewAssessment.ValidationError.self) {
            try assessment.reviewers(in: [.init(id: "thread", notes: [source])], authorID: 3)
        }
        #expect(assessment.pureReviewerOptOutNoteIDs(in: [.init(id: "thread", notes: [source])], authorID: 3).isEmpty)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking, .uncertain])
    func aGeneralReviewWithAnIndependentExpectationRetainsItsReplyOrWorkObligation(_ state: ReReviewAssessment.Note.State) throws {
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"finding","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":true,"body":"Correct the retry path."},{"id":30,"author":{"id":3},"system":false,"body":"The correction and regression are verified."}]},{"id":"report","notes":[{"id":20,"author":{"id":7},"system":false,"resolvable":false,"body":"The review raised retries. Please also explain the chosen limit in this thread."}]}]"#.utf8))
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The correction and answer are verified."),
            .init(noteID: 20, state: state, reason: "The general report includes an independent expectation.",
                informationalPurpose: .reviewSummary, publishedReplyNoteID: state == .addressed ? 30 : nil)
        ])
        let normalized = try assessment.normalizingCoveredReviewSummaries(in: threads, authorID: 3)
        #expect(normalized.notes.last?.state == state)
        #expect(normalized.notes.last?.informationalPurpose == .reviewSummary)
        #expect(!normalized.hasNoRemainingAuthorWork(in: threads, authorID: 3))
        if state == .addressed {
            #expect(normalized.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [20])
            #expect(AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: normalized, authorID: 3,
                approvedReviewerIDs: [7]).contains { $0.id == 20 && $0.state == .needsReply })
        } else {
            #expect(normalized.readinessBlockers.contains { $0.noteID == 20 })
        }
    }

    @Test(arguments: [false, true])
    func aVerifiedCoveredReviewSummaryDoesNotInventAnotherAuthorReply(_ acknowledgement: Bool) throws {
        let threads = try summaryDiscussions()
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The correction and published answer are verified."),
            .init(noteID: 20, state: .addressed, reason: "This summary only repeats that corrected finding.",
                informationalAcknowledgementSafe: acknowledgement, informationalPurpose: .reviewSummary,
                reviewSummaryCoverage: .init(referencedNoteIDs: [10], noIndependentExpectation: true))
        ])
        #expect(try assessment.reviewers(in: threads, authorID: 3) == [7: 10])
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3).isEmpty)
        #expect(assessment.hasNoRemainingAuthorWork(in: threads, authorID: 3))
        #expect(assessment.notes.last?.informationalAcknowledgementSafe == acknowledgement)
        let normalized = try assessment.normalizingCoveredReviewSummaries(in: threads, authorID: 3)
        #expect(normalized.notes.last?.state == .informational)
        #expect(AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: 3,
            approvedReviewerIDs: [7]).allSatisfy { $0.state != .needsReply })
    }

    @Test(arguments: ["legacy", "unknown", "duplicate", "self", "independent", "concrete", "blocked", "uncertain", "reply", "question", "cycle", "summaryReference"])
    func summaryCoverageCannotWaiveAnIndependentOrUnverifiedObligation(_ change: String) throws {
        let threads = try summaryDiscussions(withReply: change != "reply")
        var original = ReReviewAssessment.Note(noteID: 10,
            state: change == "blocked" ? .blocking : change == "uncertain" ? .uncertain : .addressed,
            reason: "The concrete finding retains its own outcome.")
        if change == "cycle" {
            original.informationalPurpose = .reviewSummary
            original.reviewSummaryCoverage = .init(referencedNoteIDs: [20], noIndependentExpectation: true)
        }
        if change == "summaryReference" { original.informationalPurpose = .reviewSummary }
        let refs = change == "unknown" ? [99] : change == "duplicate" ? [10, 10] : change == "self" ? [20] : [10]
        let summary = ReReviewAssessment.Note(noteID: 20, state: .addressed, reason: "Claimed summary coverage.",
            informationalPurpose: change == "concrete" ? .concreteCodeReviewFeedback : .reviewSummary,
            reviewSummaryCoverage: change == "legacy" ? nil
                : .init(referencedNoteIDs: refs, noIndependentExpectation: change != "independent"))
        let question = ReReviewAssessment.CodeReviewRequest(sourceNoteID: 10, sourceQuote: "Please cover retries",
            kind: .potentialDefect, summary: "Check the retry path", question: "Does the retry preserve the request identity?")
        let assessment = ReReviewAssessment(notes: [original, summary], codeReviewRequests: change == "question" ? [question] : nil)
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3).contains(20))
        #expect(!assessment.hasNoRemainingAuthorWork(in: threads, authorID: 3))
        if change != "legacy" {
            #expect(throws: ReReviewAssessment.ValidationError.self) { try assessment.reviewers(in: threads, authorID: 3) }
        }
    }

    private func summaryDiscussions(withReply: Bool = true) throws -> [GitLabMergeRequestDiscussion] {
        let reply = withReply ? #",{"id":11,"author":{"id":3},"system":false,"body":"The retry now preserves the request identity; the regression verifies it."}"# : ""
        return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"finding","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":false,"body":"Please cover retries"}\#(reply)]},{"id":"summary","notes":[{"id":20,"author":{"id":7},"system":false,"resolvable":false,"body":"The earlier review raised the retry coverage issue."}]}]"#.utf8))
    }

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

    @Test func verifiedReplyInAnotherThreadDoesNotReplaceTheReplyOwedInThisThread() throws {
        // given
        let threads = try discussions()
        let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"Verified correction and reply."},{"noteID":12,"state":"informational","reason":"Summary."},{"noteID":13,"state":"addressed","reason":"The same correction is explained in published reply 14.","publishedReplyNoteID":14}]}"#.utf8))
        let replyThread = try JSONDecoder().decode(GitLabMergeRequestDiscussion.self, from: Data(#"{"notes":[{"id":14,"author":{"id":3},"system":false,"body":"The shared correction also addresses the same concern in note 13."}]}"#.utf8))
        // when
        let current = threads + [replyThread]
        // then
        #expect(try assessment.reviewers(in: current, authorID: 3) == [7: 10, 9: 13])
        #expect(assessment.missingPublishedReplyNoteIDs(in: current, authorID: 3) == [13])
        #expect(assessment.missingPublishedRepliesByThread(in: current, authorID: 3) == [13: [13]])
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [13])
    }

    @Test(arguments: [false, true])
    func aSharedCorrectionNeedsOnePublishedReplyPerConcreteThread(_ sameReviewer: Bool) throws {
        let reviewer = sameReviewer ? 7 : 9
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"first","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":false,"body":"Share the access check."},{"id":14,"author":{"id":3},"system":false,"body":"The shared service now performs the check. This also fixes note 13."}]},{"id":"second","notes":[{"id":13,"author":{"id":\#(reviewer)},"system":false,"resolvable":true,"resolved":false,"body":"Use the shared access service."}]}]"#.utf8))
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The shared correction is verified."),
            .init(noteID: 13, state: .addressed, reason: "The same correction is verified.", publishedReplyNoteID: 14)
        ])

        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [13])
        #expect(assessment.missingPublishedRepliesByThread(in: threads, authorID: 3) == [13: [13]])
    }

    @Test func addressedGeneralFeedbackAlsoNeedsItsOwnReplyButInformationalSummariesDoNot() throws {
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"general-feedback","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":false,"body":"Please document the new fallback."}]},{"id":"summary","notes":[{"id":12,"author":{"id":9},"system":false,"body":"The review raised the fallback documentation issue."}]}]"#.utf8))
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The fallback documentation is corrected."),
            .init(noteID: 12, state: .informational, reason: "Repeats the concrete finding without a new expectation.")
        ])

        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == [10])
        #expect(assessment.missingPublishedRepliesByThread(in: threads, authorID: 3) == [10: [10]])
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
