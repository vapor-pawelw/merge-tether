import Foundation

@MainActor public final class RemoteCommandGate {
    private let store: RemoteCommandReceiptStore?
    private var snapshot: RemoteCommandReceiptStore.Snapshot?
    private var loaded = false
    private var storageFailed = false
    private var busy = false
    // Pass nil only when deliberately using ephemeral, in-memory receipts.
    public init(store: RemoteCommandReceiptStore?) { self.store = store }
    public func execute(_ command: RemoteCommand, board: RemoteBoard, pairingSession: UUID,
                        accepted: @MainActor () async -> Void = {},
                        operation: @MainActor (RemoteCard, RemoteAction) async -> RemoteCommandResult.Status) async -> RemoteCommandResult {
        guard command.hostSession == board.hostSession, command.account == board.account else { return .init(id: command.id, status: .changed) }
        if !loaded {
            do { snapshot = try store?.load(); loaded = true }
            catch { return .init(id: command.id, status: .uncertain) }
        }
        if snapshot?.pairingSession == pairingSession,
           let receipt = snapshot?.receipts.first(where: { $0.command.id == command.id }) {
            return receipt.command == command ? receipt.result : .init(id: command.id, status: .changed)
        }
        guard !storageFailed else { return .init(id: command.id, status: .uncertain) }
        guard !busy else { return .init(id: command.id, status: .changed) }
        if snapshot?.pairingSession != pairingSession {
            // Only explicit device-key rotation revokes the old trust namespace.
            // Host reconnects retain results so a phone can recover a lost reply.
            snapshot = .init(pairingSession: pairingSession)
        }
        guard var admission = snapshot else { return .init(id: command.id, status: .uncertain) }
        guard admission.receipts.count < RemoteCommandReceiptStore.maximumReceipts else { return .init(id: command.id, status: .limit) }
        guard !board.partial,
              let card = board.cards.first(where: { $0.id == command.cardID }),
              let action = card.actions.first(where: { $0.id == command.actionID && $0.token == command.token })
        else { return .init(id: command.id, status: .changed) }
        admission.receipts.append(.init(command: command, result: .init(id: command.id, status: .running)))
        do { try store?.save(admission) }
        catch { storageFailed = true; return .init(id: command.id, status: .uncertain) }
        snapshot = admission; busy = true
        defer { busy = false }
        await accepted()
        let result = RemoteCommandResult(id: command.id, status: await operation(card, action))
        guard var completion = snapshot,
              let index = completion.receipts.firstIndex(where: { $0.command == command }) else { return .init(id: command.id, status: .uncertain) }
        completion.receipts[index].result = result
        do { try store?.save(completion); snapshot = completion; return result }
        catch {
            snapshot?.receipts[index].result.status = .uncertain
            storageFailed = true
            return .init(id: command.id, status: .uncertain)
        }
    }
    public func receipt(for command: RemoteCommand, account: String, pairingSession: UUID) -> RemoteCommandResult {
        guard command.account == account else { return .init(id: command.id, status: .changed) }
        if !loaded {
            do { snapshot = try store?.load(); loaded = true }
            catch { return .init(id: command.id, status: .uncertain) }
        }
        guard let snapshot else { return .init(id: command.id, status: .uncertain) }
        guard snapshot.pairingSession == pairingSession else { return .init(id: command.id, status: .changed) }
        guard let receipt = snapshot.receipts.first(where: { $0.command.id == command.id }) else { return .init(id: command.id, status: .uncertain) }
        return receipt.command == command ? receipt.result : .init(id: command.id, status: .changed)
    }

}
