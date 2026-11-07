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
