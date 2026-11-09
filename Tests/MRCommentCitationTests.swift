import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRCommentCitationTests {
    private let host = "gitlab.example.test"
    private var target: MRDiscussionTarget {
        .init(host: host, username: "me", projectID: 7, iid: 11,
            url: URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11")!)
    }
    private func request() throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":11,"title":"Example","author":{"id":3,"username":"me","name":"Me"},"web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"opened","draft":false,"sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
    private func note(_ id: Int, _ body: String = "Exact source text", system: Bool = false) -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: .init(id: 8, username: "reviewer", name: "Reviewer"), system: system,
            resolvable: true, resolved: false, resolvedBy: nil, body: body)
    }
    private func discussions() -> [GitLabMergeRequestDiscussion] {
        [.init(id: "unrelated", notes: [note(5, "An unrelated earlier thread")]),
         .init(id: "selected", notes: [note(40, "Original root"), note(42, "  Exact selected requirement.\nSecond line.  ")])]
    }
    private func context(_ threads: [GitLabMergeRequestDiscussion]? = nil) throws -> MRCommentCitation.Context {
        try #require(MRCommentCitation.Context(target: target, loadedTarget: target, request: request(),
            discussions: threads ?? discussions(), hasLoaded: true, hasError: false))
    }
    private func status(_ threads: [GitLabMergeRequestDiscussion]) throws -> AuthorFeedbackStatus {
        .init(head: "abc", fingerprint: try #require(ReviewVerdict.fingerprint(threads)),
            semanticContextFingerprint: try request().semanticContextFingerprint, phase: .complete)
    }
    private var finding: AuthorFeedbackPolicy.Finding {
        .init(id: 40, discussionID: "selected", reviewerID: 8, reviewerUsername: "reviewer", state: .needsChanges,
            reason: "The selected requirement remains", waitingForReviewers: [], sourceNoteID: 42)
    }

    @Test func assessmentCitationUsesExactProvenanceTextAuthorAndNoteLink() throws {
        let source = try #require(context().finding(finding, status: status(discussions())))
        #expect(source.id == 42)
        #expect(source.discussionID == "selected")
        #expect(source.note.body == "  Exact selected requirement.\nSecond line.  ")
        #expect(source.note.author?.username == "reviewer")
        #expect(source.url.absoluteString == "https://gitlab.example.test/team/repo/-/merge_requests/11#note_42")
    }

    @Test func sharedSnapshotKeepsItsEvidenceUntilRebuiltForEditedDiscussions() throws {
        // given
        let originalThreads = discussions()
        let originalStatus = try status(originalThreads)
        let original = try context(originalThreads)
        let editedThreads = [GitLabMergeRequestDiscussion(id: "selected", notes: [note(42, "Edited requirement")])]
        let editedStatus = try status(editedThreads)

        // when
        let refreshed = try context(editedThreads)

        // then
        #expect(original.finding(finding, status: originalStatus)?.note.body == "  Exact selected requirement.\nSecond line.  ")
        #expect(original.finding(finding, status: editedStatus) == nil)
        #expect(refreshed.finding(finding, status: originalStatus) == nil)
        #expect(refreshed.finding(finding, status: editedStatus)?.note.body == "Edited requirement")
    }

    @Test func repeatedNoteIDsNeverBecomeCitableAgainAfterAnotherDuplicate() throws {
        let threads = [GitLabMergeRequestDiscussion(id: "selected", notes: [note(42), note(42), note(42)])]
        #expect(try context(threads).finding(finding, status: status(threads)) == nil)
    }

    @Test(arguments: ["legacy", "head", "text", "thread", "phase", "missing", "duplicate", "system", "empty"])
    func missingOrStaleAssessmentEvidenceNeverGuessesASource(_ change: String) throws {
        var threads = discussions()
        var finding = finding
        var current = try status(threads)
        if change == "legacy" { finding.sourceNoteID = nil }
        if change == "head" { current = .init(head: "older", fingerprint: current.fingerprint, phase: .complete) }
        if change == "text" { current.semanticContextFingerprint = "old description" }
        if change == "thread" { threads = [.init(id: "selected", notes: [note(42, "Edited source")])] }
        if change == "phase" { current.phase = .checking }
        if change == "missing" { finding.sourceNoteID = 999 }
        if change == "duplicate" { threads.append(.init(id: "duplicate", notes: [note(42)])); current = try status(threads) }
        if change == "system" { threads = [.init(id: "selected", notes: [note(42, system: true)])]; current = try status(threads) }
        if change == "empty" { threads = [.init(id: "selected", notes: [note(42, " ")])]; current = try status(threads) }
        #expect(try context(threads).finding(finding, status: current) == nil)
    }

    @Test(arguments: ["account", "host", "mr", "missing", "failed"])
    func discussionCacheFromAnotherContextOrAFailedLoadIsNotCitable(_ change: String) throws {
        var loaded = target
        if change == "account" { loaded = .init(host: host, username: "other", projectID: 7, iid: 11, url: target.url) }
        if change == "host" { loaded = .init(host: "other.example.test", username: "me", projectID: 7, iid: 11, url: target.url) }
        if change == "mr" { loaded = .init(host: host, username: "me", projectID: 7, iid: 12, url: target.url) }
        #expect(try MRCommentCitation.Context(target: target, loadedTarget: loaded, request: request(),
            discussions: discussions(), hasLoaded: change != "missing", hasError: change == "failed") == nil)
    }

    @Test func draftCitationSelectsItsOwnDiscussionAndNeverTheFirstThread() throws {
        let draft = try JSONDecoder().decode(GitLabDraftNote.self,
            from: Data(#"{"id":71,"author_id":3,"note":"Private reply","discussion_id":"selected"}"#.utf8))
        let source = try #require(context().reply(to: draft, rootNoteID: 40))
        #expect(source.id == 40 && source.note.body == "Original root")
        #expect(source.url.fragment == "note_40")
        #expect(try context().reply(to: draft, rootNoteID: 5) == nil)
        let unmatched = try JSONDecoder().decode(GitLabDraftNote.self,
            from: Data(#"{"id":72,"author_id":3,"note":"Private reply","discussion_id":"absent"}"#.utf8))
        #expect(try context().reply(to: unmatched) == nil)
    }

    @Test func repeatedDiscussionIDsCannotSelectADraftRootEvenWhenEarlierCopiesAreEmpty() throws {
        let draft = try JSONDecoder().decode(GitLabDraftNote.self,
            from: Data(#"{"id":71,"author_id":3,"note":"Private reply","discussion_id":"selected"}"#.utf8))
        let threads = [GitLabMergeRequestDiscussion(id: "selected", notes: []),
                       .init(id: "selected", notes: []), .init(id: "selected", notes: [note(40)])]
        #expect(try context(threads).reply(to: draft) == nil)
    }

    @Test func stoppedFollowUpQuotesOnlyItsExplicitCurrentAccountScope() throws {
        var job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: 7, iid: 11), username: "me", workspace: "", access: .gitLabRead),
            title: "Follow-up", prompt: "", createdAt: Date(), allowsPush: false, feedbackNoteIDs: [42],
            execution: .init(state: .blocked), mergeRequestURL: target.url, workflow: .followUp, expectedHeadSHA: "abc")
        #expect(try context().followUp(job).map(\.id) == [42])
        job.feedbackNoteIDs = [999]
        #expect(try context().followUp(job).isEmpty)
        job.feedbackNoteIDs = [42]
        job.expectedHeadSHA = "old"
        #expect(try context().followUp(job).isEmpty)
    }
}
