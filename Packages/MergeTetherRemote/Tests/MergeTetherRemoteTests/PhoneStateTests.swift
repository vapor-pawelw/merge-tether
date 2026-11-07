import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct PhoneStateTests {
    @Test func onlyFreshChallengeEnablesActionsAndDisconnectKeepsBoard() {
        let state = RemotePhoneState(), now = Date()
        let board = CommandGateTests().board()
        let challenge = state.challenge()
        state.receive(.init(type: .snapshot, challenge: UUID(), board: board), now: now)
        #expect(!state.canAct(now: now))
        state.receive(.init(type: .snapshot, challenge: challenge, board: board), now: now)
        #expect(state.canAct(now: now))
        #expect(!state.canAct(now: now.addingTimeInterval(46)))
        state.disconnected()
        #expect(state.board == board)
        #expect(!state.canAct(now: now))
    }
    @Test func lostConnectionMakesPendingWriteUncertainWithoutRetry() throws {
        let state = RemotePhoneState(), board = CommandGateTests().board(), now = Date()
        let challenge = state.challenge()
        state.receive(.init(type: .snapshot, challenge: challenge, board: board), now: now)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let command = try #require(state.command(card: card, action: action, now: now))
        #expect(!state.canAct(now: now))
        state.disconnected()
        #expect(state.result == .init(id: command.id, status: .uncertain))
        #expect(state.command(card: card, action: action, now: now) == nil)
    }

    @Test func delayedSnapshotCannotExtendAChallengePastItsLease() {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        let challenge = state.challenge(now: now)
        state.receive(.init(type: .snapshot, challenge: challenge, board: board), now: now.addingTimeInterval(46))
        #expect(!state.canAct(now: now.addingTimeInterval(46)))
    }
    @Test func repeatedRefreshCoalescesAndAcceptanceExtendsTheCommandDeadline() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        let first = try #require(state.beginRefresh(now: now))
        #expect(state.beginRefresh(now: now.addingTimeInterval(1)) == nil)
        state.receive(.init(type: .snapshot, challenge: first, board: board), now: now)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let command = try #require(state.command(card: card, action: action, now: now))
        state.receive(.init(type: .accepted, result: .init(id: command.id, status: .running)), now: now.addingTimeInterval(30))
        state.checkCommandTimeout(now: now.addingTimeInterval(60))
        #expect(state.pending?.id == command.id)
        state.checkCommandTimeout(now: now.addingTimeInterval(151))
        #expect(state.result?.status == .uncertain)
    }

    @Test func aReconnectedHostReplacesALostOutstandingHelloImmediately() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        let lost = try #require(state.beginRefresh(now: now))
        let fresh = try #require(state.beginRefresh(force: true, now: now.addingTimeInterval(1)))
        #expect(fresh != lost)
        state.receive(.init(type: .snapshot, challenge: lost, board: board), now: now.addingTimeInterval(2))
        #expect(!state.canAct(now: now.addingTimeInterval(2)))
        state.receive(.init(type: .snapshot, challenge: fresh, board: board), now: now.addingTimeInterval(2))
        #expect(state.canAct(now: now.addingTimeInterval(2)))
    }

}
