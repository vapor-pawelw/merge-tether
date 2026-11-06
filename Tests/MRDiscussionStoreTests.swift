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
