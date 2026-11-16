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

    @Test func aCommandArgumentIsOptionalForOlderReceipts() throws {
        let legacy = try JSONDecoder().decode(RemoteCommand.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hostSession":"6F9619FF-8B86-D011-B42D-00C04FC964FE","account":"a","cardID":"c","actionID":"x","token":"t"}"#.utf8))
        #expect(legacy.argument == nil)
    }
}
