import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct RemoteDetailsTests {
    private let date = Date(timeIntervalSince1970: 100)
    private func board() -> RemoteBoard {
        .init(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [
            .init(id: "mr:1:2", title: "Feature", project: "g/p", url: nil, head: "a", contextRevision: "source-target-text")
        ])])
    }

    @MainActor @Test func detailsAreReadOnlyAndCanLoadWithoutAnyWriteAction() throws {
        let board = board(), state = RemoteDetailState()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        let response = RemoteDetailResponse(request: request, status: .current,
            details: .init(checkedAt: date, metadata: [.init(label: "Source", value: "feature")]))
        state.receive(response, board: board)
        #expect(state.details(for: board.cards[0], board: board)?.metadata.first?.value == "feature")
        #expect(board.cards[0].actions.isEmpty)
        #expect(state.pending == nil)
    }

    @MainActor @Test(arguments: ["account", "session", "head", "target", "card"])
    func lateDetailsCannotCrossTheirDisplayedContext(_ change: String) throws {
        var board = board()
        let state = RemoteDetailState(), original = board.cards[0]
        let request = try #require(state.begin(card: original, board: board, now: date))
        switch change {
        case "account": board.account = "other@host"
        case "session": board.hostSession = UUID()
        case "head": board.lanes[0].cards[0].head = "b"
        case "target": board.lanes[0].cards[0].contextRevision = "changed-target"
        case "card": board.lanes[0].cards[0].id = "mr:1:3"
        default: break
        }
        state.receive(.init(request: request, status: .current, details: .init(checkedAt: date)), board: board)
        #expect(state.details(for: board.cards[0], board: board) == nil)
    }

    @MainActor @Test func replacingTheRequestRejectsTheEarlierReplyAndDisconnectKeepsOnlyMatchingCachedData() throws {
        let board = board(), state = RemoteDetailState(), card = board.cards[0]
        let first = try #require(state.begin(card: card, board: board, now: date))
        let current = try #require(state.begin(card: card, board: board, now: date, force: true))
        state.receive(.init(request: first, status: .current, details: .init(checkedAt: date)), board: board)
        #expect(state.details(for: card, board: board) == nil)
        state.receive(.init(request: current, status: .current, details: .init(checkedAt: date)), board: board)
        state.disconnect()
        #expect(state.details(for: card, board: board) != nil)
        var changed = board; changed.account = "other@host"
        state.update(board: changed)
        #expect(state.details(for: card, board: changed) == nil)
    }

    @MainActor @Test func timeoutAndPartialReadNeverGrantCommandReadiness() throws {
        let board = board(), state = RemoteDetailState()
        let request = try #require(state.begin(card: board.cards[0], board: board, now: date))
        #expect(state.isLoading(now: date))
        #expect(!state.isLoading(now: date.addingTimeInterval(46)))
        state.receive(.init(request: request, status: .unavailable), board: board)
        #expect(state.failure == .unavailable)
        #expect(state.details(for: board.cards[0], board: board) == nil)
        let phone = RemotePhoneState()
        let challenge = phone.challenge(now: date)
        var partial = board; partial.partial = true
        phone.receive(.init(type: .snapshot, challenge: challenge, board: partial), now: date)
        #expect(!phone.canAct(now: date))
    }

    @Test func aLargeEscapedDetailResponseFitsTheEncryptedPayloadAndDeclaresItsExcerpt() throws {
        let board = board(), card = board.cards[0]
        let request = try RemoteDetailRequest(card: card, board: board)
        let note = RemoteDetailNote(id: "1", author: "Person", username: "person", body: String(repeating: "\"\\\ną", count: 40_000))
        let threads = (0..<80).map { RemoteDetailThread(id: String($0), state: .open, notes: [note]) }
        let response = RemoteDetailResponse(request: request, status: .current,
            details: .init(checkedAt: date, description: String(repeating: "ą", count: 100_000), threads: threads)).bounded()
        let encoded = try JSONEncoder().encode(RemoteMessage(type: .details, detailResponse: response))
        #expect(encoded.count <= RemoteCipher.maximumPayloadBytes)
        #expect(response.details?.truncated == true)
        #expect(response.status == .current)
    }
}
