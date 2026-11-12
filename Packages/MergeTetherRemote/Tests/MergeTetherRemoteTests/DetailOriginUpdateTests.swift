import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct DetailOriginUpdateTests {
    private let date = Date(timeIntervalSince1970: 100)

    private func board() -> RemoteBoard {
        .init(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [
            .init(id: "mr:1:2", title: "MR", project: "g/p", url: nil, head: "source-head", contextRevision: "source-target")
        ])])
    }

    private func details() -> RemoteMRDetails {
        .init(checkedAt: date, description: "Original description", threads: [
            .init(id: "thread", state: .open, notes: [
                .init(id: "1", author: "Reviewer", body: "Root body", authorID: 7),
                .init(id: "2", author: "Owner", body: "Reply body", authorID: 9)
            ], reply: .published, draftCount: 1, feedback: .addressed)
        ])
    }

    private func update(_ request: RemoteDetailRequest, details: RemoteMRDetails,
                        origin: RemoteDetailNote.Origin = .ai) throws -> RemoteDetailOrigins {
        let thread = try #require(details.threads?.first)
        return .init(request: request, changes: try thread.notes.map { note in
            let identity = try #require(note.originIdentity(in: thread.id))
            return .init(threadID: thread.id, noteID: note.id, identity: identity, origin: origin)
        })
    }

    @Test func metadataUpdatesRootReplyAndAggregateWithoutReplacingOtherDetailsOrRenewingActionLease() throws {
        let board = board(), state = RemoteDetailState(), initial = details()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        state.receive(.init(request: request, status: .current, details: initial), board: board)
        let update = try update(request, details: initial)
        #expect(state.receiveOrigins(update, board: board))
        let changed = try #require(state.details(for: board.cards[0], board: board))
        #expect(changed.threads?.first?.notes.map(\.origin) == [.ai, .ai])
        #expect(changed.threads?.first?.origin == .ai)
        #expect(changed.description == initial.description && changed.checkedAt == initial.checkedAt)
        #expect(changed.threads?.first?.reply == .published && changed.threads?.first?.draftCount == 1)
        #expect(changed.threads?.first?.feedback == .addressed && state.pending == nil)
        let phone = RemotePhoneState()
        let challenge = phone.challenge(now: date)
        #expect(phone.receive(.init(type: .snapshot, challenge: challenge, board: board), now: date))
        let expired = date.addingTimeInterval(46)
        #expect(!phone.receive(.init(type: .details, detailOrigins: update), now: expired))
        #expect(!phone.canAct(now: expired))
    }

    @Test(arguments: ["close", "disconnect", "replace", "account", "session", "head", "request", "body", "author", "thread", "duplicate"])
    func staleOrMismatchedMetadataCannotRepaintACachedConversation(_ mismatch: String) throws {
        var board = board()
        let state = RemoteDetailState(), initial = details()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        state.receive(.init(request: request, status: .current, details: initial), board: board)
        var candidate = initial
        if mismatch == "body" { candidate.threads?[0].notes[0].body = "Edited root" }
        if mismatch == "author" {
            candidate.threads?[0].notes[0] = .init(id: "1", author: "Other", body: "Root body", authorID: 99)
        }
        if mismatch == "thread" {
            candidate.threads = [.init(id: "other-thread", state: .open, notes: initial.threads![0].notes)]
        }
        var payload = try update(request, details: candidate)
        switch mismatch {
        case "close", "disconnect": state.disconnect()
        case "replace": _ = state.begin(card: board.cards[0], board: board, now: date, force: true)
        case "account": board = .init(hostSession: board.hostSession, account: "other@host", lanes: board.lanes)
        case "session": board = .init(hostSession: UUID(), account: board.account, lanes: board.lanes)
        case "head": board.lanes[0].cards[0].head = "new-head"
        case "request":
            let other = try RemoteDetailRequest(card: board.cards[0], board: board)
            payload = .init(request: other, changes: payload.changes)
        case "duplicate": payload = .init(request: request, changes: payload.changes + payload.changes)
        default: break
        }
        #expect(!state.receiveOrigins(payload, board: board))
        #expect(state.response?.details == initial)
    }

    @Test func originsRemainIndependentAndAdditiveMetadataSurvivesTheExistingDetailsEnvelope() throws {
        let board = board(), state = RemoteDetailState(), initial = details()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        state.receive(.init(request: request, status: .current, details: initial), board: board)
        let updates = try update(request, details: initial, origin: .uncertain)
        let message = RemoteMessage(type: .details, detailOrigins: updates)
        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.type == .details && decoded.detailResponse == nil && decoded.detailOrigins == updates)
        #expect(state.receiveOrigins(updates, board: board))
        #expect(state.response?.details?.threads?.first?.origin == .uncertain)
        let first = try #require(updates.changes.first)
        let human = RemoteDetailOrigins(request: request, changes: [.init(threadID: first.threadID,
            noteID: first.noteID, identity: first.identity, origin: .human, revision: 2)])
        #expect(state.receiveOrigins(human, board: board))
        #expect(state.response?.details?.threads?.first?.origin == nil)
    }

    @Test func closingAndReopeningTheSameCardCreatesANewSubscriptionAndLateOriginsStayRejected() throws {
        let board = board(), state = RemoteDetailState(), initial = details()
        let first = try #require(state.begin(card: board.cards[0], board: board, now: date))
        state.receive(.init(request: first, status: .current, details: initial), board: board)
        state.disconnect()
        let reopened = try #require(state.begin(card: board.cards[0], board: board, now: date))
        #expect(reopened != first && state.openRequest == reopened)
        state.receive(.init(request: reopened, status: .current, details: initial), board: board)
        let old = try update(first, details: initial)
        #expect(!state.receiveOrigins(old, board: board))
        let current = try update(reopened, details: initial)
        #expect(state.receiveOrigins(current, board: board))
    }

    @Test func newerPerMessageOriginsSurviveOutOfOrderUpdatesWhileOtherFreshMessagesStillUpdate() throws {
        let board = board(), state = RemoteDetailState(), initial = details()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        state.receive(.init(request: request, status: .current, details: initial), board: board)
        let old = try update(request, details: initial, origin: .uncertain)
        let first = try #require(old.changes.first)
        let newer = RemoteDetailOrigins(request: request, changes: [.init(threadID: first.threadID,
            noteID: first.noteID, identity: first.identity, origin: .ai, revision: 2)])
        #expect(state.receiveOrigins(newer, board: board))
        #expect(state.receiveOrigins(old, board: board))
        #expect(state.response?.details?.threads?.first?.notes.map(\.origin) == [.ai, .uncertain])
        #expect(!state.receiveOrigins(old, board: board))
    }
}
