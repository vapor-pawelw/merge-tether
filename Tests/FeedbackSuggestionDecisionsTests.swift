import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct FeedbackSuggestionDecisionsTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)

    @Test(arguments: [false, true])
    func anAddressedCompanionConcernStillOwesItsReplyAndCannotResolveAWaivedThread(_ withReply: Bool) throws {
        let note = try source()
        let entry = decision(for: note)
        let reply = try JSONDecoder().decode(GitLabMergeRequestDiscussion.Note.self,
            from: Data(#"{"id":43,"author":{"id":1,"username":"me"},"system":false,"body":"The separate requested correction and its verification are complete."}"#.utf8))
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: withReply ? [note, reply] : [note])]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 42, state: .addressed,
            reason: "The optional assumption is user-declined; the separate regression correction is verified.", ignoredDecisionIDs: [entry.id])])
        let validated = try? assessment.reviewers(in: discussions, authorID: 1, ignoredSuggestions: [entry])
        #expect(validated != nil)
        #expect(assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: 1) == (withReply ? [] : [42]))
        let findings = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
            authorID: 1, approvedReviewerIDs: [2], ignoredSuggestions: [entry])
        let canResolve = findings.contains(where: \.canResolve)
        #expect(!canResolve)
    }

    @Test(arguments: ["remove", "reset"])
    func restoringAnEmptyListAdvancesItsPersistentDecisionContext(_ operation: String) throws {
        var ledger = FeedbackSuggestionDecisions()
        let initial = ledger.revision(for: target)
        let sibling = MRAutomationScope.Target(host: target.host, username: target.username, projectID: 7, iid: 12)
        let siblingInitial = ledger.revision(for: sibling)
        let result = ledger.ignore(try source(), concernSummary: "Precise concern", concernReason: "Exact assumption", for: target)
        let entry = try #require(result)
        let whileIgnored = ledger.revision(for: target)
        if operation == "remove" { ledger.remove(entry.id, for: target) }
        else { ledger.reset(for: target) }
        let restored = try JSONDecoder().decode(FeedbackSuggestionDecisions.self, from: JSONEncoder().encode(ledger))

        #expect(restored.entries(for: target).isEmpty)
        #expect(restored.revision(for: target) != initial)
        #expect(restored.revision(for: target) != whileIgnored)
        #expect(restored.revision(for: sibling) == siblingInitial)
    }

    @Test(arguments: ["exact", "missingIDs", "wrongID", "restored", "editedSource"])
    func userIgnoredVerdictRequiresCurrentPreciseDecisionEvidence(_ scenario: String) throws {
        let note = try source()
        let entry = decision(for: note)
        let current = scenario == "editedSource" ? try source(body: "A new obligation was added.") : note
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [current])]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 42, state: .ignoredByUser,
            reason: "Only the explicitly declined concern remains.",
            ignoredDecisionIDs: scenario == "missingIDs" ? nil : [scenario == "wrongID" ? UUID() : entry.id])])
        let active = scenario == "restored" ? [] : [entry]
        if scenario == "exact" {
            let reviewers = try assessment.reviewers(in: discussions, authorID: 1, ignoredSuggestions: active)
            #expect(reviewers.isEmpty)
            let findings = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
                authorID: 1, approvedReviewerIDs: [2], ignoredSuggestions: active)
            let canResolve = findings.contains(where: \.canResolve)
            #expect(!canResolve)
            #expect(!findings.contains { [.needsChanges, .needsVerification].contains($0.state) })
            #expect(AuthorFeedbackPolicy.informationalAcknowledgements(discussions: discussions,
                assessment: assessment, authorID: 1).isEmpty)
        } else {
            #expect(throws: (any Error).self) {
                try assessment.reviewers(in: discussions, authorID: 1, ignoredSuggestions: active)
            }
        }
    }

    @Test func anIgnoredAssumptionCannotHideAnotherObligationInTheSameComment() throws {
        let note = try source()
        let entry = decision(for: note)
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [note])]
        let assessment = ReReviewAssessment(notes: [.init(noteID: 42, state: .blocking,
            reason: "The release assumption is declined, but the requested regression test is missing.",
            ignoredDecisionIDs: [entry.id])])
        let findings = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment,
            authorID: 1, approvedReviewerIDs: [2], ignoredSuggestions: [entry])
        #expect(findings.first?.state == .needsChanges)
        let canResolve = findings.contains(where: \.canResolve)
        #expect(!canResolve)
    }

    @Test func preciseConcernDecisionsSurviveSettingsReloadWithoutSuppressingTheWholeNote() throws {
        let suite = "FeedbackSuggestionDecisions.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let note = try source()
        let firstResult = settings.feedbackSuggestionDecisions.ignore(note,
            concernSummary: "Do not require later release approval for this correction.",
            concernReason: "Only the later release approval assumption is declined; the regression test is still required.", for: target)
        let first = try #require(firstResult)
        let secondResult = settings.feedbackSuggestionDecisions.ignore(note,
            concernSummary: "A separate optional refactor is out of scope.", concernReason: "This does not waive the regression test.", for: target)
        let second = try #require(secondResult)
        settings.save()

        let restored = SettingsManager(defaults: defaults).feedbackSuggestionDecisions

        #expect(Set(restored.entries(for: target).map(\.id)) == [first.id, second.id])
        #expect(restored.entries(for: target).allSatisfy { $0.sourceBody == note.body })
        #expect(restored.entries(for: target).map(\.concernSummary) == [first.concernSummary, second.concernSummary])
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [note])]
        #expect(restored.applicable(in: discussions, for: target).count == 2)
    }

    @Test func editedSourcesAndDifferentAccountsNeverInheritAnOldConcernDecision() throws {
        var ledger = FeedbackSuggestionDecisions()
        let note = try source()
        let result = ledger.ignore(note, concernSummary: "Ignore only the optional release assumption.",
            concernReason: "The code correction still has to be verified.", for: target)
        let decision = try #require(result)
        let unchanged = [GitLabMergeRequestDiscussion(id: "thread", notes: [note])]
        #expect(ledger.applicable(in: unchanged, for: target).map(\.id) == [decision.id])
        let edited = try source(body: "Edited request")
        #expect(ledger.applicable(in: [GitLabMergeRequestDiscussion(id: "thread", notes: [edited])], for: target).isEmpty)
        let otherAccount = MRAutomationScope.Target(host: target.host, username: "other", projectID: 7, iid: 11)
        #expect(ledger.applicable(in: unchanged, for: otherAccount).isEmpty)
        #expect(ledger.entries(for: otherAccount).isEmpty)
        #expect(ledger.applicable(in: [], for: target).isEmpty)
    }

    @Test func restoringOneConcernAndResettingOneMRLeaveOtherDecisionsIntact() throws {
        var ledger = FeedbackSuggestionDecisions()
        let note = try source()
        let firstResult = ledger.ignore(note, concernSummary: "First concern", concernReason: "First exact assumption", for: target)
        let first = try #require(firstResult)
        let secondResult = ledger.ignore(note, concernSummary: "Second concern", concernReason: "Second exact assumption", for: target)
        let second = try #require(secondResult)
        let sibling = MRAutomationScope.Target(host: target.host, username: target.username, projectID: 7, iid: 12)
        let thirdResult = ledger.ignore(note, concernSummary: "Sibling concern", concernReason: "A distinct MR decision", for: sibling)
        let third = try #require(thirdResult)
        let removedFromSibling = ledger.remove(first.id, for: sibling)
        #expect(removedFromSibling == false)
        let removedFromTarget = ledger.remove(first.id, for: target)
        #expect(removedFromTarget)
        #expect(ledger.entries(for: target).map(\.id) == [second.id])
        let resetCount = ledger.reset(for: target)
        #expect(resetCount == 1)
        #expect(ledger.entries(for: target).isEmpty)
        #expect(ledger.entries(for: sibling).map(\.id) == [third.id])
    }

    @Test func exactDecisionRetriesAreIdempotentButDifferentConcernsInOneCommentRemainDistinct() throws {
        var ledger = FeedbackSuggestionDecisions()
        let note = try source()
        let firstResult = ledger.ignore(note, concernSummary: "Only this concern", concernReason: "Exact rationale", for: target)
        let first = try #require(firstResult)
        let retriedResult = ledger.ignore(note, concernSummary: "Only this concern", concernReason: "Exact rationale", for: target)
        let retried = try #require(retriedResult)
        #expect(retried.id == first.id)
        #expect(ledger.entries(for: target).count == 1)
    }

    private func source(body: String = "Please add the regression test. It is worth obtaining approval before a later deployment.") throws -> GitLabMergeRequestDiscussion.Note {
        let data = try JSONSerialization.data(withJSONObject: ["id": 42, "author": ["id": 2, "username": "reviewer"], "system": false,
            "body": body, "resolvable": true, "resolved": false])
        return try JSONDecoder().decode(GitLabMergeRequestDiscussion.Note.self, from: data)
    }

    private func decision(for note: GitLabMergeRequestDiscussion.Note) -> IgnoredFeedbackSuggestion {
        .init(id: UUID(), target: target, sourceNoteID: note.id!, sourceAuthorID: note.author!.id,
            sourceBody: note.body!, sourceRevision: UserAttentionSnapshot.digest("\(note.author!.id)\n" + note.body!),
            concernSummary: "The later release assumption is declined.", concernReason: "The regression test remains required.", createdAt: Date())
    }
}
