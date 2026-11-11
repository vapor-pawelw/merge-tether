import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct CommandGateTests {
    let pairingSession = UUID()
    func board() -> RemoteBoard {
        .init(hostSession: UUID(), account: "me@gitlab.example.org", lanes: [.init(id: .ready, cards: [
            .init(id: "mr:1:2", title: "Fix", project: "demo", url: URL(string: "https://gitlab.example.org/demo/-/merge_requests/2")!,
                  actions: [.init(id: "approve", kind: .approve, token: "current-content")]),
        ])])
    }

    @Test func duplicateCommandExecutesOnlyOnceAndAcceptancePrecedesCompletion() async {
        let board = board(), gate = RemoteCommandGate(store: nil)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        var events: [String] = []
        let first = await gate.execute(command, board: board, pairingSession: pairingSession, accepted: { events.append("accepted") }) { _, _ in
            events.append("executed"); return .completed
        }
        let second = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in events.append("duplicate"); return .completed }
        #expect(events == ["accepted", "executed"])
        #expect(first.status == .completed)
        #expect(second == first)
    }

    @Test func changedContentAndOldHostCannotExecute() async {
        let board = board(), gate = RemoteCommandGate(store: nil)
        for command in [
            RemoteCommand(hostSession: UUID(), account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content"),
            RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "old-content"),
        ] {
            let result = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Stale command executed"); return .completed }
            #expect(result.status == .changed)
        }
    }

    @Test func aReceiptFromAnEarlierSessionCannotConfirmAReplayedCommand() async {
        var board = board()
        let gate = RemoteCommandGate(store: nil)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let first = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in .completed }
        #expect(first.status == .completed)
        board.hostSession = UUID()
        let replay = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Old session executed"); return .completed }
        #expect(replay.status == .changed)
        let fresh = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let current = await gate.execute(fresh, board: board, pairingSession: pairingSession) { _, _ in .completed }
        #expect(current.status == .completed)
    }

    @Test func deliberateKeyRotationGetsItsOwnReceiptBudget() async {
        var board = board()
        let gate = RemoteCommandGate(store: nil)
        for _ in 0..<512 {
            let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
            let result = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in .completed }
            #expect(result.status == .completed)
        }
        let exhausted = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let limited = await gate.execute(exhausted, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Receipt limit bypassed"); return .completed }
        #expect(limited.status == .limit)
        board.hostSession = UUID()
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let fresh = await gate.execute(command, board: board, pairingSession: UUID()) { _, _ in .completed }
        #expect(fresh.status == .completed)
    }

    @Test func anAcceptedOperationKeepsTheWriteLockAcrossSessionChanges() async {
        let board = board(), gate = RemoteCommandGate(store: nil)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in
            var reconnected = board
            reconnected.hostSession = UUID()
            let fresh = RemoteCommand(hostSession: reconnected.hostSession, account: reconnected.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
            let blocked = await gate.execute(fresh, board: reconnected, pairingSession: pairingSession) { _, _ in Issue.record("Concurrent write after reconnect"); return .completed }
            #expect(blocked.status == .changed)
            return .completed
        }
    }

    @Test func uncertainResultsAreNeverRetried() async {
        let board = board(), gate = RemoteCommandGate(store: nil)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in .uncertain }
        let again = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Ambiguous write retried"); return .completed }
        #expect(again.status == .uncertain)
    }

    @Test func concurrentDuplicateIsAcknowledgedButAnotherWriteCannotRun() async {
        let board = board(), gate = RemoteCommandGate(store: nil)
        let first = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let second = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(first, board: board, pairingSession: pairingSession, accepted: {
            let duplicate = await gate.execute(first, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Duplicate executed"); return .completed }
            #expect(duplicate.status == .running)
            let concurrent = await gate.execute(second, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Concurrent write executed"); return .completed }
            #expect(concurrent.status == .changed)
        }) { _, _ in .completed }
    }
    @Test func storedCompletionSurvivesGateRecreationAndChangedIdentityCannotReuseItsID() async throws {
        let board = board(), memory = InMemorySecurity()
        let store = RemoteCommandReceiptStore(service: "receipt", security: memory.client)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let first = await RemoteCommandGate(store: store).execute(command, board: board, pairingSession: pairingSession) { _, _ in .completed }
        let reopened = RemoteCommandGate(store: store)
        let duplicate = await reopened.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Replayed after restart"); return .failed }
        #expect(first == duplicate)
        var changed = command; changed.token = "different"
        let changedResult = await reopened.execute(changed, board: board, pairingSession: pairingSession) { _, _ in .failed }
        #expect(changedResult.status == .changed)
        changed = command; changed.account = "other@gitlab.example.org"
        let differentAccount = await reopened.execute(changed, board: board, pairingSession: pairingSession) { _, _ in .failed }
        #expect(differentAccount.status == .changed)
    }
    @Test func admissionIsDurableBeforeAcceptanceAndCrashAdmissionIsNeverRetried() async throws {
        let board = board(), memory = InMemorySecurity()
        let store = RemoteCommandReceiptStore(service: "receipt", security: memory.client)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let gate = RemoteCommandGate(store: store)
        _ = await gate.execute(command, board: board, pairingSession: pairingSession, accepted: {
            let restarted = RemoteCommandGate(store: store)
            let receipt = await restarted.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Crash admission replayed"); return .completed }
            #expect(receipt.status == .uncertain)
        }) { _, _ in .completed }
    }
    @Test(arguments: ["read", "add", "update"])
    func persistenceFailurePreventsAcceptanceAndTheSideEffect(_ failure: String) async throws {
        let board = board(), memory = InMemorySecurity(failing: failure)
        let gate = RemoteCommandGate(store: RemoteCommandReceiptStore(service: "receipt", security: memory.client))
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let result = await gate.execute(command, board: board, pairingSession: pairingSession, accepted: { Issue.record("Accepted without durable receipt") }) { _, _ in
            Issue.record("Executed without durable receipt"); return .completed
        }
        #expect(result.status == .uncertain)
    }
    @Test func finalReceiptFailureIsUncertainAndNeverReexecutesAfterRestart() async throws {
        let board = board(), memory = InMemorySecurity()
        let store = RemoteCommandReceiptStore(service: "receipt", security: memory.client)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let result = await RemoteCommandGate(store: store).execute(command, board: board, pairingSession: pairingSession) { _, _ in memory.failing = "update"; return .completed }
        #expect(result.status == .uncertain)
        memory.failing = nil
        let replay = await RemoteCommandGate(store: store).execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Uncertain write retried"); return .failed }
        #expect(replay.status == .uncertain)
    }
    @Test func fullDurableStoreDoesNotEvictAReplayableReceipt() async throws {
        let board = board(), memory = InMemorySecurity()
        let store = RemoteCommandReceiptStore(service: "receipt", security: memory.client)
        let gate = RemoteCommandGate(store: store)
        let first = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(first, board: board, pairingSession: pairingSession) { _, _ in .completed }
        for _ in 1..<512 {
            let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
            _ = await gate.execute(command, board: board, pairingSession: pairingSession) { _, _ in .completed }
        }
        let reopened = RemoteCommandGate(store: store)
        let new = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let limited = await reopened.execute(new, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Bound bypassed"); return .failed }
        #expect(limited.status == .limit)
        let retained = await reopened.execute(first, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Evicted receipt replayed"); return .failed }
        #expect(retained.status == .completed)
    }

    @Test func receiptQuerySurvivesHostSessionRolloverWithoutPermittingOldCommands() async throws {
        var board = board()
        let memory = InMemorySecurity()
        let durable = RemoteCommandReceiptStore(service: "recovery", security: memory.client)
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await RemoteCommandGate(store: durable).execute(command, board: board, pairingSession: pairingSession) { _, _ in .completed }
        board.hostSession = UUID()
        let restarted = RemoteCommandGate(store: durable)
        let replay = await restarted.execute(command, board: board, pairingSession: pairingSession) { _, _ in Issue.record("Old command replayed"); return .completed }
        #expect(replay.status == .changed)
        #expect(restarted.receipt(for: command, account: board.account, pairingSession: pairingSession).status == .completed)
        #expect(restarted.receipt(for: command, account: "other", pairingSession: pairingSession).status == .changed)
        #expect(restarted.receipt(for: command, account: board.account, pairingSession: UUID()).status == .changed)
        var changed = command; changed.token = "different"
        #expect(restarted.receipt(for: changed, account: board.account, pairingSession: pairingSession).status == .changed)
        let fresh = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await restarted.execute(fresh, board: board, pairingSession: pairingSession) { _, _ in .completed }
        #expect(restarted.receipt(for: command, account: board.account, pairingSession: pairingSession).status == .completed)
    }

}
