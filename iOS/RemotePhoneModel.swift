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
    var state = RemotePhoneState()
    var paired = false
    var error = false
    private(set) var pairingRevision = UUID()
    var pairingCandidate: RemotePairing?
    private var pairing: RemotePairing?
    private var connection: (any RemotePhoneTransport)?
    private let savePairing: (RemotePairing) throws -> Void
    private let makeConnection: (RemotePairing) throws -> any RemotePhoneTransport
    private var connectionRevision = UUID()
    private var connectingUntil = Date.distantPast
    private var connectionFailed = false
    private let now: () -> Date
    init(
        loadPairing: () throws -> RemotePairing? = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").load() },
        savePairing: @escaping (RemotePairing) throws -> Void = { try RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote").save($0) },
        makeConnection: @escaping (RemotePairing) throws -> any RemotePhoneTransport = { try RemoteConnection(pairing: $0, role: .phone) },
        now: @escaping () -> Date = Date.init
    ) {
        self.savePairing = savePairing; self.makeConnection = makeConnection; self.now = now
        do { pairing = try loadPairing(); paired = pairing != nil } catch { self.error = true }
    }
    func offerPairing(_ raw: String) {
        do {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteProtocolError.invalid }
            pairingCandidate = try RemotePairing(url: url)
            error = false
        } catch { self.error = true }
    }
    @discardableResult func acceptPairing() -> Bool {
        guard let pairing = pairingCandidate else { return false }
        do { try savePairing(pairing) } catch { self.error = true; return false }
        disconnect(); self.pairing = pairing; state = RemotePhoneState(); paired = true; error = false
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
        guard connection == nil, let pairing else { return }
        connectingUntil = now().addingTimeInterval(45); connectionFailed = false; error = false
        do {
            let connection = try makeConnection(pairing)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                if !connected { self.connectionRevision = UUID(); self.state.disconnected() }
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
                self.state.receive(message, now: self.now())
                if message.type == .snapshot, self.state.isConnected(now: self.now()) {
                    self.error = false; self.connectionFailed = false; self.connectingUntil = .distantPast
                    // A slow reply can consume most of its lease; renew before the next timer tick.
                    if self.state.needsRefresh(now: self.now()) { await self.refresh() }
                }
                if message.type == .result { await self.refresh() }
            }
            self.connection = connection; connection.start()
        } catch { self.error = true; connectionFailed = true }
    }
    func disconnect() {
        let old = connection; connection = nil; connectionRevision = UUID()
        old?.stop(); state.disconnected(); connectingUntil = .distantPast
    }
    func refresh(force: Bool = false) async {
        let requestState = state
        guard let connection, let challenge = requestState.beginRefresh(force: force, now: now()) else { return }
        do { try await connection.send(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.commentReviewCapability])) }
        catch {
            guard !Task.isCancelled, self.connection === connection, self.state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) { self.error = true; self.connectionFailed = true }
        }
    }
    func perform(card: RemoteCard, action: RemoteAction) async {
        let requestState = state, revision = connectionRevision
        guard let connection, let command = requestState.command(card: card, action: action, now: now()) else { return }
        do {
            try await connection.send(.init(type: .command, command: command))
        } catch {
            guard self.connection === connection, state === requestState, connectionRevision == revision else { return }
            requestState.disconnected(); return
        }
        while state === requestState && requestState.pending?.id == command.id {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            requestState.checkCommandTimeout(now: now())
        }
    }
}
