import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ProposalMRContextTests {
    @MainActor private final class AccountBox {
        var value: ProposalAuthorLoader.Account
        init(_ value: ProposalAuthorLoader.Account) { self.value = value }
    }
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
    private let url = URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!
    private let mrAuthor = Todo.Author(id: 7, username: "alice", name: "Alice Author", avatarURL: nil)
    private let bot = Todo.Author(id: 99, username: "review-bot", name: "Review Bot", avatarURL: nil)

    private func todo(_ id: Int = 1, action: ActionName = .reviewRequested, author: Todo.Author? = nil) -> Todo {
        .init(id: id, actionName: action, targetType: .mergeRequest, targetURL: url, body: "Review this MR",
            createdAt: Date(timeIntervalSince1970: Double(id)), state: "pending",
            project: .init(id: 1, nameWithNamespace: "Group / Repo", pathWithNamespace: "group/repo"), author: bot,
            target: .init(id: 22, iid: 2, title: "Example MR", state: "opened", draft: false, workInProgress: false, author: author))
    }
    private func proposal(todos: [Todo] = [], item: MergeRequestAttentionMonitor.Item? = nil,
                          intents: [MRTodoIntent] = []) -> MergeRequestBoardSnapshot.Proposal {
        .init(target: target, title: "Example MR", url: url, item: item, todos: todos, intents: intents)
    }
    private func request(iid: Int = 2, authorID: Int = 7, username: String = "alice") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
            {"project_id":1,"iid":\(iid),"author":{"id":\(authorID),"username":"\(username)","name":"Author"},
             "title":"Example MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/\(iid)",
             "state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
             "source_branch":"feature","target_branch":"main","labels":[]}
            """.utf8))
    }

    @Test func eventActorNeverSubstitutesForMergeRequestAuthor() {
        let context = ProposalMRContext(proposal: proposal(todos: [todo(author: mrAuthor)]))
        #expect(context.author?.username == "alice")
        #expect(context.author?.id != bot.id)
        #expect(context.reasons == [.event(todo(author: mrAuthor))])
    }

    @Test func missingTargetAuthorStaysUnknownInsteadOfShowingTheReviewBot() {
        let context = ProposalMRContext(proposal: proposal(todos: [todo()]))
        #expect(context.author == nil)
        #expect(context.reasons.map(\.id) == ["event/review_requested/99"])
    }

    @Test func knownRequestAndIntentProvideTheActualAuthor() throws {
        let request = try request()
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: url, mergeRequest: request)
        let itemContext = ProposalMRContext(proposal: proposal(todos: [todo(author: bot)], item: item))
        #expect(itemContext.author?.username == "alice")
        let intent = MRTodoIntent(id: UUID(), target: target, kind: .review, state: .pending,
            todoIDs: [1], noteIDs: [], sourceEvents: [], request: request, headSHA: request.sha!, updatedAt: Date())
        let intentContext = ProposalMRContext(proposal: proposal(intents: [intent]))
        #expect(intentContext.author?.username == "alice")
        #expect(intentContext.reasons == [.intent(.review)])
    }

    @Test func readOnlyEnrichmentMustMatchTheExactProposal() throws {
        let unknown = proposal(todos: [todo()])
        #expect(ProposalMRContext(proposal: unknown, fetchedRequest: try request()).author?.username == "alice")
        #expect(ProposalMRContext(proposal: unknown, fetchedRequest: try request(iid: 3)).author == nil)
    }

    @Test func repeatedEventsGroupByReasonAndKeepDistinctCauses() {
        let context = ProposalMRContext(proposal: proposal(todos: [todo(), todo(2), todo(3, action: .buildFailed)]))
        #expect(context.reasons.map(\.id) == ["event/build_failed/99", "event/review_requested/99"])
    }

    @Test func missingReasonHasAnHonestUnmanagedFallback() {
        #expect(ProposalMRContext(proposal: proposal()).reasons == [.unmanaged])
    }

    @Test func authorLookupIsReadOnlyAndSkipsAlreadyKnownAuthors() async throws {
        var reads = 0
        let loader = ProposalAuthorLoader(fetch: { _ in reads += 1; return try request() }, currentAccount: {
            .init(host: target.host, username: target.username)
        })
        await loader.load(proposal(todos: [todo(author: mrAuthor)]))
        #expect(reads == 0)
        let unknown = proposal(todos: [todo()])
        await loader.load(unknown)
        #expect(reads == 1)
        #expect(loader.request(for: unknown)?.author.username == "alice")
        await loader.load(unknown)
        #expect(reads == 1)
    }

    @Test func changedAccountCannotReadCachedAuthorOrStartAnOldAccountsLookup() async throws {
        let account = AccountBox(.init(host: target.host, username: target.username))
        var reads = 0
        let loader = ProposalAuthorLoader(fetch: { _ in reads += 1; return try request() }, currentAccount: { account.value })
        let unknown = proposal(todos: [todo()])
        await loader.load(unknown)
        account.value = .init(host: target.host, username: "another-account")
        #expect(loader.request(for: unknown) == nil)
        await loader.load(unknown)
        #expect(reads == 1)
    }

    @Test func oldTargetResponseCannotReplaceANewerProposal() async throws {
        let first = proposal(todos: [todo()])
        let secondRequest = try request(iid: 3, authorID: 8, username: "bob")
        let second = MergeRequestBoardSnapshot.Proposal(target: .init(host: target.host, username: target.username, projectID: 1, iid: 3),
            title: "Second MR", url: secondRequest.webURL, item: nil, todos: [], intents: [])
        var started = false
        var completion: CheckedContinuation<GitLabMergeRequest, Never>?
        let loader = ProposalAuthorLoader(fetch: { target in
            if target.iid == 3 { return secondRequest }
            started = true
            return await withCheckedContinuation { completion = $0 }
        }, currentAccount: { .init(host: target.host, username: target.username) })
        let stale = Task { await loader.load(first) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !started, ContinuousClock.now < deadline { await Task.yield() }
        guard let completion else { stale.cancel(); Issue.record("Author lookup never started"); return }
        await loader.load(second)
        completion.resume(returning: try request())
        await stale.value
        #expect(loader.request(for: first) == nil)
        #expect(loader.request(for: second)?.author.username == "bob")
    }
}
