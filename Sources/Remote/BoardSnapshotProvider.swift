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
        .init(own: ownMergeRequestItems, reviewed: reviewedMergeRequestItems,
            todos: currentAccountTodos, attention: attentionItems,
            handoffs: assistantHandoffs, host: glab.resolvedHost, username: glab.currentUsername,
            intents: currentMRTodoIntents, routedTodoIDs: routedMRTodoIDs,
            ignoredTargets: hiddenBoardTargets, humanAttention: userAttention,
            pinnedCards: settings.boardPins, pipelineEvidence: currentPipelineEvidence,
            pipelineEvidenceCheckedAt: currentPipelineEvidenceDate, preservedOrder: preservedOrder,
            automation: settings.automation, displayRequests: boardDisplayRequests, grouping: settings.boardGrouping,
            completions: lifecycleCompletions)
    }
}
