import Foundation
import Testing
@testable import GitLabTodos

@Suite("Author feedback policy")
struct AuthorFeedbackPolicyTests {
    private let fixedA = ReReviewAssessment.Note(noteID: 10, state: .addressed, reason: "Current diff fixes A")

    @Test func anInheritedConfirmedConcernLeadsBeforeAnotherParticipantsUncertainty() throws {
        let findings = try evaluate([
            thread("shared", note(10, by: 7, "Fix A", resolvable: true), note(11, by: 8, "Also fix B")),
            thread("uncertain", note(20, by: 7, "Verify the timeout")),
            thread("blocking", note(30, by: 8, "Fix the retry"))
        ], [fixedA, .init(noteID: 11, state: .addressed, reason: "B is fixed"),
            .init(noteID: 20, state: .uncertain, reason: "The timeout evidence is incomplete"),
            .init(noteID: 30, state: .blocking, reason: "The retry is still incorrect")])
        #expect(findings.first?.state == .needsChanges && findings.first?.sourceNoteID == 30)
    }

    @Test func anUncertainThreadKeepsItsOwnSourceWhenAnotherThreadHasAConfirmedBlocker() throws {
        let findings = try evaluate([
            thread("uncertain", note(10, by: 7, "Please verify the timeout", resolvable: true)),
            thread("blocking", note(20, by: 7, "Fix the retry", resolvable: true))
        ], [.init(noteID: 10, state: .uncertain, reason: "The timeout evidence is incomplete"),
            .init(noteID: 20, state: .blocking, reason: "The retry is still incorrect")])
        #expect(findings.map(\.state) == [.needsVerification, .needsChanges])
        #expect(findings.map(\.sourceNoteID) == [10, 20])
        #expect(findings.map(\.reason) == ["The timeout evidence is incomplete", "The retry is still incorrect"])
        #expect(findings.allSatisfy { !$0.canResolve })
    }

    @Test(arguments: [false, true])
    func uncertaintyIsNotPresentedAsAConfirmedCorrection(_ resolvable: Bool) throws {
        let findings = try evaluate([thread("uncertain", note(10, by: 7, "Please cover retries", resolvable: resolvable))], [
            .init(noteID: 10, state: .uncertain, reason: "The current test evidence is incomplete")
        ])
        #expect(findings.first?.state == .needsVerification)
        #expect(findings.first?.sourceNoteID == 10 && findings.first?.canResolve == false)
    }
    private var alicesThread: String {
        thread("d1", note(10, by: 7, "Fix A", resolvable: true), note(11, by: 3, "Fixed A", at: "2026-01-01T11:00:00Z"))
    }

    private func note(_ id: Int?, by author: Int, _ body: String, at created: String? = "2026-01-01T10:00:00Z",
                      updated: String? = nil, resolvable: Bool = false, resolved: Bool = false,
                      system: Bool = false) -> String {
        let names = [3: "me", 7: "alice", 8: "bob", 9: "carol"]
        let dates = [("created_at", created), ("updated_at", updated)]
            .compactMap { key, value in value.map { ",\"\(key)\":\"\($0)\"" } }.joined()
        return """
            {"id":\(id.map(String.init) ?? "null"),"author":{"id":\(author),"username":"\(names[author] ?? "")"},\
            "system":\(system),"resolvable":\(resolvable),"resolved":\(resolved),"body":"\(body)"\(dates)}
            """
    }

