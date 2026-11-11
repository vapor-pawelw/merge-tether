import Foundation
import Observation
import MergeTetherRemote

@MainActor protocol RemotePhoneTransport: AnyObject {
    var onMessage: (@MainActor (RemoteMessage) async -> Void)? { get set }
    var onStatus: (@MainActor (Bool, Bool) -> Void)? { get set }
    func start()
    func stop()
    func send(_ message: RemoteMessage) async throws
}
extension RemoteConnection: RemotePhoneTransport {}

enum RemotePhoneConnectionStatus { case unpaired, connecting, connected, offline, failed }

@MainActor @Observable final class RemotePhoneModel {
    let relayConfiguration: RemoteRelayConfiguration
    private(set) var relayMismatch = false
    var state = RemotePhoneState()
    var paired = false
    var error = false
    private(set) var pairingRevision = UUID()
    var pairingCandidate: RemotePairing?
    private var pairing: RemotePairing?
    private var connection: (any RemotePhoneTransport)?
    private let savePairing: (RemotePairing) throws -> Void
    private let saveRecovery: (RemoteCommandRecovery) throws -> Void
    private let removeRecovery: () throws -> Void
    private var recovery: RemoteCommandRecovery?
    private var recoveryUnavailable = false
    private var shouldRecoverCommand = false
    private var receiptChallenge: UUID?
    private var receiptRevision: UUID?
    private let makeConnection: (RemotePairing) throws -> any RemotePhoneTransport
    private var connectionRevision = UUID()
    private struct ApprovalConfirmation {
        let id: UUID
        let card: RemoteCard
        let action: RemoteAction
        let hostSession: UUID
        let account: String
        let connectionRevision: UUID
        let state: RemotePhoneState
        let expiresAt: Date
    }
    private var approvalConfirmation: ApprovalConfirmation?
    private var connectingUntil = Date.distantPast
    private var connectionFailed = false
    private let now: () -> Date
    init(
        relayConfiguration: RemoteRelayConfiguration = .bundled(),
        loadPairing: () throws -> RemotePairing? = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").load() },
        savePairing: @escaping (RemotePairing) throws -> Void = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").save($0) },
        loadRecovery: () throws -> RemoteCommandRecovery? = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").load() },
        saveRecovery: @escaping (RemoteCommandRecovery) throws -> Void = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").save($0) },
        removeRecovery: @escaping () throws -> Void = { try RemoteCommandRecoveryStore(service: "com.vaporpw.MergeTether.iOS.remote").remove() },
        makeConnection: @escaping (RemotePairing) throws -> any RemotePhoneTransport = { try RemoteConnection(pairing: $0, role: .phone) },
        now: @escaping () -> Date = Date.init
    ) {
        self.relayConfiguration = relayConfiguration
        self.savePairing = savePairing; self.makeConnection = makeConnection; self.now = now
        self.saveRecovery = saveRecovery; self.removeRecovery = removeRecovery
        guard relayConfiguration.status == .configured else { bindResultAcknowledgement(); return }
        do {
            let loaded = try loadPairing()
            guard loaded == nil || loaded?.role == .phone else { throw RemoteProtocolError.invalid }
            if let loaded, !relayConfiguration.accepts(origin: loaded.origin) {
                relayMismatch = true; bindResultAcknowledgement(); return
            }
            pairing = loaded; paired = loaded != nil
            if let loaded, let previous = try loadRecovery(), previous.pairingSession == loaded.sessionID {
                recovery = previous; shouldRecoverCommand = true
                state.recoverResult(.init(id: previous.command.id, status: .uncertain))
            }
        } catch { self.error = true; recoveryUnavailable = true }
        bindResultAcknowledgement()
    }
    func offerPairing(_ raw: String) {
        do {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteProtocolError.invalid }
            let candidate = try RemotePairing(url: url, now: now())
            guard relayConfiguration.accepts(origin: candidate.origin) else {
                pairingCandidate = nil; relayMismatch = true; error = true; return
            }
            pairingCandidate = candidate; relayMismatch = false; error = false
        } catch { pairingCandidate = nil; self.error = true }
    }
    @discardableResult func acceptPairing() -> Bool {
        guard let pairing = pairingCandidate, pairing.role == .phone, pairing.invitationIsValid(now: now()),
              relayConfiguration.accepts(origin: pairing.origin) else {
            error = true; return false
        }
        do { try savePairing(pairing) } catch { self.error = true; return false }
        disconnect(); self.pairing = pairing; state = RemotePhoneState(); paired = true; error = false
        recovery = nil; shouldRecoverCommand = false; recoveryUnavailable = false; relayMismatch = false
        bindResultAcknowledgement()
        pairingCandidate = nil; pairingRevision = UUID(); connect()
        // Trust was saved even if the transport cannot start yet.
        return true
    }
    func connectionStatus(now: Date = Date()) -> RemotePhoneConnectionStatus {
        guard paired else { return .unpaired }
        if connectionFailed { return .failed }
        if state.isConnected(now: now) { return .connected }
        if now < connectingUntil { return .connecting }
        return .offline
    }
    func reconnect() {
        guard paired, connectionStatus(now: now()) != .connecting else { return }
        disconnect(); connect()
    }
    func connect() {
        guard connection == nil, let pairing, relayConfiguration.accepts(origin: pairing.origin) else { return }
        connectingUntil = now().addingTimeInterval(45); connectionFailed = false; error = false
        do {
            let connection = try makeConnection(pairing)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                if !connected {
                    self.connectionRevision = UUID(); self.cancelApproval(); self.state.disconnected()
                    self.shouldRecoverCommand = self.recovery != nil
                    self.receiptChallenge = nil; self.receiptRevision = nil
                }
                self.error = fatal; self.connectionFailed = fatal
                if connected {
                    let revision = self.connectionRevision
                    Task { [weak self, weak connection] in
                        guard let self, let connection, self.connection === connection, self.connectionRevision == revision else { return }
                        await self.refresh()
                    }
                }
            }
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection, self.connection === connection else { return }
                if message.type == .hostReady { await self.refresh(force: true); return }
                if message.type == .unavailable { self.state.refreshFailed(); self.error = true; self.connectionFailed = true; return }
                if message.type == .receiptResult {
                    guard let result = message.result, result.id == self.recovery?.command.id,
                          let challenge = self.receiptChallenge, message.challenge == challenge,
                          self.receiptRevision == self.connectionRevision,
                          self.state.board?.account == self.recovery?.command.account else { return }
                    self.receiptChallenge = nil; self.receiptRevision = nil
                    self.state.recoverResult(result)
                    self.shouldRecoverCommand = result.status == .running
                    return
                }
                self.state.receive(message, now: self.now())
                if message.type == .snapshot, self.state.isConnected(now: self.now()) {
                    self.error = self.recoveryUnavailable; self.connectionFailed = false; self.connectingUntil = .distantPast
                    await self.recoverLastCommand()
                    // A slow reply can consume most of its lease; renew before the next timer tick.
                    if self.state.needsRefresh(now: self.now()) { await self.refresh() }
                }
                if message.type == .result {
                    if let result = message.result, result == self.state.result { self.shouldRecoverCommand = false }
                    await self.refresh()
                }
            }
            self.connection = connection; connection.start()
        } catch { self.error = true; connectionFailed = true }
    }
    func disconnect() {
        let old = connection; connection = nil; connectionRevision = UUID()
        old?.stop(); cancelApproval(); state.disconnected(); connectingUntil = .distantPast
        shouldRecoverCommand = recovery != nil; receiptChallenge = nil; receiptRevision = nil
    }
    func refresh(force: Bool = false) async {
        let requestState = state
        guard let connection, let challenge = requestState.beginRefresh(force: force, now: now()) else { return }
        do { try await connection.send(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.commentReviewCapability, RemoteMessage.mergeActionsCapability])) }
        catch {
            guard !Task.isCancelled, self.connection === connection, self.state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) { self.error = true; self.connectionFailed = true }
        }
    }
    func prepareApproval(card: RemoteCard, action: RemoteAction) -> UUID? {
        cancelApproval()
        guard connection != nil, !recoveryUnavailable, recovery == nil, action.kind == .approve, card.head != nil,
              state.canAct(now: now()), let board = state.board,
              board.cards.contains(where: { $0 == card && $0.actions.contains(action) }) else { return nil }
        let id = UUID()
        approvalConfirmation = .init(id: id, card: card, action: action, hostSession: board.hostSession,
            account: board.account, connectionRevision: connectionRevision, state: state, expiresAt: now().addingTimeInterval(30))
        return id
    }
    func cancelApproval() { approvalConfirmation = nil }
    func perform(card: RemoteCard, action: RemoteAction, approvalID: UUID? = nil) async {
        if action.kind == .approve {
            let confirmation = approvalConfirmation
            cancelApproval()
            guard let confirmation, confirmation.id == approvalID, confirmation.card == card, confirmation.action == action,
                  confirmation.state === state, confirmation.connectionRevision == connectionRevision, now() < confirmation.expiresAt,
                  state.board?.hostSession == confirmation.hostSession, state.board?.account == confirmation.account,
                  state.board?.cards.contains(card) == true else { return }
        }
        let requestState = state, revision = connectionRevision
        guard !recoveryUnavailable, recovery == nil, let pairing, let connection,
              let command = requestState.command(card: card, action: action, now: now()) else { return }
        let pending = RemoteCommandRecovery(pairingSession: pairing.sessionID, command: command)
        do { try saveRecovery(pending); recovery = pending }
        catch {
            self.error = true; requestState.recoverResult(.init(id: command.id, status: .failed)); return
        }
        do {
            try await connection.send(.init(type: .command, command: command))
        } catch {
            guard self.connection === connection, state === requestState, connectionRevision == revision else { return }
            requestState.disconnected(); shouldRecoverCommand = true; return
        }
        while state === requestState && requestState.pending?.id == command.id {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            requestState.checkCommandTimeout(now: now())
        }
        if state === requestState, requestState.result?.id == command.id, requestState.result?.status == .uncertain {
            shouldRecoverCommand = true
        }
    }
    private func recoverLastCommand() async {
        guard shouldRecoverCommand, let recovery, let pairing, recovery.pairingSession == pairing.sessionID,
              let connection else { return }
        guard state.board?.account == recovery.command.account else {
            state.recoverResult(.init(id: recovery.command.id, status: .uncertain)); return
        }
        let challenge = UUID(), revision = connectionRevision
        receiptChallenge = challenge; receiptRevision = revision
        do { try await connection.send(.init(type: .receipt, challenge: challenge, command: recovery.command)) }
        catch {
            guard self.connection === connection, connectionRevision == revision, receiptChallenge == challenge else { return }
            self.error = true
        }
    }
    private func bindResultAcknowledgement() {
        state.onResultAcknowledgement = { [weak self] result in
            guard let self, self.recovery?.command.id == result.id else { return }
            guard result.status != .running else { throw RemoteProtocolError.invalid }
            do { try self.removeRecovery() }
            catch { self.error = true; throw error }
            self.recovery = nil; self.shouldRecoverCommand = false
        }
    }

}
