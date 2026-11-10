import Foundation

@MainActor extension TodoMonitorService {
    var boardSnapshot: MergeRequestBoardSnapshot {
        let baseline = makeBoardSnapshot()
        let positions = boardPolicyOrder.positions(for: boardOrderingEntries(baseline))
        return positions.isEmpty ? baseline : makeBoardSnapshot(preservedOrder: positions)
    }

    var inboxItems: [MergeRequestBoardSnapshot.OtherCard] {
        boardSnapshot.otherCards(jobs: assistantHandoffs, host: glab.resolvedHost,
            username: glab.currentUsername, pinnedCards: settings.boardPins)
    }

    private func makeBoardSnapshot(preservedOrder: [MergeRequestAttentionMonitor.Item.ID: Int] = [:]) -> MergeRequestBoardSnapshot {
        boardProjector?.board(humanAttention: userAttention, preservedOrder: preservedOrder)
            ?? .init(own: [], reviewed: [], todos: [], attention: [], handoffs: [], host: nil, username: nil)
    }
}
