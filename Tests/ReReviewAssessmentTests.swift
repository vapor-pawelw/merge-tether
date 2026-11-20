import Foundation
import Testing
@testable import MergeTether

@Suite("Re-review assessment")
struct ReReviewAssessmentTests {
    @Test func manualDecisionRetainsEnoughContextToUnderstandTheWholeProblem() throws {
        // given
        let note = try FeedbackManualDecisionFixture.note()
        // when
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        // then
        #expect(wire["manualDecision"] as? [String: String] == FeedbackManualDecisionFixture.context)
        let assessment = ReReviewAssessment(notes: [note, .init(noteID: 20, state: .blocking, reason: "Fix the retry")])
        #expect(assessment.automaticWorkNoteIDs == [20])
        #expect(assessment.readinessBlockers.map(\.noteID) == [20, 10])
        #expect(!note.needsAutomaticWork)
        let legacy = try JSONDecoder().decode(ReReviewAssessment.Note.self,
            from: Data(#"{"noteID":10,"state":"uncertain","reason":"A source check is still needed"}"#.utf8))
        #expect(legacy.needsAutomaticWork)
    }

    @Test(arguments: ["emptyContext", "wrongState", "oversizedQuestion"])
    func incompleteManualDecisionsCannotSuppressAutomaticWork(_ scenario: String) throws {
        // given
        var fields = FeedbackManualDecisionFixture.context
        if scenario == "emptyContext" { fields["context"] = "  " }
        if scenario == "oversizedQuestion" { fields["question"] = String(repeating: "?", count: 1001) }
        let note = try FeedbackManualDecisionFixture.note(state: scenario == "wrongState" ? "blocking" : "uncertain", fields: fields)
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(
            #"[{"id":"contract","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,"body":"Clarify the provider contract"}]}]"#.utf8))
        // when + then
        #expect(throws: ReReviewAssessment.ValidationError.self) {
            try ReReviewAssessment(notes: [note]).reviewers(in: discussions, authorID: 3)
        }
    }

    @Test(arguments: [false, true])
    func rejectedFeedbackStillNeedsItsOwnReplyAndReviewerAcceptance(_ withReply: Bool) throws {
        let decoded = try? JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"rejected","reason":"Current remote source proves the suggested retry would duplicate a request."}]}"#.utf8))
        #expect(decoded != nil, "Verified rejection is a distinct semantic outcome, not an implemented correction")
        guard let assessment = decoded else { return }
        let reply = withReply ? #",{"id":11,"author":{"id":3,"username":"me"},"system":false,"body":"The existing request key already prevents duplicates; the proposed retry would send twice."}"# : ""
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,"resolvable":true,"resolved":false,"body":"Retry the request once more"}\#(reply)]}]"#.utf8))
        #expect(assessment.notes.first?.state.rawValue == "rejected")
        #expect(assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3) == (withReply ? [] : [10]))
        #expect(assessment.hasNoRemainingAuthorWork(in: threads, authorID: 3) == withReply)
        let pending = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment,
            authorID: 3, approvedReviewerIDs: [])
        #expect(pending.first?.state == (withReply ? .waitingAcceptance : .needsReply))
        #expect(pending.first?.canResolve == false)
        let approved = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment,
            authorID: 3, approvedReviewerIDs: [7])
        #expect(approved.first?.state == (withReply ? .ready : .needsReply))
    }

    @Test func legacySemanticAssessmentsCannotBeReusedAsCurrentOrPriorPasses() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let record = AuthorFeedbackAssessmentStore.Record(version: 1, target: target, keyDigest: "legacy-semantics",
            completedFollowUpJobID: nil, assessment: .init(notes: [.init(noteID: 10, state: .addressed,
                reason: "Old semantics classified a justified rejection as addressed.")]),
            noteRevisions: [10: "unchanged"], diffDigest: "same-remote-diff")
        try AuthorFeedbackAssessmentStore.save(record, in: folder)
        #expect(AuthorFeedbackAssessmentStore.load(target, keyDigest: record.keyDigest, in: folder) == nil)
        #expect(AuthorFeedbackAssessmentStore.latest(target, in: folder) == nil)
        #expect(FileManager.default.fileExists(atPath: AuthorFeedbackAssessmentStore.fileURL(target, in: folder).path))
    }

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
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"finding","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":false,"body":"Correct the retry path."},{"id":30,"author":{"id":3},"system":false,"body":"The correction and regression are verified."}]},{"id":"report","notes":[{"id":20,"author":{"id":7},"system":false,"resolvable":false,"body":"The review raised retries. Please also explain the chosen limit in this thread."}]}]"#.utf8))
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

    @Test(arguments: ["answered", "resolvableOverview", "otherReviewer", "laterSubmission", "missingTimestamp",
                      "blockedFinding", "question", "ignored", "replyByReviewer"])
    func anOverviewFromTheSameReviewSubmissionIsAnsweredByTheFindingThreadReply(_ scenario: String) throws {
        // given: a non-resolvable review overview and the resolvable finding it summarizes, published together
        let overviewTime = "2026-11-04T21:32:03.557Z"
        let findingTime = scenario == "laterSubmission" ? "2026-11-05T09:00:00.000Z" : "2026-11-04T21:32:03.692Z"
        let created = scenario == "missingTimestamp" ? "" : #","created_at":"\#(overviewTime)""#
        let findingAuthor = scenario == "otherReviewer" ? 9 : 7
        let replyAuthor = scenario == "replyByReviewer" ? 7 : 3
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
            [{"id":"overview","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":\(scenario == "resolvableOverview"),"resolved":false\(created),"body":"I left one recommendation, on the title filter."}]},
             {"id":"finding","notes":[{"id":11,"author":{"id":\(findingAuthor)},"system":false,"resolvable":true,"resolved":false,"created_at":"\(findingTime)","body":"Bound the title filter."},
                                      {"id":14,"author":{"id":\(replyAuthor)},"system":false,"resolvable":true,"resolved":false,"created_at":"2026-11-05T07:40:33.959Z","body":"Added a 255-code-point limit."}]}]
            """.utf8))
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The same correction is explained in reply 14.",
                informationalPurpose: .concreteCodeReviewFeedback,
                ignoredDecisionIDs: scenario == "ignored" ? [UUID()] : nil, publishedReplyNoteID: 14),
            .init(noteID: 11, state: scenario == "blockedFinding" ? .blocking : .addressed, reason: "The title limit is verified.",
                publishedReplyNoteID: scenario == "blockedFinding" ? nil : 14)
        ], codeReviewRequests: scenario == "question"
            ? [.init(sourceNoteID: 10, sourceQuote: "title filter", kind: .feedbackVerification, summary: "Check", question: "Is it bounded?")]
            : nil)

        // when
        let missing = assessment.missingPublishedReplyNoteIDs(in: threads, authorID: 3)

        // then
        #expect(missing.contains(10) == (scenario != "answered"))
        #expect(assessment.missingPublishedRepliesByThread(in: threads, authorID: 3)[10] == (scenario == "answered" ? nil : [10]))
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


enum FeedbackManualDecisionFixture {
    static let context = [
        "context": "The application retrieves one transaction from a provider using its transaction identifier. The review asks how an absent transaction is represented.",
        "verifiedFacts": "The adapter preserves an explicit provider not-found response. A stub test verifies that mapping and that other failures remain server errors.",
        "missingEvidence": "The accessible provider contract omits the absent-transaction response. No integration environment is available to verify it.",
        "question": "Does the required provider contract guarantee a distinct not-found response, and which response is it?",
        "mergeImpact": "This requirement remains unresolved, so keep this concern open and automatic merge on hold. Other corrections can continue."
    ]
    static func note(state: String = "uncertain", fields: [String: String] = context) throws -> ReReviewAssessment.Note {
        try JSONDecoder().decode(ReReviewAssessment.Note.self, from: JSONSerialization.data(withJSONObject: [
            "noteID": 10, "state": state, "reason": "An essential provider contract decision needs external evidence.",
            "summary": "Confirm the required absent-transaction response", "manualDecision": fields
        ]))
    }
}
