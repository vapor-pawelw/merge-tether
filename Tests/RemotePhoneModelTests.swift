import Foundation
import Testing
import MergeTetherRemote

@MainActor @Suite struct RemotePhoneModelTests {
    @Test func refreshUsesExistingTransportAndCoalescesOutstandingRequests() async throws {
        let fixture = try PhoneFixture()
        let model = fixture.model
        model.connect()
        await model.refresh()
        await model.refresh()
        #expect(fixture.transports.count == 1)
        #expect(fixture.transports[0].sent.map(\.type) == [.hello])
        await fixture.reply()
        #expect(model.state.isConnected(now: fixture.date))
        await model.refresh()
        #expect(fixture.transports[0].sent.map(\.type) == [.hello, .hello])
        #expect(fixture.saved.isEmpty)
    }
    @Test func oldCommandSendFailureCannotDisconnectANewConnection() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        old.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while old.sendBarrier == nil { await Task.yield() }
        // when
        model.reconnect()
        await model.refresh(); await fixture.reply()
        #expect(model.state.result?.status == .uncertain)
        old.sendBarrier?.resume(throwing: RemoteProtocolError.invalid)
        await sending.value
        // then
        #expect(model.state.isConnected(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello])
        #expect(model.state.result?.status == .uncertain)
    }

    @Test func savedPairingConnectsThenTimesOutWithoutLosingTrustAndAcceptsALateSnapshot() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        #expect(model.paired)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        fixture.date += 46
        #expect(model.connectionStatus(now: fixture.date) == .offline)
        #expect(!model.state.canAct(now: fixture.date))
        await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(fixture.saved.isEmpty)
    }

    @Test func reconnectReplacesOnlyTransportCoalescesAndRequiresAFreshSnapshot() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let board = try #require(model.state.board), old = fixture.transports[0]
        // when
        model.reconnect(); model.reconnect(); model.connect()
        // then
        #expect(old.stopped)
        #expect(fixture.transports.count == 2)
        #expect(model.state.board == board)
        #expect(!model.state.canAct(now: fixture.date))
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        #expect(fixture.saved.isEmpty)
        await model.refresh(); await fixture.reply()
        #expect(model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello])
    }

    @Test func obsoleteCallbacksAndQueuedStatusRefreshCannotAffectReplacement() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], callback = old.onMessage, status = old.onStatus
        status?(true, false) // Schedules a refresh that must remain bound to this transport.
        // when
        model.reconnect()
        status?(false, true)
        await callback?(.init(type: .unavailable))
        await callback?(.init(type: .snapshot, challenge: old.sent.last?.challenge, board: fixture.board))
        await Task.yield()
        // then
        #expect(!model.error)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
        #expect(!model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.isEmpty)
    }

    @Test func foregroundRestartsAfterBackgroundAndOldSendFailureOnSameTransportIsIgnored() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let transport = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        transport.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while transport.sendBarrier == nil { await Task.yield() }
        // when: automatic socket loss/recovery can reuse the same transport object.
        transport.onStatus?(false, false)
        transport.suspendSend = false
        await model.refresh(); await fixture.reply()
        transport.sendBarrier?.resume(throwing: RemoteProtocolError.invalid)
        await sending.value
        // then
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(model.state.result?.status == .uncertain)
        model.disconnect(); model.connect(); model.connect()
        #expect(fixture.transports.count == 2)
        #expect(model.connectionStatus(now: fixture.date) == .connecting)
    }

    @Test func successfulTrustClosesPairingEvenWhenTransportCreationFailsAndReplacementClearsOldBoard() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let previousState = model.state
        fixture.failConnection = true
        let replacement = try RemotePairing.generate(origin: URL(string: "https://other.example.org")!, access: String(repeating: "B", count: 43))
        model.offerPairing(replacement.deepLink.absoluteString)
        // when
        let oldMessage = fixture.transports[0].onMessage
        let accepted = model.acceptPairing()
        await oldMessage?(.init(type: .unavailable))
        // then
        #expect(accepted)
        #expect(model.paired)
        #expect(model.pairingCandidate == nil)
        #expect(model.state !== previousState)
        #expect(model.state.board == nil)
        #expect(fixture.saved == [replacement])
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        fixture.failConnection = false
        model.reconnect(); await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
    }

    @Test func rejectedPairingSaveKeepsExistingBoardAndConnection() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let board = model.state.board
        fixture.failSave = true
        model.offerPairing(fixture.pairing.deepLink.absoluteString)
        let accepted = model.acceptPairing()
        #expect(!accepted)
        #expect(model.state.board == board)
        #expect(!fixture.transports[0].stopped)
        #expect(model.pairingCandidate != nil)
    }

    @Test func unpairedStartupAndReconnectNeverCreateATransport() throws {
        var connections = 0
        let model = RemotePhoneModel(loadPairing: { nil }, savePairing: { _ in Issue.record("Unexpected pairing write") },
            makeConnection: { _ in connections += 1; return PhoneTransport() })
        model.connect(); model.reconnect()
        #expect(model.connectionStatus() == .unpaired)
        #expect(connections == 0)
    }

    @Test func reconnectKeepsPendingCommandUncertainAndIgnoresItsLateResultWithoutReplay() async throws {
        // given
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh(); await fixture.reply()
        let old = fixture.transports[0], card = try #require(model.state.board?.cards.first)
        old.suspendSend = true
        let sending = Task { await model.perform(card: card, action: card.actions[0]) }
        while old.sendBarrier == nil { await Task.yield() }
        let command = try #require(model.state.pending), callback = old.onMessage
        await callback?(.init(type: .accepted, result: .init(id: command.id, status: .running)))
        // when
        model.reconnect()
        old.sendBarrier?.resume()
        await sending.value
        await model.refresh(); await fixture.reply()
        await callback?(.init(type: .result, result: .init(id: command.id, status: .completed)))
        await model.perform(card: card, action: card.actions[0])
        // then
        #expect(model.state.result == .init(id: command.id, status: .uncertain))
        #expect(!model.state.canAct(now: fixture.date))
        #expect(fixture.transports[1].sent.map(\.type) == [.hello])
        model.state.acknowledgeResult()
        #expect(model.state.canAct(now: fixture.date))
    }

    @Test func expiredOrPartialSnapshotsNeverGrantWritePermission() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect(); await model.refresh()
        fixture.date += 46
        await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .offline)
        #expect(!model.state.canAct(now: fixture.date))
        await model.refresh()
        var board = fixture.board; board.partial = true
        let transport = fixture.transports[0]
        await transport.onMessage?(.init(type: .snapshot, challenge: transport.sent.last?.challenge, board: board))
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        #expect(!model.state.canAct(now: fixture.date))
    }

    @Test func transportFailureIsVisibleAndExplicitReconnectCanRecover() async throws {
        let fixture = try PhoneFixture(), model = fixture.model
        model.connect()
        fixture.transports[0].onStatus?(false, true)
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        model.reconnect(); await model.refresh(); await fixture.reply()
        #expect(model.connectionStatus(now: fixture.date) == .connected)
        await fixture.transports[1].onMessage?(.init(type: .unavailable))
        #expect(model.connectionStatus(now: fixture.date) == .failed)
        #expect(!model.state.canAct(now: fixture.date))
    }

}

