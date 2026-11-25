import Foundation
import MergeTetherRemote

@MainActor struct RemoteInboxReadSelection {
    private struct Entry {
        let item: MergeRequestBoardSnapshot.OtherCard
        let token: String

        init?(_ item: MergeRequestBoardSnapshot.OtherCard) {
            let version: String? = switch item.content {
            case .todo(let todo): try? RemoteDigest.token(todo)
            case .completion(let completion): try? RemoteDigest.token(completion)
            case .hiddenReview(let review, _): try? RemoteDigest.token(review)
            case .job, .proposal: nil
            }
            guard let version, let identity = try? RemoteDigest.token(item.id),
                  let token = try? RemoteDigest.token([identity, version]) else { return nil }
            self.item = item
            self.token = token
        }
    }

    private let entries: [Entry]

    init?(_ items: [MergeRequestBoardSnapshot.OtherCard]) {
        let notificationIDs = CommandCenterDisplayFrame.Inbox(items: items).notificationIDs
        let identities = Set(notificationIDs)
        let entries = items.filter { identities.contains($0.id) }.compactMap(Entry.init)
        guard !entries.isEmpty, entries.count == notificationIDs.count, entries.count == identities.count else { return nil }
        self.entries = entries
    }

    func action(hostSession: UUID, account: String) -> RemoteAction? {
        let context = [RemoteBoard.inboxReadCardID, hostSession.uuidString, account]
        guard let token = try? RemoteDigest.token(context + entries.map(\.token).sorted()) else { return nil }
        return .init(id: RemoteBoard.inboxReadActionID, kind: .markDone, token: token)
    }

    func acknowledge(monitor: TodoMonitorService,
                     isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> RemoteCommandResult.Status {
        var acknowledged = 0
        var uncertain = false
        for entry in entries {
            guard isCurrent() else { break }
            let id = entry.item.id, token = entry.token
            let stillVisible: @MainActor @Sendable () -> Bool = {
                guard isCurrent(), let current = monitor.inboxItems.first(where: { $0.id == id }) else { return false }
                return Entry(current)?.token == token
            }
            guard stillVisible() else { continue }
            let outcome: InboxTodoStore.AcknowledgementResult
            switch entry.item.content {
            case .todo(let todo):
                outcome = await monitor.acknowledgeVisibleTodo(todo, shouldProceed: stillVisible)
            case .completion(let completion):
                outcome = monitor.acknowledgeLifecycleCompletion(id: completion.id) ? .acknowledged : .uncertain
            case .hiddenReview(_, let notice):
                outcome = monitor.acknowledgeHiddenReviewNotifications([notice.id]) ? .acknowledged : .uncertain
            case .proposal, .job:
                continue
            }
            switch outcome {
            case .acknowledged: acknowledged += 1
            case .notStarted: continue
            case .uncertain: uncertain = true
            }
        }
        if acknowledged == entries.count { return .completed }
        if acknowledged > 0 { return .partial }
        return uncertain ? .uncertain : .changed
    }

    static func acknowledgeTodo(card: RemoteCard, action: RemoteAction, account: String, monitor: TodoMonitorService,
                                isCurrent: @escaping @MainActor @Sendable () -> Bool) async -> RemoteCommandResult.Status {
        guard isCurrent(), let todo = monitor.boardSnapshot.otherTodos.first(where: { "todo:\($0.id)" == card.id }),
              RemoteBoardAdapter.card(todo, account: account).actions.contains(action) else { return .changed }
        let stillVisible: @MainActor @Sendable () -> Bool = {
            isCurrent() && !monitor.isAssessingNotice(todo) && monitor.boardSnapshot.otherTodos.contains(todo)
        }
        guard stillVisible() else { return .changed }
        switch await monitor.acknowledgeVisibleTodo(todo, shouldProceed: stillVisible) {
        case .acknowledged: return .completed
        case .notStarted: return .changed
        case .uncertain: return .uncertain
        }
    }
}
