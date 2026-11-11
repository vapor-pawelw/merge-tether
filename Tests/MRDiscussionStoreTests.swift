import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRDiscussionStoreTests {
    private final class Flag { var value = false }
    private let target = MRDiscussionTarget(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2,
        url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
    private func glab() -> GlabService {
        let glab = GlabService()
        glab.resolvedHost = target.host; glab.currentUsername = target.username
        return glab
    }
    private func threads(_ body: String = "Published comment") throws -> [GitLabMergeRequestDiscussion] {
        [GitLabMergeRequestDiscussion(id: "thread", notes: [
            .init(id: 3, author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: body)
        ])]
    }

    @Test func loadsFullDiscussionAndKeepsItClickableAfterRefreshFailure() async throws {
        struct Failure: Error {}
        let fail = Flag()
        let expected = try threads()
        let store = MRDiscussionStore(load: { _ in if fail.value { throw Failure() }; return expected },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.discussions.first?.notes.first?.body == "Published comment")
        #expect(store.hasLoaded && !store.hasError && !store.isLoading)
        fail.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.hasError && store.hasLoaded)
        #expect(store.discussions.first?.id == "thread")
    }

    @Test func anOldAccountCannotStartAReadOrExposeAnInflightResponse() async throws {
        var continuation: CheckedContinuation<[GitLabMergeRequestDiscussion], Never>?
        let store = MRDiscussionStore(load: { _ in await withCheckedContinuation { continuation = $0 } })
        let glab = glab()
        let task = Task { await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let resume = try #require(continuation)
        glab.currentUsername = "other"
        resume.resume(returning: try threads())
        await task.value
        #expect(store.discussions.isEmpty && store.target == nil)
        var reads = 0
        let another = MRDiscussionStore(load: { _ in reads += 1; return [] })
        await another.refresh(target: target, glab: glab)
        #expect(reads == 0 && another.discussions.isEmpty)
    }

    @Test func anOlderTargetResponseCannotOverwriteTheNewConversation() async throws {
        let newer = MRDiscussionTarget(host: target.host, username: target.username, projectID: 1, iid: 4,
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/4")!)
        var continuation: CheckedContinuation<[GitLabMergeRequestDiscussion], Never>?
        let current = try threads("Current conversation")
        let store = MRDiscussionStore(load: { request in
            if request.iid == 2 { return await withCheckedContinuation { continuation = $0 } }
            return current
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        let task = Task { await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let resume = try #require(continuation)
        await store.refresh(target: newer, glab: glab)
        resume.resume(returning: try threads("Stale conversation"))
        await task.value
        #expect(store.target == newer)
        #expect(store.discussions.first?.notes.first?.body == "Current conversation")
    }

    @Test func anAssistantUsernameAloneDoesNotProveAIOrigin() async throws {
        let notes = [GitLabMergeRequestDiscussion(id: "assistant", notes: [
            .init(id: 8, author: .init(id: 9, username: "GitLabDuo", name: "GitLab Duo"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: "AI finding")
        ])]
        let verified = Flag()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAssistant: { _, _ in verified.value },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[8] == nil)
        verified.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[8] == .verifiedAssistant)
    }

    @Test(arguments: [
        ("ai_assisted", "high", "ai"), ("ai_assisted", "very_high", "ai"),
        ("manual_likely", "high", "human"), ("manual_likely", "very_high", "human"),
        ("uncertain", "high", "uncertain"), ("uncertain", "uncertain", "uncertain"),
        ("ai_assisted", "uncertain", "uncertain"), ("manual_likely", "uncertain", "uncertain")
    ])
    func displaysOnlyTheRecordedClassificationWithoutChangingAIEligibility(classification: String, confidence: String, expected: String) async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads()
        let note = try #require(notes.first?.notes.first)
        let record = assessment(note: note, classification: classification, confidence: confidence)
        try save(record, in: directory)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: directory)
        // when
        await store.refresh(target: target, glab: glab())
        // then
        let origin = try #require(store.origins[3])
        switch expected {
        case "ai": #expect(origin == .assessed(evidence: record.evidence))
        case "human": #expect(origin == .humanLikely(evidence: record.evidence))
        default: #expect(origin == .uncertain(evidence: record.evidence))
        }
        #expect(AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: directory)
            == (classification == "ai_assisted" && confidence != "uncertain"))
    }

    @Test(arguments: ["body", "author", "account", "host", "project", "mr", "note", "criteria"])
    func staleOrMismatchedManualEvidenceNeverBecomesAHumanBadge(mismatch: String) async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads()
        let note = try #require(notes.first?.notes.first)
        let record = AICommentAssessment(version: 2, host: mismatch == "host" ? "other.example.test" : target.host,
            projectID: mismatch == "project" ? 9 : 1, iid: mismatch == "mr" ? 9 : 2, noteID: mismatch == "note" ? 9 : 3,
            bodySHA256: AICommentAssessmentStore.digest(mismatch == "body" ? "Edited" : note.body!), confidence: "high",
            evidence: "Spontaneous personal composition", classification: "manual_likely",
            criteriaVersion: mismatch == "criteria" ? AICommentOriginAssessor.criteriaVersion - 1 : AICommentOriginAssessor.criteriaVersion,
            username: mismatch == "account" ? "other" : target.username, authorID: mismatch == "author" ? 99 : note.author?.id)
        try save(record, in: directory)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: directory)
        // when
        await store.refresh(target: target, glab: glab())
        // then
        #expect(store.hasLoaded)
        #expect(store.origins.isEmpty)
    }

    private func assessment(note: GitLabMergeRequestDiscussion.Note, classification: String, confidence: String) -> AICommentAssessment {
        .init(version: 2, host: target.host, projectID: 1, iid: 2, noteID: 3,
              bodySHA256: AICommentAssessmentStore.digest(note.body!), confidence: confidence,
              evidence: "Recorded origin evidence", classification: classification,
              criteriaVersion: AICommentOriginAssessor.criteriaVersion, username: target.username, authorID: note.author?.id)
    }

    private func save(_ record: AICommentAssessment, in directory: URL) throws {
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 1, iid: 2, noteID: 3, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: path)
    }

    @Test func liveAccountMismatchClearsPreviouslyCachedDiscussion() async throws {
        let changedAccount = Flag()
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in
            if changedAccount.value { throw MRDiscussionStore.IdentityError.accountChanged }
            return notes
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(!store.discussions.isEmpty)
        changedAccount.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.discussions.isEmpty && store.origins.isEmpty)
        #expect(store.hasError && !store.hasLoaded)
    }

    @Test func expiredAuthenticationKeepsPreviouslyLoadedDiscussionReadable() async throws {
        let expired = Flag()
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in
            if expired.value { throw GlabError.notAuthenticated }
            return notes
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        expired.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.hasError && store.hasLoaded)
        #expect(store.discussions.first?.notes.first?.body == "Published comment")
    }
}
