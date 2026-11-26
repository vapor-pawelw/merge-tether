import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CommentOriginRequestTests {
    @Test func aThreadRequestNamesEveryDisplayedNoteAndRoundTrips() throws {
        let notes = [RemoteDetailNote(id: "11", body: "First", origin: .uncertain, authorID: 7),
                     RemoteDetailNote(id: "12", body: "Reply", origin: .ai, authorID: 8)]
        let request = try #require(RemoteCommentOriginRequest.set(.human, notes: notes, in: "discussion/abc"))
        #expect(request.notes.map(\.noteID) == ["11", "12"])
        #expect(request.notes.first?.identity == notes[0].originIdentity(in: "discussion/abc"))
        #expect(RemoteCommentOriginRequest(argument: request.argument) == request)
        let automatic = try #require(RemoteCommentOriginRequest.set(nil, notes: [notes[0]], in: "discussion/abc"))
        #expect(RemoteCommentOriginRequest(argument: automatic.argument)?.origin == nil)
    }

    @Test func notesWithoutAStableIdentityCannotBeChanged() {
        let unidentified = RemoteDetailNote(id: "unidentified/0", body: "Body", authorID: 7)
        #expect(RemoteCommentOriginRequest.set(.ai, notes: [unidentified], in: "discussion/abc") == nil)
        #expect(RemoteCommentOriginRequest(argument: "not json") == nil)
        let tooMany = RemoteCommentOriginRequest(operation: .set, origin: .ai, notes: Array(repeating:
            .init(threadID: "discussion/abc", noteID: "1", identity: "x"), count: RemoteCommentOriginRequest.maximumNotes + 1))
        #expect(RemoteCommentOriginRequest(argument: tooMany.argument) == nil)
    }

    @Test func olderPhonesNeverReceiveTheOriginAction() throws {
        let board = RemoteBoard(hostSession: UUID(), account: "me@gitlab.example.org", lanes: [.init(id: .own, cards: [
            .init(id: "mr:1:2", title: "Fix", project: "demo", url: nil, actions: [
                .init(id: "commentOrigin", kind: .setCommentOrigin, token: "t"), .init(id: "approve", kind: .approve, token: "a")]),
        ])])
        #expect(board.forClient(supportsCommentReview: true, supportsMRControls: true).cards.first?.actions.map(\.kind) == [.approve])
        #expect(board.forClient(supportsCommentReview: true, supportsCommentOrigins: true).cards.first?.actions.count == 2)
    }

    @MainActor @Test(arguments: [RemoteActionKind.confirmAIReply, .markReplyHuman])
    func draftOriginDecisionRoundTripsAndRequiresTheCurrentToken(_ kind: RemoteActionKind) async throws {
        struct LegacyDraft: Decodable { let id: Int; let body: String }
        let source = RemoteAIReplyDecision(id: 7, authorLabel: "reviewer",
            reply: .init(id: "confirmAIReply:12:7", kind: .confirmAIReply, token: "reply-token"),
            human: .init(id: "markReplyHuman:12:7", kind: .markReplyHuman, token: "human-token"))
        let draft = RemoteDraft(id: 12, body: "Fixed", aiReplyDecisions: [source])
        let encoded = try JSONEncoder().encode(draft)
        #expect(try JSONDecoder().decode(LegacyDraft.self, from: encoded).body == "Fixed")
        #expect(try JSONDecoder().decode(RemoteDraft.self, from: encoded) == draft)
        #expect(try JSONDecoder().decode(RemoteDraft.self,
            from: Data(#"{"id":12,"body":"Fixed"}"#.utf8)).aiReplyDecisions == nil)

        let card = RemoteCard(id: "mr:1:2", title: "Fix", project: "demo", url: nil, drafts: [draft])
        let board = RemoteBoard(hostSession: UUID(), account: "me@gitlab.example.org", lanes: [.init(id: .own, cards: [card])])
        let action = kind == .confirmAIReply ? source.reply : source.human
        let gate = RemoteCommandGate(store: nil), pairing = UUID()
        let phone = RemotePhoneState()
        let now = Date(timeIntervalSince1970: 100)
        let challenge = try #require(phone.beginRefresh(now: now))
        #expect(phone.receive(.init(type: .snapshot, challenge: challenge, board: board), now: now))
        let command = try #require(phone.command(card: card, action: action, now: now))
        let wire = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(RemoteCommand.self, from: wire)
        let result = await gate.execute(decoded, board: board, pairingSession: pairing) { card, action in
            #expect(card.drafts == [draft])
            #expect(action.kind == kind)
            return .completed
        }
        #expect(result.status == .completed)
        #expect(phone.receive(.init(type: .result, result: result), now: now))
        #expect(phone.result?.status == .completed)

        let stale = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: card.id,
            actionID: action.id, token: "old-token")
        let refused = await gate.execute(stale, board: board, pairingSession: pairing) { _, _ in
            Issue.record("A stale origin decision reached the host")
            return .failed
        }
        #expect(refused.status == .changed)
    }

    @Test func aCommandArgumentIsOptionalForOlderReceipts() throws {
        let legacy = try JSONDecoder().decode(RemoteCommand.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hostSession":"6F9619FF-8B86-D011-B42D-00C04FC964FE","account":"a","cardID":"c","actionID":"x","token":"t"}"#.utf8))
        #expect(legacy.argument == nil)
    }
}
