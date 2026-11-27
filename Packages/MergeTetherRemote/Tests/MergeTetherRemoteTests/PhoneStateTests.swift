import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct PhoneStateTests {
    @Test func nextTimeChangeReportsTheEarliestFutureDeadlineAndIgnoresPastOnes() throws {
        let state = RemotePhoneState(), now = Date()
        #expect(state.nextTimeChange(after: now) == nil)

        // The challenge deadline is the response window; a snapshot sets every deadline to it.
        let challenge = state.challenge(now: now)
        let deadline = now.addingTimeInterval(45)
        #expect(state.nextTimeChange(after: now) == deadline)
        #expect(state.nextTimeChange(after: deadline.addingTimeInterval(-1)) == deadline)
        #expect(state.nextTimeChange(after: deadline) == nil)

        state.receive(.init(type: .snapshot, challenge: challenge, board: CommandGateTests().board()), now: now)
        #expect(state.canAct(now: now) && state.isConnected(now: now))
        #expect(state.nextTimeChange(after: now) == deadline)
        #expect(state.canAct(now: deadline) == false && state.isConnected(now: deadline) == false)
        #expect(state.nextTimeChange(after: deadline.addingTimeInterval(1)) == nil)

        state.refreshFailed()
        #expect(state.nextTimeChange(after: now) == deadline)
    }

    @Test func inboxReadUsesOnlyTheControlFromTheCurrentCompleteSnapshot() throws {
        let state = RemotePhoneState(), now = Date()
        var board = CommandGateTests().board()
        let old = RemoteAction(id: RemoteBoard.inboxReadActionID, kind: .markDone, token: "older")
        board.inboxReadAction = old
        let prior = try #require(board.inboxReadCard)
        #expect(!board.cards.contains(prior))

        let action = RemoteAction(id: RemoteBoard.inboxReadActionID, kind: .markDone, token: "current")
        board.inboxReadAction = action
        board.partial = true
        #expect(board.inboxReadCard == nil)

        board.partial = false
        board.hostSession = UUID()
        let decoded = try JSONDecoder().decode(RemoteBoard.self, from: JSONEncoder().encode(board))
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: decoded), now: now)
        #expect(state.command(card: prior, action: old, now: now) == nil)
        let control = try #require(decoded.inboxReadCard)
        let command = try #require(state.command(card: control, action: action, now: now))
        #expect(command.isInboxRead)
        #expect(command.account == board.account && command.hostSession == board.hostSession)
        #expect(command.token == action.token)
    }

    @Test func onlyACompleteInboxLaneCanEstablishAnEmptyInbox() {
        let state = RemotePhoneState(), now = Date()
        var board = CommandGateTests().board()
        #expect(state.inboxCards == nil)
        state.refreshFailed()
        #expect(state.inboxCards == nil)

        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.inboxCards == nil)

        board.lanes.append(.init(id: .other, cards: []))
        board.partial = true
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.inboxCards == nil)

        board.partial = false
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.inboxCards == [])

        let cached = board.cards
        board.lanes[board.lanes.count - 1].cards = cached
        board.partial = true
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        state.disconnected()
        #expect(state.inboxCards == cached)

        board.account = "another@example.test"
        board.hostSession = UUID()
        board.lanes[board.lanes.count - 1].cards = []
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.inboxCards == nil)
    }

    @Test func presentationUpdatesPreserveTheExactConfirmedAction() throws {
        let state = RemotePhoneState(), now = Date()
        var board = CommandGateTests().board()
        let card = board.cards[0], action = card.actions[0]
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        board.lanes[0].cards[0].presentation = .init(repository: "p", status: "Monitoring", working: false)
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        let command = try #require(state.command(card: card, action: action, now: now))
        #expect(command.actionID == action.id && command.token == action.token)
    }

    @Test func onlyFreshChallengeEnablesActionsAndDisconnectKeepsBoard() {
        let state = RemotePhoneState(), now = Date()
        let board = CommandGateTests().board()
        let challenge = state.challenge()
        state.receive(.init(type: .snapshot, challenge: UUID(), board: board), now: now)
        #expect(!state.canAct(now: now))
        #expect(!state.isConnected(now: now))
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
        #expect(!state.isConnected(now: now.addingTimeInterval(46)))
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

    @Test func refreshKeepsTheConnectionVisibleWhileWriteFreshnessStillExpires() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.isConnected(now: now))
        #expect(!state.isRefreshing(now: now))
        let next = try #require(state.beginRefresh(now: now.addingTimeInterval(25)))
        #expect(state.isRefreshing(now: now.addingTimeInterval(26)))
        #expect(state.isConnected(now: now.addingTimeInterval(46)))
        #expect(!state.canAct(now: now.addingTimeInterval(46)))
        state.receive(.init(type: .snapshot, challenge: next, board: board), now: now.addingTimeInterval(50))
        #expect(state.isConnected(now: now.addingTimeInterval(50)))
        #expect(!state.isRefreshing(now: now.addingTimeInterval(50)))
        #expect(state.canAct(now: now.addingTimeInterval(50)))
    }

    @Test func refreshTimeoutCannotKeepAnAbsentMacConnectedIndefinitely() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        _ = try #require(state.beginRefresh(now: now.addingTimeInterval(25)))
        #expect(!state.isConnected(now: now.addingTimeInterval(71)))
        #expect(!state.isRefreshing(now: now.addingTimeInterval(71)))
        _ = try #require(state.beginRefresh(now: now.addingTimeInterval(75)))
        #expect(!state.isConnected(now: now.addingTimeInterval(76)))
        state.disconnected()
        #expect(!state.isRefreshing(now: now.addingTimeInterval(76)))
    }

    @Test func authenticatedPartialDataAndPendingCommandsDoNotChangeTheConnectionLabel() throws {
        let state = RemotePhoneState(), now = Date()
        var board = CommandGateTests().board()
        board.partial = true
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        #expect(state.isConnected(now: now))
        #expect(!state.canAct(now: now))
        board.partial = false
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let command = try #require(state.command(card: card, action: action, now: now))
        #expect(state.isConnected(now: now))
        #expect(!state.canAct(now: now))
        state.receive(.init(type: .result, result: .init(id: command.id, status: .completed)), now: now)
        #expect(state.isConnected(now: now))
    }

    @Test func failedRefreshMarksTheConnectionUnavailableButKeepsThePendingCommandReceipt() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        let card = try #require(board.cards.first), action = try #require(card.actions.first)
        let command = try #require(state.command(card: card, action: action, now: now))
        _ = state.beginRefresh(now: now)
        state.refreshFailed()
        #expect(!state.isConnected(now: now))
        #expect(!state.isRefreshing(now: now))
        #expect(!state.canAct(now: now))
        #expect(state.board == board)
        #expect(state.pending?.id == command.id)
        state.receive(.init(type: .result, result: .init(id: command.id, status: .completed)), now: now)
        #expect(state.result?.status == .completed)
    }

    @Test func forcedRefreshPausesWritesWithoutFlashingAnAuthenticatedConnection() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        let challenge = try #require(state.beginRefresh(force: true, now: now.addingTimeInterval(1)))
        #expect(state.isConnected(now: now.addingTimeInterval(2)))
        #expect(state.isRefreshing(now: now.addingTimeInterval(2)))
        #expect(!state.canAct(now: now.addingTimeInterval(2)))
        state.receive(.init(type: .snapshot, challenge: challenge, board: board), now: now.addingTimeInterval(3))
        #expect(state.isConnected(now: now.addingTimeInterval(3)))
        #expect(state.canAct(now: now.addingTimeInterval(3)))
        state.disconnected()
        #expect(!state.isConnected(now: now.addingTimeInterval(4)))
    }

    @Test func aSlowSnapshotRequestsImmediateRenewalBeforeTheCurrentLeaseExpires() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        let first = state.challenge(now: now)
        #expect(!state.needsRefresh(now: now.addingTimeInterval(25)))
        state.receive(.init(type: .snapshot, challenge: first, board: board), now: now.addingTimeInterval(35))
        #expect(state.needsRefresh(now: now.addingTimeInterval(35)))
        #expect(state.isConnected(now: now.addingTimeInterval(35)))
        _ = try #require(state.beginRefresh(now: now.addingTimeInterval(35)))
        #expect(state.isConnected(now: now.addingTimeInterval(46)))
        #expect(!state.canAct(now: now.addingTimeInterval(46)))
        #expect(!state.needsRefresh(now: now.addingTimeInterval(46)))
    }

    @Test func anEarlySnapshotWaitsForTheNormalRefreshInterval() {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now.addingTimeInterval(2))
        #expect(!state.needsRefresh(now: now.addingTimeInterval(10)))
        #expect(state.needsRefresh(now: now.addingTimeInterval(25)))
    }

    @Test func repeatedForcedRefreshesCannotExtendConnectionWithoutAnotherHostReply() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        state.receive(.init(type: .snapshot, challenge: state.challenge(now: now), board: board), now: now)
        _ = try #require(state.beginRefresh(force: true, now: now.addingTimeInterval(40)))
        _ = try #require(state.beginRefresh(force: true, now: now.addingTimeInterval(80)))
        #expect(!state.isConnected(now: now.addingTimeInterval(86)))
        #expect(!state.canAct(now: now.addingTimeInterval(86)))
    }

    @Test func aLateSendFailureCannotInvalidateANewerOrAlreadyCompletedRefresh() throws {
        let state = RemotePhoneState(), now = Date(), board = CommandGateTests().board()
        let old = try #require(state.beginRefresh(now: now))
        let current = try #require(state.beginRefresh(force: true, now: now.addingTimeInterval(1)))
        #expect(!state.refreshFailed(challenge: old))
        #expect(state.isRefreshing(now: now.addingTimeInterval(2)))
        state.receive(.init(type: .snapshot, challenge: current, board: board), now: now.addingTimeInterval(3))
        #expect(state.isConnected(now: now.addingTimeInterval(3)))
        #expect(!state.refreshFailed(challenge: current))
        #expect(state.isConnected(now: now.addingTimeInterval(4)))
        #expect(state.canAct(now: now.addingTimeInterval(4)))
    }

}
