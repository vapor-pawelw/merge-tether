import Foundation

@MainActor public final class RemoteCommandGate {
    private var receipts: [UUID: (RemoteCommand, RemoteCommandResult)] = [:]
    private var busy = false
    private var hostSession: UUID?
    public init() {}
    public func execute(_ command: RemoteCommand, board: RemoteBoard,
                        accepted: @MainActor () async -> Void = {},
                        operation: @MainActor (RemoteCard, RemoteAction) async -> RemoteCommandResult.Status) async -> RemoteCommandResult {
        if hostSession != board.hostSession {
            hostSession = board.hostSession
            receipts.removeAll()
            // A reconnect does not cancel a write already accepted by GitLab.
            // Keep the same lock until that operation finishes.
        }
        guard command.hostSession == board.hostSession else { return .init(id: command.id, status: .changed) }
        if let (original, result) = receipts[command.id] {
            return original == command ? result : .init(id: command.id, status: .changed)
        }
        guard receipts.count < 512 else { return .init(id: command.id, status: .limit) }
        guard !busy else { return .init(id: command.id, status: .changed) }
        guard !board.partial, board.hostSession == command.hostSession,
              let card = board.cards.first(where: { $0.id == command.cardID }),
              let action = card.actions.first(where: { $0.id == command.actionID && $0.token == command.token })
        else { return .init(id: command.id, status: .changed) }
        busy = true
        receipts[command.id] = (command, .init(id: command.id, status: .running))
        await accepted()
        let result = RemoteCommandResult(id: command.id, status: await operation(card, action))
        if hostSession == command.hostSession { receipts[command.id] = (command, result) }
        busy = false
        return result
    }
}
