import Foundation
import Testing
@testable import GitLabTodos

@Suite struct ReviewVerdictTests {
    private let head = "0123456789012345678901234567890123456789"
    private let reviewer = 3

    @Test func discussionFingerprintMatchesTheAuthorHelperUnicodeFixture() throws {
        let value = try discussions([(40, 8, "Zażółć gęślą jaźń 🧵\nCheck this")])
        #expect(ReviewVerdict.fingerprint(value) == "820aa6b58b9b1848a9f2c75f526a2057b5cf98f1f7b52acae2bbead69a588a4a")
    }

    private func discussions(_ notes: [(id: Int, author: Int, body: String)]) throws -> [GitLabMergeRequestDiscussion] {
        let json = notes.map { ["notes": [["id": $0.id, "author": ["id": $0.author,
            "username": $0.author == reviewer ? "reviewer" : "author"], "system": false, "body": $0.body]]] }
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

    @Test func reviewWithFindingsCompletesTheActionWithoutAllowingApproval() throws {
        let original = try discussions([(10, 7, "Please rename this")])
        let recorded = ReviewVerdict(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2,
            headSHA: head, verdict: .objections, discussionFingerprint: ReviewVerdict.fingerprint(original))
        let published = try discussions([(10, 7, "Please rename this"), (20, reviewer, "Add a regression test")])
        let seen: Set = [AICommentAssessmentStore.digest("Add a regression test")]

        #expect(recorded.covers(head: head, discussions: published, reviewerID: reviewer, publishedDrafts: seen))
        #expect(!recorded.approves(head: head, discussions: published, reviewerID: reviewer, publishedDrafts: seen))
        #expect(!recorded.covers(head: String(repeating: "b", count: 40), discussions: original))
        #expect(!recorded.covers(head: head, discussions: try discussions([(10, 7, "An edited request")])))
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

    @Test func accountBoundVerdictsCannotBeReusedByAnotherAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var recorded = verdict(for: [])
        recorded.username = "reviewer"
        recorded.userID = reviewer
        recorded.runID = UUID()
        let path = ReviewVerdictStore.fileURL(host: recorded.host, projectID: 1, iid: 2, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recorded).write(to: path)

        #expect(ReviewVerdictStore.verdict(host: recorded.host, projectID: 1, iid: 2,
            user: .init(id: reviewer, username: "reviewer"), in: directory) == recorded)
        #expect(ReviewVerdictStore.verdict(host: recorded.host, projectID: 1, iid: 2,
            user: .init(id: 9, username: "other"), in: directory) == nil)
        #expect(ReviewVerdictStore.verdict(host: recorded.host, projectID: 1, iid: 2,
            user: .init(id: 9, username: "reviewer"), in: directory) == nil)
    }

    @Test func unscopedLegacyVerdictsRemainReadableWithoutAuthorizingAnAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorded = verdict(for: [])
        let path = ReviewVerdictStore.fileURL(host: recorded.host, projectID: 1, iid: 2, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recorded).write(to: path)

        #expect(ReviewVerdictStore.verdict(host: recorded.host, projectID: 1, iid: 2, in: directory) == recorded)
        #expect(ReviewVerdictStore.verdict(host: recorded.host, projectID: 1, iid: 2,
            user: .init(id: reviewer, username: "reviewer"), in: directory) == nil)
    }

    @MainActor @Test func automaticApprovalIgnoresUnsignedDraftHistoryButAcceptsExactConfirmedPublications() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = GitLabAuthenticatedUser(id: reviewer, username: "reviewer")
        var recorded = verdict(for: [])
        recorded.username = user.username; recorded.userID = user.id; recorded.runID = UUID()
        let draft = GitLabDraftNote(id: 5, authorID: user.id, note: "Checked reply", discussionID: "thread", position: nil)
        let published = [GitLabMergeRequestDiscussion(id: "thread", notes: [.init(id: 20,
            author: .init(id: user.id, username: user.username, name: nil), system: false,
            resolvable: false, resolved: nil, resolvedBy: nil, body: draft.note)])]
        ReviewVerdictStore.rememberDrafts([draft], host: recorded.host, projectID: 1, iid: 2, in: directory)
        #expect(recorded.approves(head: head, discussions: published, reviewerID: user.id,
            publishedDrafts: ReviewVerdictStore.seenDrafts(host: recorded.host, projectID: 1, iid: 2, in: directory)))
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: published, user: user, in: directory))
        let capture = try #require(ReviewVerdictStore.capturePublication([draft], verdict: recorded,
            before: [], reviewedDrafts: [draft], user: user, in: directory))
        let later = GitLabDraftNote(id: 6, authorID: user.id, note: draft.note, discussionID: draft.discussionID, position: nil)
        #expect(ReviewVerdictStore.capturePublication([later], verdict: recorded, before: [],
            reviewedDrafts: [draft], user: user, in: directory) == nil)
        let edited = GitLabDraftNote(id: draft.id, authorID: user.id, note: "New concern", discussionID: draft.discussionID, position: nil)
        #expect(ReviewVerdictStore.capturePublication([edited], verdict: recorded, before: [],
            reviewedDrafts: [draft], user: user, in: directory) == nil)
        #expect(ReviewVerdictStore.capturePublication([draft], verdict: recorded, before: [],
            reviewedDrafts: [], user: user, in: directory) == nil)
        try ReviewVerdictStore.recordPublication(capture, after: published, user: user, in: directory)
        #expect(ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: published, user: user, in: directory))
        let incoming = published + (try discussions([(21, reviewer, "A new objection")]))
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: incoming, user: user, in: directory))
        var otherRun = recorded; otherRun.runID = UUID()
        #expect(!ReviewVerdictStore.automaticallyApproves(otherRun, head: head, discussions: published, user: user, in: directory))
        let path = ReviewVerdictStore.fileURL(host: recorded.host, projectID: 1, iid: 2, in: directory)
            .deletingPathExtension().appendingPathExtension("published.json")
        let bytes = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: bytes)
        var envelope = try #require(object as? [String: Any])
        envelope["payload"] = Data("worker substituted normalization".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: path)
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: published, user: user, in: directory))
    }

    @MainActor @Test func publicationCannotNormalizeConcurrentEditsOrAnUnrelatedNewOwnComment() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = GitLabAuthenticatedUser(id: reviewer, username: "reviewer")
        let before = try discussions([(10, 7, "Reviewed text")])
        var recorded = verdict(for: before)
        recorded.username = user.username; recorded.userID = user.id; recorded.runID = UUID()
        let draft = GitLabDraftNote(id: 5, authorID: user.id, note: "Checked reply", discussionID: nil, position: nil)
        let capture = try #require(ReviewVerdictStore.capturePublication([draft], verdict: recorded,
            before: before, reviewedDrafts: [draft], user: user, in: directory))
        let after = try discussions([(10, 7, "Edited expectation"), (20, reviewer, "Checked reply")])
        try ReviewVerdictStore.recordPublication(capture, after: after, user: user, in: directory)
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: after, user: user, in: directory))
        let withUnrelated = try discussions([(10, 7, "Reviewed text"), (20, reviewer, "Checked reply"), (21, reviewer, "Block this MR")])
        try ReviewVerdictStore.recordPublication(capture, after: withUnrelated, user: user, in: directory)
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: withUnrelated, user: user, in: directory))
    }

    @MainActor @Test func publishingReviewedFindingsPreservesCompletionWithoutAuthorizingApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = GitLabAuthenticatedUser(id: reviewer, username: "reviewer")
        let recorded = ReviewVerdict(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2,
            headSHA: head, verdict: .objections, discussionFingerprint: ReviewVerdict.fingerprint([]),
            username: user.username, userID: user.id, runID: UUID())
        let draft = GitLabDraftNote(id: 5, authorID: user.id, note: "Reviewed finding", discussionID: nil, position: nil)
        let capture = try #require(ReviewVerdictStore.capturePublication([draft], verdict: recorded,
            before: [], reviewedDrafts: [draft], user: user, in: directory))
        let after = try discussions([(20, reviewer, "Reviewed finding")])
        try ReviewVerdictStore.recordPublication(capture, after: after, user: user, in: directory)
        #expect(ReviewVerdictStore.contentMatches(recorded, head: head, discussions: after, user: user, in: directory))
        #expect(!ReviewVerdictStore.automaticallyApproves(recorded, head: head, discussions: after, user: user, in: directory))
    }
}
