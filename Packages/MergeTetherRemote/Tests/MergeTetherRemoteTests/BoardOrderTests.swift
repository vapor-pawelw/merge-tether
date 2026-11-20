import Foundation
import Testing
@testable import MergeTetherRemote

struct BoardOrderTests {
    @Test func pairedClientsCanSendABoardOrderRequest() throws {
        let board = try makeBoard()
        let source = try #require(board.orderSource(for: board.cards[0]))
        let move = RemoteBoardOrderMove(source: source, destinationID: "second")
        let message = RemoteMessage(type: .boardOrderRequest, challenge: UUID(), boardOrderMove: move)

        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.type.rawValue == "board-order-request")
        #expect(decoded.boardOrderMove == move && decoded.challenge == message.challenge)
        #expect(board.permitsOrderMove(move))
    }

    @Test func onlyTheSourceGroupRevisionMattersAndItCoversAutomationPinLaneAndOrder() throws {
        var board = try makeBoard()
        let source = try #require(board.orderSource(for: board.cards[0]))
        for id in ["pinned", "paused", "reviewed", "first", "missing"] {
            #expect(!board.permitsOrderMove(.init(source: source, destinationID: id)))
        }
        let move = RemoteBoardOrderMove(source: source, destinationID: "second")
        let detailContext = board.cards[0].detailContextDigest
        board.lanes[0].cards[0].needsAttention = true
        board.lanes[1].cards[0].title = "Changed elsewhere"
        #expect(board.permitsOrderMove(move))
        let promoted = try #require(RemoteBoardOrderGroup(lane: .own, automationEnabled: true,
            pinned: false, cardIDs: ["second", "first"]))
        board.lanes[0].cards[0].orderGroup = promoted
        board.lanes[0].cards[1].orderGroup = promoted
        board.lanes[0].cards.swapAt(0, 1)
        #expect(!board.permitsOrderMove(move))
        #expect(board.cards[1].detailContextDigest == detailContext)
    }

    @Test(arguments: ["partial", "account", "session", "older host"])
    func anOrderRequestIsBoundToTheCurrentPairedBoard(_ change: String) throws {
        var board = try makeBoard()
        let source = try #require(board.orderSource(for: board.cards[0]))
        switch change {
        case "partial": board.partial = true
        case "account": board.account = "other"
        case "session": board.hostSession = UUID()
        default: board.lanes[0].cards[0].orderGroup = nil
        }
        #expect(!board.permitsOrderMove(.init(source: source, destinationID: "second")))
    }

    private func makeBoard() throws -> RemoteBoard {
        func cards(_ ids: [String], lane: RemoteLaneID = .own, enabled: Bool = true, pinned: Bool = false) throws -> [RemoteCard] {
            let group = try #require(RemoteBoardOrderGroup(lane: lane, automationEnabled: enabled, pinned: pinned, cardIDs: ids))
            return ids.map {
                var card = RemoteCard(id: $0, title: $0, project: "example", url: nil)
                card.orderGroup = group
                return card
            }
        }
        return try .init(hostSession: UUID(), account: "me@gitlab.example.test", lanes: [
            .init(id: .own, cards: cards(["first", "second"]) + cards(["pinned"], pinned: true)
                + cards(["paused"], enabled: false)),
            .init(id: .reviewed, cards: cards(["reviewed"], lane: .reviewed))
        ])
    }
}
