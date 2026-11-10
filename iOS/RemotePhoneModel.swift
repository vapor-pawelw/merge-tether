import Foundation
import Observation
import MergeTetherRemote

@MainActor @Observable final class RemotePhoneModel {
    var state = RemotePhoneState()
    var paired = false
    var error = false
    var pairingCandidate: RemotePairing?
    private var pairing: RemotePairing?
    private var connection: RemoteConnection?
    private let store = RemotePairingStore(service: "com.vaporpw.MergeTether.iOS.remote")
    private var isPreview: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--remote-preview")
        #else
        false
        #endif
    }
    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--remote-preview") {
            paired = true
            state.receive(.init(type: .snapshot, challenge: state.challenge(), board: RemoteDemo.board))
            return
        }
        #endif
        do { pairing = try store.load(); paired = pairing != nil } catch { self.error = true }
    }
    func offerPairing(_ raw: String) {
        do {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RemoteProtocolError.invalid }
            pairingCandidate = try RemotePairing(url: url)
            error = false
        } catch { self.error = true }
    }
    func acceptPairing() {
        guard let pairing = pairingCandidate else { return }
        do {
            try store.save(pairing)
            disconnect(); self.pairing = pairing; state = RemotePhoneState(); paired = true; error = false
            pairingCandidate = nil; connect()
        } catch { self.error = true }
    }
    func connect() {
        guard !isPreview, connection == nil, let pairing else { return }
        do {
            let connection = try RemoteConnection(pairing: pairing, role: .phone)
            connection.onStatus = { [weak self, weak connection] connected, fatal in
                guard let self, let connection, self.connection === connection else { return }
                if !connected { self.state.disconnected() }
                self.error = fatal
                if connected { Task { await self.refresh() } }
            }
            connection.onMessage = { [weak self, weak connection] message in
                guard let self, let connection, self.connection === connection else { return }
                if message.type == .hostReady { await self.refresh(force: true); return }
                if message.type == .unavailable { self.state.refreshFailed(); self.error = true; return }
                self.state.receive(message)
                if message.type == .snapshot, self.state.isConnected() {
                    self.error = false
                    // A slow reply can consume most of its lease; renew before the next timer tick.
                    if self.state.needsRefresh() { await self.refresh() }
                }
                if message.type == .result { await self.refresh() }
            }
            self.connection = connection; connection.start()
        } catch { self.error = true }
    }
    func disconnect() { connection?.stop(); connection = nil; state.disconnected() }
    func refresh(force: Bool = false) async {
        #if DEBUG
        if isPreview {
            state.receive(.init(type: .snapshot, challenge: state.challenge(), board: RemoteDemo.board)); return
        }
        #endif
        let requestState = state
        guard let connection, let challenge = requestState.beginRefresh(force: force) else { return }
        do { try await connection.send(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.commentReviewCapability])) }
        catch {
            guard !Task.isCancelled, self.connection === connection, self.state === requestState else { return }
            if requestState.refreshFailed(challenge: challenge) { self.error = true }
        }
    }
    func perform(card: RemoteCard, action: RemoteAction) async {
        guard let command = state.command(card: card, action: action) else { return }
        if isPreview { state.receive(.init(type: .result, result: .init(id: command.id, status: .completed))); return }
        do {
            guard let connection else { throw RemoteProtocolError.invalid }
            try await connection.send(.init(type: .command, command: command))
        } catch { state.disconnected(); return }
        while state.pending?.id == command.id {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            state.checkCommandTimeout()
        }
    }
}
