import Foundation

@MainActor extension TodoMonitorService {
    var boardSnapshot: MergeRequestBoardSnapshot {
        .init(own: ownMergeRequestItems, reviewed: reviewedMergeRequestItems,
            todos: currentAccountTodos, attention: attentionItems,
            handoffs: assistantHandoffs, host: glab.resolvedHost, username: glab.currentUsername,
            intents: currentMRTodoIntents, routedTodoIDs: routedMRTodoIDs,
            ignoredTargets: settings.ignoredMergeRequests, humanAttention: userAttention,
            pinnedCards: settings.boardPins)
    }
}
