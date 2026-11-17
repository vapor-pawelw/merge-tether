import Foundation

@MainActor extension TodoMonitorService {
    var boardSnapshot: MergeRequestBoardSnapshot {
        withBoardPresentationRead { live in
            live ? makeBoardSnapshot() : boardSnapshotCache.value { makeBoardSnapshot() }
        }
    }

    private func makeBoardSnapshot() -> MergeRequestBoardSnapshot {
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
        commandCenterDisplayFrame.inbox.items
    }

    var commandCenterDisplayFrame: CommandCenterDisplayFrame {
        withBoardPresentationRead { live in
            live ? makeCommandCenterDisplayFrame() : commandCenterDisplayFrameCache.value { makeCommandCenterDisplayFrame() }
        }
    }

    private func makeCommandCenterDisplayFrame() -> CommandCenterDisplayFrame {
        .init(board: boardSnapshot, jobs: assistantHandoffs, host: glab.resolvedHost,
            username: glab.currentUsername, pinnedCards: settings.boardPins)
    }
}
