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
        if settings.boardOrderingMethod == .manual, let host = glab.resolvedHost, let username = glab.currentUsername {
            return baseline.applyingManualOrder(settings.boardManualOrder, host: host, username: username,
                pinnedCards: settings.boardPins, newReviews: settings.newReviewTargets)
        }
        let positions = boardPolicyOrder.positions(for: boardOrderingEntries(baseline))
        return baseline.preservingOrder(positions, host: glab.resolvedHost, username: glab.currentUsername,
            pinnedCards: settings.boardPins)
    }

    func moveBoardCard(_ source: MRAutomationScope.Target, to destination: MRAutomationScope.Target,
                       accountRevision: UInt64) -> Bool {
        guard settings.boardOrderingMethod == .manual, glab.accountRevision == accountRevision,
              boardRefreshState == .current else { return false }
        var order = settings.boardManualOrder
        guard order.move(source, to: destination, in: boardSnapshot.manualOrderEntries) else { return false }
        return settings.saveBoardManualOrder(order)
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
