import Foundation
import Testing
@testable import MergeTetherRemote

struct BoardOrderTests {
    @Test func laneFiltersCombineCardChoicesAndSectionsWithoutChangingOrder() throws {
        var board = try makeBoard()
        board.lanes[0].cards[0].boardTraits = .init(needsAttention: false, isNew: true, isInactive: false)
        board.lanes[0].cards[2].boardTraits = .init(needsAttention: true, isNew: false, isInactive: true)
        let source = try #require(board.orderSource(for: board.lanes[0].cards[0]))
        let canonicalOrder = board.lanes[0].cards.map(\.id)
        let filter = RemoteBoardLaneFilter(cards: [.needsAttention, .new], sections: [.regular])
        #expect(board.lanes[0].cards.filter(filter.matches).map(\.id) == [canonicalOrder[0]])
        #expect(board.lanes[0].cards.map(\.id) == canonicalOrder)
        #expect(board.orderMove(from: source, beside: "second", insertion: .after)?.destinationID == "second")
    }

    @Test func openingDetailsCanAcknowledgeOnlyTheDisplayedNewAssignment() throws {
        let seen = RemoteAction(id: RemoteAction.reviewSeenID, kind: .markDone, token: String(repeating: "a", count: 64))
        var card = RemoteCard(id: "mr:1:2", title: "Review", project: "group/repo", url: nil, actions: [seen])
        card.boardTraits = .init(needsAttention: false, isNew: true, isInactive: false)
        var board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .reviewed, cards: [card])])
        let request = try RemoteDetailRequest(card: card, board: board, presentationIndependent: true, reviewSeenToken: seen.token)
        #expect(request.reviewSeenAction(in: board) == seen)

        var unavailable = board
        unavailable.partial = true
        #expect(request.matches(unavailable))
        #expect(request.reviewSeenAction(in: unavailable) == nil)
        unavailable.hostSession = UUID()
        #expect(request.reviewSeenAction(in: unavailable) == nil)

        board.lanes[0].cards[0].actions = []
        board.lanes[0].cards[0].boardTraits?.isNew = false
        #expect(request.matches(board))
        #expect(request.reviewSeenAction(in: board) == nil)
        board.lanes[0].cards[0].actions = [.init(id: seen.id, kind: seen.kind, token: String(repeating: "b", count: 64))]
        board.lanes[0].cards[0].boardTraits?.isNew = true
        #expect(request.reviewSeenAction(in: board) == nil)
        board.account = "other@host"
        board.lanes[0].cards[0].actions = [seen]
        #expect(!request.matches(board))
        #expect(request.reviewSeenAction(in: board) == nil)
    }

    @MainActor @Test func onlyCurrentCapablePeersCanRestoreAHiddenReview() throws {
        let restore = RemoteAction(id: RemoteAction.restoreHiddenReviewID, kind: .markDone, token: "hide")
        let hidden = RemoteCard(id: "hidden-review:1:2", title: "Hidden", project: "group/repo", url: nil, actions: [restore])
        var board = try makeBoard()
        board.hiddenReviews = [hidden]
        board.lanes[1].cards[0].boardTraits = .init(needsAttention: true, isNew: true, isInactive: false)
        board.lanes[1].cards[0].actions = [.init(id: RemoteAction.reviewSeenID, kind: .markDone, token: "new")]
        let legacy = board.forClient(supportsCommentReview: true)
        #expect(legacy.hiddenReviews == nil)
        #expect(legacy.cards.allSatisfy { $0.boardTraits == nil && $0.actions.isEmpty })
        #expect(legacy.cards.map(\.detailContextDigest) == board.cards.map(\.detailContextDigest))

        let state = RemotePhoneState()
        var partial = board
        partial.partial = true
        #expect(state.receive(.init(type: .snapshot, challenge: state.challenge(), board: partial)))
        #expect(state.board?.hiddenReviews == [hidden])
        #expect(state.command(card: hidden, action: restore) == nil)
        #expect(state.receive(.init(type: .snapshot, challenge: state.challenge(), board: board)))
        #expect(state.inboxCards == nil)
        #expect(state.command(card: hidden, action: restore)?.cardID == hidden.id)
    }

    @Test func oversizedHiddenHistoryKeepsTheBoardReadable() throws {
        var board = try makeBoard()
        board.hiddenReviews = [RemoteCard(id: "hidden-review:1:2",
            title: String(repeating: "a", count: RemoteCipher.maximumPayloadBytes), project: "group/repo", url: nil)]
        board.lanes[1].cards[0].boardTraits = .init(needsAttention: false, isNew: true, isInactive: false)
        board.lanes[1].cards[0].issues = [.init(reference: "#4", url: URL(string: "https://gitlab.example.test/g/p/-/issues/4")!)]
        let fitted = RemoteMessage(type: .snapshot, challenge: UUID(), board: board).fittingSnapshotMetadata()
        #expect(fitted.board?.hiddenReviews == nil)
        #expect(fitted.board?.lanes == board.lanes)
        #expect(fitted.board?.issueTagsOmitted != true)
        #expect(try JSONEncoder().encode(fitted).count <= RemoteCipher.maximumPayloadBytes)
    }

    @Test func gapsResolveToTheExistingMoveContractInEitherDirection() {
        let order = ["a", "b", "c", "d"]
        #expect(BoardOrderInsertion.before.destination(moving: "d", beside: "a", in: order) == "a")
        #expect(BoardOrderInsertion.after.destination(moving: "a", beside: "d", in: order) == "d")
        #expect(BoardOrderInsertion.before.destination(moving: "a", beside: "d", in: order) == "c")
        #expect(BoardOrderInsertion.after.destination(moving: "d", beside: "a", in: order) == "b")
        #expect(BoardOrderInsertion.before.destination(moving: "a", beside: "b", in: order) == nil)
        #expect(BoardOrderInsertion.after.destination(moving: "d", beside: "c", in: order) == nil)
        #expect(BoardOrderInsertion.after.destination(moving: "a", beside: "missing", in: order) == nil)
    }

    @Test func aPhoneCanInsertAtAValidBoundaryOnlyWithinItsOriginalGroup() throws {
        var board = try makeBoard()
        let source = try #require(board.orderSource(for: board.cards[1]))
        let move = board.orderMove(from: source, beside: "first", insertion: .before)
        #expect(move?.destinationID == "first")
        for anchor in ["pinned", "paused", "reviewed", "missing"] {
            #expect(board.orderMove(from: source, beside: anchor, insertion: .before) == nil)
        }
        board.hostSession = UUID()
        #expect(board.orderMove(from: source, beside: "first", insertion: .before) == nil)
    }

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
