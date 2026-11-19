import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor
struct DraftRegenerationCommandTests {
    @Test func aGlobalRequestRequiresTheCurrentControlCardAndToken() async throws {
        var board = makeBoard()
        let pairing = UUID()
        let security = InMemorySecurity()
        let store = RemoteCommandReceiptStore(service: "draft-regeneration", security: security.client)
        let gate = RemoteCommandGate(store: store)
        let card = try #require(board.draftRegeneration?.card)
        let action = try #require(card.actions.first)
        let cardID = card.id
        let current = RemoteCommand(hostSession: board.hostSession, account: board.account,
                                    cardID: cardID, actionID: action.id, token: action.token)
        var stale = current
        stale.id = UUID()
        stale.token = "previous-batch"
        var partial = board
        partial.partial = true
        let legacy = board.forClient(supportsCommentReview: true)

        for (snapshot, command) in [(board, stale), (partial, current), (legacy, current)] {
            let result = await gate.execute(command, board: snapshot, pairingSession: pairing) { _, _ in
                Issue.record("A draft regeneration command passed stale admission")
                return .completed
            }
            #expect(result.status == .changed)
        }

        var executions = 0
        let result = await gate.execute(current, board: board, pairingSession: pairing) { card, admitted in
            #expect(card.id == cardID)
            #expect(admitted == action)
            executions += 1
            return .completed
        }
        #expect(result.status == .completed)
        board.draftRegeneration = nil
        let reopened = RemoteCommandGate(store: store)
        let receipt = await reopened.execute(current, board: board, pairingSession: pairing) { _, _ in
            executions += 1
            return .failed
        }
        #expect(receipt == result)
        #expect(executions == 1)
    }

    @Test func clientsWithoutTheCapabilityReceiveOnlyTheExistingBoardCards() throws {
        let board = makeBoard()
        let encoder = JSONEncoder()
        let compatible = board.forClient(supportsCommentReview: true)
        let fields = try #require(JSONSerialization.jsonObject(with: encoder.encode(compatible)) as? [String: Any])
        #expect(fields["draftRegeneration"] == nil)
        #expect(compatible.cards == board.cards)

        let decoded = try JSONDecoder().decode(RemoteBoard.self, from: encoder.encode(board))
        #expect(decoded.cards == compatible.cards)
        #expect(decoded.draftRegeneration?.card.actions.first?.kind == .startDraftRegeneration)
        #expect(decoded.commandCards.map(\.id) == ["mr:1:2", "draft-regeneration"])
    }

    private func makeBoard() -> RemoteBoard {
        let request = RemoteCard(id: "mr:1:2", title: "Fix", project: "demo", url: nil, actions: [])
        let control = RemoteCard(id: "draft-regeneration", title: "", project: "", url: nil, actions: [
            .init(id: "start:all", kind: .startDraftRegeneration, token: "current-drafts")
        ])
        return .init(hostSession: UUID(), account: "me@gitlab.example.org",
                     lanes: [.init(id: .own, cards: [request])],
                     draftRegeneration: .init(card: control, count: 2))
    }
}
