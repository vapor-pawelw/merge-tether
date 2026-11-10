import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct CommandGateTests {
    func board() -> RemoteBoard {
        .init(hostSession: UUID(), account: "me@gitlab.example.org", lanes: [.init(id: .ready, cards: [
            .init(id: "mr:1:2", title: "Fix", project: "demo", url: URL(string: "https://gitlab.example.org/demo/-/merge_requests/2")!,
                  actions: [.init(id: "approve", kind: .approve, token: "current-content")]),
        ])])
    }

    @Test func duplicateCommandExecutesOnlyOnceAndAcceptancePrecedesCompletion() async {
        let board = board(), gate = RemoteCommandGate()
        let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        var events: [String] = []
        let first = await gate.execute(command, board: board, accepted: { events.append("accepted") }) { _, _ in
            events.append("executed"); return .completed
        }
        let second = await gate.execute(command, board: board) { _, _ in events.append("duplicate"); return .completed }
        #expect(events == ["accepted", "executed"])
        #expect(first.status == .completed)
        #expect(second == first)
    }

    @Test func changedContentAndOldHostCannotExecute() async {
        let board = board(), gate = RemoteCommandGate()
        for command in [
            RemoteCommand(hostSession: UUID(), cardID: "mr:1:2", actionID: "approve", token: "current-content"),
            RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "old-content"),
        ] {
            let result = await gate.execute(command, board: board) { _, _ in Issue.record("Stale command executed"); return .completed }
            #expect(result.status == .changed)
        }
    }

    @Test func aReceiptFromAnEarlierSessionCannotConfirmAReplayedCommand() async {
        var board = board()
        let gate = RemoteCommandGate()
        let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let first = await gate.execute(command, board: board) { _, _ in .completed }
        #expect(first.status == .completed)
        board.hostSession = UUID()
        let replay = await gate.execute(command, board: board) { _, _ in Issue.record("Old session executed"); return .completed }
        #expect(replay.status == .changed)
        let fresh = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let current = await gate.execute(fresh, board: board) { _, _ in .completed }
        #expect(current.status == .completed)
    }

    @Test func aNewSessionGetsItsOwnReceiptBudget() async {
        var board = board()
        let gate = RemoteCommandGate()
        for _ in 0..<512 {
            let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
            let result = await gate.execute(command, board: board) { _, _ in .completed }
            #expect(result.status == .completed)
        }
        let exhausted = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let limited = await gate.execute(exhausted, board: board) { _, _ in Issue.record("Receipt limit bypassed"); return .completed }
        #expect(limited.status == .limit)
        board.hostSession = UUID()
        let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let fresh = await gate.execute(command, board: board) { _, _ in .completed }
        #expect(fresh.status == .completed)
    }

    @Test func anAcceptedOperationKeepsTheWriteLockAcrossSessionChanges() async {
        let board = board(), gate = RemoteCommandGate()
        let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(command, board: board) { _, _ in
            var reconnected = board
            reconnected.hostSession = UUID()
            let fresh = RemoteCommand(hostSession: reconnected.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
            let blocked = await gate.execute(fresh, board: reconnected) { _, _ in Issue.record("Concurrent write after reconnect"); return .completed }
            #expect(blocked.status == .changed)
            return .completed
        }
    }

    @Test func uncertainResultsAreNeverRetried() async {
        let board = board(), gate = RemoteCommandGate()
        let command = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(command, board: board) { _, _ in .uncertain }
        let again = await gate.execute(command, board: board) { _, _ in Issue.record("Ambiguous write retried"); return .completed }
        #expect(again.status == .uncertain)
    }

    @Test func concurrentDuplicateIsAcknowledgedButAnotherWriteCannotRun() async {
        let board = board(), gate = RemoteCommandGate()
        let first = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        let second = RemoteCommand(hostSession: board.hostSession, cardID: "mr:1:2", actionID: "approve", token: "current-content")
        _ = await gate.execute(first, board: board, accepted: {
            let duplicate = await gate.execute(first, board: board) { _, _ in Issue.record("Duplicate executed"); return .completed }
            #expect(duplicate.status == .running)
            let concurrent = await gate.execute(second, board: board) { _, _ in Issue.record("Concurrent write executed"); return .completed }
            #expect(concurrent.status == .changed)
        }) { _, _ in .completed }
    }
}