    private func thread(_ id: String?, _ notes: String...) -> String {
        "{\(id.map { "\"id\":\"\($0)\"," } ?? "")\"notes\":[\(notes.joined(separator: ","))]}"
    }

    private func decode(_ threads: [String]) throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("[\(threads.joined(separator: ","))]".utf8))
    }

    private func evaluate(_ threads: [String], _ verdicts: [ReReviewAssessment.Note]?, approved: Set<Int> = [],
                          enabled: Bool = true, drafts: Int = 0) throws -> [AuthorFeedbackPolicy.Finding] {
        AuthorFeedbackPolicy.evaluate(discussions: try decode(threads), assessment: verdicts.map { ReReviewAssessment(notes: $0) },
                                      authorID: 3, approvedReviewerIDs: approved, enabled: enabled,
                                      pendingDraftCount: drafts)
    }

    @Test func findingQuotesTheActualBlockingAssessmentNoteRatherThanItsThreadRoot() throws {
        let findings = try evaluate([thread("scope", note(10, by: 7, "Original concern", resolvable: true),
                                                  note(11, by: 8, "Specific remaining requirement"))], [
            .init(noteID: 10, state: .addressed, reason: "Original concern was fixed"),
            .init(noteID: 11, state: .blocking, reason: "The additional requirement remains")
        ])
        #expect(findings.first?.id == 10)
        #expect(findings.first?.reason == "The additional requirement remains")
        #expect(findings.first?.sourceNoteID == 11)
    }

    @Test func verifiedFixApprovedBySameReviewerIsReady() throws {
        let findings = try evaluate([alicesThread], [fixedA], approved: [7])
        #expect(findings == [.init(id: 10, discussionID: "d1", reviewerID: 7, reviewerUsername: "alice", state: .ready,
                                   reason: "Current diff fixes A", waitingForReviewers: [], sourceNoteID: 10)])
        #expect(findings.first?.canResolve == true)
    }

    @Test func aSharedReplyDoesNotAllowClosingAnUnansweredThreadEvenAfterApproval() throws {
        let findings = try evaluate([
            thread("original", note(10, by: 7, "Use the shared service", resolvable: true)),
            thread("elsewhere", note(11, by: 3, "The shared correction also fixes note 10"))
        ], [.init(noteID: 10, state: .addressed, reason: "The shared correction is verified", publishedReplyNoteID: 11)], approved: [7])

        #expect(findings.count == 1)
        #expect(findings.first?.state == .needsReply)
        #expect(findings.first?.canResolve == false)
    }

    @Test func purelyInformationalThreadNeedsNoApprovalAndDoesNotGrantReviewerAcceptance() throws {
        let threads = [thread("thanks", note(10, by: 7, "The access mapping looks good", resolvable: true)),
                       thread("other", note(20, by: 7, "Please cover another path", resolvable: true))]
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: .informational, reason: "No request, question or condition", informationalAcknowledgementSafe: true),
            .init(noteID: 20, state: .blocking, reason: "Independent coverage is still missing")
        ])
        let discussions = try decode(threads)
        let findings = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
            authorID: 3, approvedReviewerIDs: [])
        #expect(findings.first?.canResolve == true)
        #expect(findings.first?.waitingForReviewers.isEmpty == true)
        #expect(findings.last?.state == .needsChanges)
        #expect(AuthorFeedbackPolicy.acceptedReviewers(discussions: discussions, assessment: assessment,
            authorID: 3, approvedReviewerIDs: []).isEmpty)
        #expect(try evaluate(threads, assessment.notes, enabled: false).first?.state == .disabled)
        #expect(try evaluate(threads, assessment.notes, drafts: 1).first?.state == .waitingPublication)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking, .uncertain])
    func informationalChildNeverMakesAMixedThreadReadyWithoutNormalConsent(_ state: ReReviewAssessment.Note.State) throws {
        let threads = [thread("mixed", note(10, by: 7, "Please cover a missing path", resolvable: true),
                              note(20, by: 8, "The mapping itself looks good"))]
        let findings = try evaluate(threads, [
            .init(noteID: 10, state: state, reason: "The original request still requires its ordinary workflow"),
            .init(noteID: 20, state: .informational, reason: "A positive side observation", informationalAcknowledgementSafe: true)
        ])
        #expect(findings.count == 1)
        #expect(findings.first?.canResolve == false)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking, .uncertain])
    func acknowledgementFlagNeverOverridesAnActionableState(_ state: ReReviewAssessment.Note.State) throws {
        let discussions = try decode([thread("mixed", note(10, by: 7, "Please add coverage", resolvable: true),
                                             note(20, by: 8, "The mapping looks good"))])
        let assessment = ReReviewAssessment(notes: [
            .init(noteID: 10, state: state, reason: "The original expectation requires its normal workflow", informationalAcknowledgementSafe: true),
            .init(noteID: 20, state: .informational, reason: "A positive side observation", informationalAcknowledgementSafe: true)
        ])
        #expect(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
            assessment: assessment, authorID: 3).isEmpty)
        #expect(AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
            authorID: 3, approvedReviewerIDs: []).allSatisfy { !$0.canResolve })
    }

    @Test func legacyInformationalAssessmentNeverAuthorizesAcknowledgement() throws {
        let discussions = try decode([thread("praise", note(10, by: 7, "Looks good", resolvable: true))])
        let legacy = try JSONDecoder().decode(ReReviewAssessment.self,
            from: Data(#"{"notes":[{"noteID":10,"state":"informational","reason":"No remaining action"}]}"#.utf8))
        #expect(legacy.notes.first?.informationalAcknowledgementSafe == nil)
        #expect(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
            assessment: legacy, authorID: 3).isEmpty)
        #expect(AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: legacy,
            authorID: 3, approvedReviewerIDs: []).allSatisfy { !$0.canResolve })
    }

    @Test func advanceApprovalNeverOverridesARemainingConditionElsewhere() throws {
        let general = thread("g1", note(20, by: 7, "Also rename X", at: "2026-01-01T10:05:00Z"))
        let otherThread = thread("d2", note(20, by: 7, "Also rename X", at: "2026-01-01T10:05:00Z", resolvable: true))
        for elsewhere in [general, otherThread] {
            for state in [ReReviewAssessment.Note.State.blocking, .uncertain] {
                let blocked = try evaluate([alicesThread, elsewhere],
                                           [fixedA, .init(noteID: 20, state: state, reason: "X is not renamed")], approved: [7])
                #expect(blocked.map(\.id) == [10, 20])
                let expected: AuthorFeedbackPolicy.State = state == .uncertain ? .needsVerification : .needsChanges
                #expect(blocked.map(\.state) == [expected, expected])
                #expect(blocked.map(\.reason) == ["X is not renamed", "X is not renamed"])
                #expect(blocked[0].waitingForReviewers == ["alice"])
                #expect(blocked[1].discussionID == (elsewhere == general ? nil : "d2"))
                #expect(blocked.allSatisfy { !$0.canResolve })
            }
            let answered = thread(elsewhere == general ? "g1" : "d2",
                note(20, by: 7, "Also rename X", resolvable: elsewhere != general), note(21, by: 3, "Renamed X"))
            let addressed = try evaluate([alicesThread, answered],
                                         [fixedA, .init(noteID: 20, state: .addressed, reason: "X renamed")], approved: [7])
            #expect(addressed.first?.id == 10)
            #expect(!addressed.isEmpty)
            #expect(addressed.allSatisfy { $0.canResolve })
        }
    }

    @Test func approvalBySomeoneElseIsNotConsent() throws {
        let findings = try evaluate([alicesThread], [fixedA], approved: [3, 8])
        #expect(findings.map(\.state) == [.waitingAcceptance])
        #expect(findings.first?.waitingForReviewers == ["alice"])
    }

    @Test func oneLaterGeneralCommentCanAcceptSeveralFindings() throws {
        let threads = [alicesThread,
                       thread("d2", note(30, by: 7, "Fix B", at: "2026-01-01T10:10:00Z", resolvable: true),
                            note(31, by: 3, "Fixed B", at: "2026-01-01T11:00:00Z")),
                       thread("g1", note(40, by: 7, "Thanks, both look good", at: "2026-01-01T12:00:00.250Z"))]
        let findings = try evaluate(threads, [
            .init(noteID: 10, state: .addressed, reason: "Fixed A", acceptanceNoteID: 40),
            .init(noteID: 30, state: .addressed, reason: "Fixed B", acceptanceNoteID: 40),
            .init(noteID: 40, state: .informational, reason: "Reviewer accepts both fixes")])
        #expect(findings.map(\.id) == [10, 30])
        #expect(findings.allSatisfy { $0.canResolve })
    }

    @Test func invalidCommentAcceptanceIsRejected() throws {
        let concern = note(10, by: 7, "Fix A", resolvable: true)
        let ack = note(40, by: 7, "Looks good now", at: "2026-01-01T12:00:00Z")
        let cases: [(concern: String, ack: String, cited: Int?, ready: Bool)] = [
            (concern, ack, 40, true),
            (concern, note(40, by: 8, "Looks good now", at: "2026-01-01T12:00:00Z"), 40, false),
            (concern, note(9, by: 7, "Looks good now", at: "2026-01-01T12:00:00Z"), 9, false),
            (concern, note(40, by: 7, "Looks good now", at: "2026-01-01T09:00:00Z"), 40, false),
            (concern, note(40, by: 7, "Looks good now", at: "yesterday"), 40, false),
            (concern, note(40, by: 7, "Looks good now", at: nil), 40, false),
            (concern, note(40, by: 7, "approved this merge request", at: "2026-01-01T12:00:00Z", system: true), 40, false),
            (concern, ack, nil, false),
            (concern, ack, 999, false),
            (note(10, by: 7, "Fix A", updated: "2026-01-01T13:00:00Z", resolvable: true), ack, 40, false),
            (note(10, by: 7, "Fix A", at: nil, resolvable: true), ack, 40, false),
        ]
        for item in cases {
            let threads = [thread("d1", item.concern, note(11, by: 3, "Fixed A")), thread("g1", item.ack)]
            let external = try decode(threads).flatMap(\.notes).filter { $0.system == false && $0.author?.id != 3 }.compactMap(\.id)
            let verdicts = external.map { id -> ReReviewAssessment.Note in
                id == 10 ? .init(noteID: 10, state: .addressed, reason: "Fixed A", acceptanceNoteID: item.cited)
                    : .init(noteID: id, state: .informational, reason: "Acknowledgement")
            }
            let findings = try evaluate(threads, verdicts)
            #expect(findings.map(\.state) == [item.ready ? AuthorFeedbackPolicy.State.ready : .waitingAcceptance])
        }
    }

    @Test func everyActionableParticipantMustConsentButBystandersNeedNot() throws {
        let threads = [thread("d1", note(10, by: 7, "Fix A", resolvable: true),
                              note(11, by: 3, "Fixed A", at: "2026-01-01T11:00:00Z"),
                              note(12, by: 8, "Also cover nil input", at: "2026-01-01T11:30:00Z"),
                              note(13, by: 9, "+1", at: "2026-01-01T11:40:00Z"),
                              note(14, by: 3, "Nil input is covered", at: "2026-01-01T11:50:00Z"))]
        let verdicts = [fixedA, .init(noteID: 12, state: .addressed, reason: "Nil input covered"),
                        .init(noteID: 13, state: .informational, reason: "Agreement only")]
        let waiting = try evaluate(threads, verdicts, approved: [7])
        #expect(waiting.map(\.state) == [.waitingAcceptance])
        #expect(waiting.first?.waitingForReviewers == ["bob"])
        #expect(try evaluate(threads, verdicts, approved: [7, 8]).first?.canResolve == true)

        let informationalRoot = try evaluate([alicesThread], [.init(noteID: 10, state: .informational, reason: "Answered")])
        #expect(informationalRoot.map(\.state) == [.waitingAcceptance])
        #expect(informationalRoot.first?.waitingForReviewers == ["alice"])
    }

    @Test func unknownOrIncompleteAssessmentNeverResolves() throws {
        let threads = [alicesThread, thread("g1", note(20, by: 7, "Nit", at: "2026-01-01T10:05:00Z"))]
        let cases: [[ReReviewAssessment.Note]?] = [
            nil, [fixedA], [fixedA, fixedA],
            [fixedA, .init(noteID: 20, state: .informational, reason: " ")],
            [fixedA, .init(noteID: 999, state: .informational, reason: "Unknown")],
        ]
        for verdicts in cases {
            let findings = try evaluate(threads, verdicts, approved: [7])
            #expect(findings.map(\.id) == [10])
            #expect(findings.map(\.state) == [.needsVerification])
            #expect(findings.first?.reason == nil)
        }
    }

    @Test func explicitAcceptanceSurvivesResolutionWithoutAnotherReviewRequest() throws {
        let closed = thread("d1", note(10, by: 7, "Fix A", resolvable: true, resolved: true))
        let acknowledgment = thread("g1", note(40, by: 7, "All fixed", at: "2026-01-01T12:00:00Z"))
        let verdicts: [ReReviewAssessment.Note] = [
            .init(noteID: 10, state: .addressed, reason: "Fixed", acceptanceNoteID: 40),
            .init(noteID: 40, state: .informational, reason: "Reviewer accepts the fix")]
        #expect(AuthorFeedbackPolicy.acceptedReviewers(discussions: try decode([closed, acknowledgment]),
            assessment: .init(notes: verdicts), authorID: 3, approvedReviewerIDs: []) == [7])
        let remaining = thread("g2", note(50, by: 7, "But still rename X", at: "2026-01-01T13:00:00Z"))
        #expect(AuthorFeedbackPolicy.acceptedReviewers(discussions: try decode([closed, acknowledgment, remaining]),
            assessment: .init(notes: verdicts + [.init(noteID: 50, state: .blocking, reason: "Rename pending")]),
            authorID: 3, approvedReviewerIDs: [7]).isEmpty)
    }

    @Test func resolvedThreadDoesNotEraseAnUnfulfilledReviewerExpectation() throws {
        let closed = thread("old", note(20, by: 7, "Still add regression coverage", resolvable: true, resolved: true))
        let findings = try evaluate([alicesThread, closed], [fixedA,
            .init(noteID: 20, state: .blocking, reason: "The requested regression test is missing")], approved: [7])
        #expect(findings.map(\.id) == [10, 20])
        #expect(findings.allSatisfy { $0.state == .needsChanges })
        #expect(findings.allSatisfy { !$0.canResolve })
    }

    @Test func draftsDisabledResolvedSystemAndAuthorRootsAreUntouched() throws {
        let threads = [alicesThread,
                       thread("d5", note(50, by: 7, "Fixed earlier", resolvable: true, resolved: true)),
                       thread("d6", note(60, by: 3, "Self note", resolvable: true),
                              note(61, by: 7, "Agreed", at: "2026-01-01T10:30:00Z")),
                       thread("d7", note(70, by: 7, "changed the description", resolvable: true, system: true)),
                       thread(nil, note(80, by: 7, "Fix C", resolvable: true))]
        let verdicts = [fixedA, .init(noteID: 50, state: .addressed, reason: "Fixed earlier"),
                        .init(noteID: 61, state: .informational, reason: "Agreement"),
                        .init(noteID: 80, state: .addressed, reason: "Fixed C")]
        #expect(try evaluate(threads, verdicts, approved: [7]).map(\.id) == [10])
        #expect(try evaluate(threads, verdicts, approved: [7], enabled: false).map(\.state) == [.disabled])
        #expect(try evaluate(threads, verdicts, approved: [7], drafts: 1).map(\.state) == [.waitingPublication])
        #expect(try evaluate(threads, verdicts, approved: [7], drafts: 1).allSatisfy { !$0.canResolve })

        let malformed = threads + [thread("d8", note(nil, by: 7, "Fix D", resolvable: true))]
        let findings = try evaluate(malformed, verdicts, approved: [7])
        #expect(findings.map(\.id) == [10])
        #expect(findings.map(\.state) == [.needsVerification])
    }
}