@MainActor private final class PhoneFixture {
    var date = Date()
    var transports: [PhoneTransport] = []
    var failSave = false
    var failConnection = false
    var saved: [RemotePairing] = []
    let pairing: RemotePairing
    lazy var model = RemotePhoneModel(loadPairing: { self.pairing }, savePairing: { if self.failSave { throw RemoteProtocolError.invalid }; self.saved.append($0) },
        makeConnection: { _ in if self.failConnection { throw RemoteProtocolError.invalid }; let value = PhoneTransport(); self.transports.append(value); return value }, now: { self.date })
    init() throws {
        pairing = try .generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "A", count: 43))
    }
    var board: RemoteBoard {
        .init(hostSession: UUID(), account: "fixture", lanes: [.init(id: .own, cards: [
            .init(id: "card", title: "Fixture", project: "example", url: nil, head: "abc", actions: [.init(id: "approve", kind: .approve, token: "token")])
        ])])
    }
    func reply() async {
        let transport = transports.last!
        await transport.onMessage?(.init(type: .snapshot, challenge: transport.sent.last?.challenge, board: board))
    }
}

@MainActor private final class PhoneTransport: RemotePhoneTransport {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)?
    var onStatus: (@MainActor (Bool, Bool) -> Void)?
    var sent: [RemoteMessage] = []
    var stopped = false
    var sendBarrier: CheckedContinuation<Void, any Error>?
    var suspendSend = false
    func start() {}
    func stop() { stopped = true; onStatus?(false, false) }
    func send(_ message: RemoteMessage) async throws {
        sent.append(message)
        if suspendSend { try await withCheckedThrowingContinuation { sendBarrier = $0 } }
    }
}
