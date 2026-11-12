import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor struct RemoteDetailOriginSubscriptionTests {
    private func fixture() throws -> (GitLabMergeRequest, RemoteDetailRequest, RemoteMRDetails) {
        let source = try MRDependencyPresentationTests().request(2, project: 1, author: 9)
        let board = RemoteBoard(hostSession: UUID(), account: "me@gitlab.example.test", lanes: [.init(id: .own, cards: [
            .init(id: "mr:1:2", title: "MR", project: "g/p", url: source.webURL, head: source.sha)
        ])])
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        let full = RemoteMRDetails(checkedAt: .now, threads: [.init(id: "thread", state: .open, notes: [
            .init(id: "1", body: "A complete root body beyond the rendered prefix", authorID: 7),
            .init(id: "2", body: "A complete reply", authorID: 9)
        ])])
        return (source, request, full)
    }

    private func event(_ source: GitLabMergeRequest, body: String = "A complete root body beyond the rendered prefix",
                       author: Int = 7, revision: UInt64 = 1,
                       classification: AICommentOriginAssessment.Classification = .aiAssisted) -> AICommentDisplayCoordinator.PersistedOrigins {
        .init(target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            request: source, accountRevision: 10, origins: [.init(noteID: 1, authorID: author,
                bodySHA256: AICommentAssessmentStore.digest(body), classification: classification, confidence: .high, revision: revision)])
    }

    @Test func completionDuringInitialDeliveryIsBufferedAndUsesFullSourceButRenderedIdentity() throws {
        let (source, request, full) = try fixture()
        var rendered = full
        rendered.threads?[0].notes[0].body = "A complete root"
        let subscription = RemoteDetailOriginSubscription(request: request, source: source, accountRevision: 10)
        #expect(subscription.record(event(source)))
        #expect(subscription.nextUpdate() == nil)
        subscription.delivered(full: full, rendered: rendered)
        let update = try #require(subscription.nextUpdate())
        let note = try #require(rendered.threads?.first?.notes.first)
        #expect(update.request == request && update.changes.count == 1)
        #expect(update.changes[0].identity == note.originIdentity(in: "thread"))
        #expect(update.changes[0].origin == .ai)
        subscription.recordSent(update)
        #expect(subscription.nextUpdate() == nil)
    }

    @Test(arguments: ["body", "author", "account", "revision", "head"])
    func mismatchedSourceCannotAnnotateAnUnchangedRenderedPrefix(_ mismatch: String) throws {
        let (source, request, full) = try fixture()
        let subscription = RemoteDetailOriginSubscription(request: request, source: source, accountRevision: 10)
        subscription.delivered(full: full, rendered: full)
        var value = event(source, body: mismatch == "body" ? "A complete root body with an edited hidden suffix" : full.threads![0].notes[0].body,
                          author: mismatch == "author" ? 99 : 7)
        if mismatch == "account" || mismatch == "revision" {
            value = .init(target: .init(host: "gitlab.example.test", username: mismatch == "account" ? "other" : "me", projectID: 1, iid: 2),
                request: source, accountRevision: mismatch == "revision" ? 11 : 10, origins: value.origins)
        }
        if mismatch == "head" {
            let data = try JSONEncoder().encode(source)
            let object = try JSONSerialization.jsonObject(with: data)
            var fields = try #require(object as? [String: Any])
            fields["sha"] = String(repeating: "b", count: 40)
            let changed = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
            value = .init(target: value.target, request: changed, accountRevision: 10, origins: value.origins)
        }
        _ = subscription.record(value)
        #expect(subscription.nextUpdate() == nil)
    }

    @Test func anOlderInflightSendCannotClearOrOverwriteANewerCompletion() throws {
        let (source, request, full) = try fixture()
        let subscription = RemoteDetailOriginSubscription(request: request, source: source, accountRevision: 10)
        subscription.delivered(full: full, rendered: full)
        let old = event(source, classification: .uncertain)
        #expect(subscription.record(old))
        let inflight = try #require(subscription.nextUpdate())
        #expect(subscription.record(event(source, revision: 2)))
        subscription.recordSent(inflight)
        let next = try #require(subscription.nextUpdate())
        #expect(next.changes[0].revision == 2 && next.changes[0].origin == .ai)
        subscription.recordSent(next)
        #expect(!subscription.record(old))
        #expect(subscription.nextUpdate() == nil)
    }
}
