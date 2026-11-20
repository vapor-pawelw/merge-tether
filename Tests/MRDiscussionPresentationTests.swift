import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct MRDiscussionPresentationTests {
    @Test func preparedFingerprintTracksLoadedTextAndReadableFailures() async throws {
        var live = try threads()
        var fails = false
        let store = MRDiscussionStore(load: { _ in
            if fails { throw GlabError.notAuthenticated }
            return live
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        let original = try #require(store.discussionFingerprint)
        #expect(original == ReviewVerdict.fingerprint(live))
        live = try threads("Edited comment")
        await store.refresh(target: target, glab: glab)
        let edited = try #require(store.discussionFingerprint)
        #expect(edited == ReviewVerdict.fingerprint(live) && edited != original)
        fails = true
        await store.refresh(target: target, glab: glab)
        #expect(store.hasError && store.hasLoaded && store.discussionFingerprint == edited)
        store.clear()
        #expect(store.discussionFingerprint == nil)
    }

    @Test func preparedCitationsFollowHeadTextErrorsAndAccountEpoch() async throws {
        var live = try threads()
        var fails = false
        let store = MRDiscussionStore(load: { _ in
            if fails { throw GlabError.notAuthenticated }
            return live
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        var request = try presentationRequest()
        let original = try #require(store.discussionFingerprint)
        let status = AuthorFeedbackStatus(head: "abc", fingerprint: original,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete)
        let finding = AuthorFeedbackPolicy.Finding(id: 3, discussionID: "thread", reviewerID: 7,
            reviewerUsername: "alice", state: .needsChanges, reason: "Requirement", waitingForReviewers: [], sourceNoteID: 3)
        func context() -> MRCommentCitation.Context? {
            store.citationContext(target: target, request: request, accountRevision: glab.accountRevision)
        }
        #expect(context()?.finding(finding, status: status)?.note.body == "Published comment")
        request = try presentationRequest(head: "changed")
        #expect(context()?.finding(finding, status: status) == nil)
        request = try presentationRequest(description: "Changed context")
        #expect(context()?.finding(finding, status: status) == nil)
        request = try presentationRequest()
        #expect(context()?.finding(finding, status: status)?.id == 3)
        live = try threads("Edited comment")
        await store.refresh(target: target, glab: glab)
        #expect(context()?.comment(3, fingerprint: original) == nil)
        #expect(context()?.comment(3, fingerprint: store.discussionFingerprint)?.note.body == "Edited comment")
        fails = true
        await store.refresh(target: target, glab: glab)
        #expect(context() == nil)
        fails = false
        await store.refresh(target: target, glab: glab)
        glab.currentUsername = "other"; glab.currentUsername = target.username
        #expect(!store.hasCurrentTarget(target, accountRevision: glab.accountRevision))
        #expect(context() == nil)
    }

    @Test func preparedSnapshotsFollowDraftsAssessmentAndAuthorKindChanges() async throws {
        let notes = try threads() + [.init(id: "reply", notes: [
            .init(id: 4, author: .init(id: 9, username: "me", name: "Me"), system: false,
                resolvable: false, resolved: false, resolvedBy: nil, body: "Published answer")])]
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        let pending = ReReviewAssessment(notes: [.init(noteID: 3, state: .blocking, reason: "Required")])
        let addressed = ReReviewAssessment(notes: [.init(noteID: 3, state: .addressed, reason: "Answered", publishedReplyNoteID: 4)])
        func snapshot(_ drafts: [GitLabDraftNote] = [], _ assessment: ReReviewAssessment? = nil) -> MRDiscussionSnapshot {
            store.presentationSnapshot(target: target, accountRevision: glab.accountRevision,
                drafts: drafts, assessment: assessment, authorID: 9)
        }
        #expect(snapshot([], pending).threads.first?.feedback == .pending)
        let draft = GitLabDraftNote(id: 10, authorID: 9, note: "Private reply", discussionID: "thread", position: nil)
        #expect(snapshot([draft], pending).threads.first?.drafts.map(\.id) == [10])
        let completed = try #require(snapshot([], addressed).threads.first)
        #expect(completed.feedback == .addressed && completed.verifiedReplyAuthors == ["me"])
        #expect(completed.drafts.isEmpty)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .automation, host: target.host,
            username: target.username, accountRevision: glab.accountRevision)
        #expect(snapshot([], addressed).threads.first?.origins[3] == .botAccount)
        glab.currentUsername = "other"; glab.currentUsername = target.username
        #expect(snapshot([], addressed).threads.isEmpty)
        store.clear()
        #expect(snapshot().threads.isEmpty)
    }

    private let target = MRDiscussionTarget(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2,
        url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
    private func glab() -> GlabService {
        let glab = GlabService()
        glab.resolvedHost = target.host; glab.currentUsername = target.username
        return glab
    }
    private func threads(_ body: String = "Published comment") throws -> [GitLabMergeRequestDiscussion] {
        [.init(id: "thread", notes: [
            .init(id: 3, author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: body)
        ])]
    }
    private func presentationRequest(head: String = "abc", description: String? = nil) throws -> GitLabMergeRequest {
        var json: [String: Any] = ["project_id": 1, "iid": 2, "title": "Example",
            "author": ["id": 9, "username": "me", "name": "Me"], "web_url": target.url.absoluteString,
            "state": "opened", "sha": head, "source_branch": "feature", "target_branch": "main", "labels": []]
        json["description"] = description
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@MainActor
struct MRDiscussionMarkdownCacheTests {
    @Test func rendersHeadingsAndParagraphsInCommentBodies() {
        let rendered = MRDiscussionMarkdownCache().render("# Feedback\n\nPlease update **this**.")

        #expect(rendered.map { String($0.characters) } == "Feedback\n\nPlease update this.")
    }

    @Test func reusesSanitizedMarkdownUntilItsExactSourceChanges() {
        var calls = 0
        let cache = MRDiscussionMarkdownCache(render: { source in
            calls += 1
            return SafeMarkdown.render(source)
        })
        let source = "**Feedback** [unsafe](file:///private/local) ![image](https://example.test/image.png)"
        let rendered = cache.render(source)
        #expect(cache.render(source) == rendered && calls == 1)
        #expect(rendered?.runs.allSatisfy { $0.link == nil && $0.imageURL == nil } == true)
        #expect(cache.render("Edited **feedback**").map { String($0.characters) } == "Edited feedback")
        #expect(calls == 2)
    }

    @Test func boundsRetainedBodiesAndEvictsTheLeastRecentlyUsedSource() {
        var calls = 0
        let cache = MRDiscussionMarkdownCache(capacity: 2, maximumSourceBytes: 12, render: { source in
            calls += 1
            return AttributedString(source)
        })
        _ = cache.render("first"); _ = cache.render("second"); _ = cache.render("first")
        #expect(calls == 2)
        _ = cache.render("third")
        #expect(calls == 3)
        _ = cache.render("first")
        #expect(calls == 3)
        _ = cache.render("second")
        #expect(calls == 4)
        let oversized = String(repeating: "x", count: 13)
        _ = cache.render(oversized); _ = cache.render(oversized)
        #expect(calls == 6)
    }

    @Test func byteDistinctUnicodeSourcesKeepTheirOwnRenderedText() {
        let cache = MRDiscussionMarkdownCache()
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        #expect(cache.render(composed).map { Array(String($0.characters).utf8) } == Array(composed.utf8))
        #expect(cache.render(decomposed).map { Array(String($0.characters).utf8) } == Array(decomposed.utf8))
    }
}
