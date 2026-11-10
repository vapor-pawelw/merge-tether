import Foundation

@MainActor extension TodoMonitorService {
    var boardSnapshot: MergeRequestBoardSnapshot {
        guard let projector = boardProjector else {
            return .init(own: [], reviewed: [], todos: [], attention: [], handoffs: [], host: nil, username: nil)
        }
        let attention = userAttention
        let baseline = projector.board(humanAttention: attention)
        let positions = boardPolicyOrder.positions(for: boardOrderingEntries(baseline))
        return baseline.preservingOrder(positions, host: glab.resolvedHost, username: glab.currentUsername,
            pinnedCards: settings.boardPins)
    }

    var inboxItems: [MergeRequestBoardSnapshot.OtherCard] {
        boardSnapshot.otherCards(jobs: assistantHandoffs, host: glab.resolvedHost,
            username: glab.currentUsername, pinnedCards: settings.boardPins)
    }

    var commandCenterDisplayFrame: CommandCenterDisplayFrame {
        .init(board: boardSnapshot, jobs: assistantHandoffs, host: glab.resolvedHost,
            username: glab.currentUsername, pinnedCards: settings.boardPins)
    }
}
