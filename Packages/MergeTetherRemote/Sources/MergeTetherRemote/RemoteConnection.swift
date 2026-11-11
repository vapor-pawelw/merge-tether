import Foundation

@MainActor public final class RemoteConnection {
    public var onMessage: (@MainActor (RemoteMessage) async -> Void)?
    public var onPairingEstablished: (@MainActor (RemotePairing) throws -> Void)?
    public var onStatus: (@MainActor (Bool, Bool) -> Void)?
    private let pairing: RemotePairing
    private let role: RemoteCipher.Role
    private var cipher: RemoteCipher!
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var handlers = 0
    private var pongAt = Date.distantPast
    private let heartbeatInterval: Duration
    private let heartbeatTimeout: Duration

    public init(pairing: RemotePairing, role: RemoteCipher.Role, heartbeatInterval: Duration = .seconds(25), heartbeatTimeout: Duration = .seconds(10)) throws {
        self.heartbeatInterval = heartbeatInterval; self.heartbeatTimeout = heartbeatTimeout
        self.pairing = pairing; self.role = role
        cipher = try RemoteCipher(pairing: pairing, role: role, saveEstablishedPairing: { [weak self] established in
            guard let save = self?.onPairingEstablished else { throw RemoteProtocolError.invalid }
            try save(established)
        })
    }
    public func start() {
        stop()
        let generation = self.generation
        loop = Task { [weak self] in await self?.run(generation: generation) }
    }
    public func stop() {
        generation = UUID(); loop?.cancel(); loop = nil
        let old = socket; socket = nil
        old?.cancel(with: .normalClosure, reason: nil)
        onStatus?(false, false)
    }
    public func send(_ message: RemoteMessage) async throws {
        guard let socket else { throw RemoteProtocolError.invalid }
        try await socket.send(.string(cipher.seal(message)))
    }

    // The socket reader must keep processing pong frames while a GitLab action awaits I/O.
    // Writes are serialized by the host command gate; in-flight callbacks are bounded here.
    private func dispatch(_ message: RemoteMessage, generation: UUID) throws {
        guard handlers < 8 else { throw RemoteProtocolError.oversized }
        handlers += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.handlers -= 1 }
            guard self.generation == generation else { return }
            await self.onMessage?(message)
        }
    }

    private func run(generation: UUID) async {
        var delay: Double = 1
        while !Task.isCancelled && self.generation == generation {
            var parts = URLComponents(url: pairing.origin, resolvingAgainstBaseURL: false)!
            // This is the opaque relay's transport version. Native cryptographic
            // invitations and frames independently require protocol v2.
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"; parts.path = "/v1/connect"
            let task = session.webSocketTask(with: parts.url!, protocols: [
                "mt-v1", "access-\(pairing.access)", "room-\(pairing.room)", "role-\(role.rawValue)",
            ])
            task.maximumMessageSize = RemoteCipher.maximumFrameBytes
            socket = task; task.resume(); pongAt = Date()
            onStatus?(true, false)
            let heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await task.send(.string("ping"))
                        try await Task.sleep(for: self?.heartbeatTimeout ?? .seconds(10))
                        guard let self, self.generation == generation else { return }
                        if Date().timeIntervalSince(self.pongAt) > self.heartbeatTimeout.secondsValue * 2 { task.cancel(with: .goingAway, reason: nil); return }
                        try await Task.sleep(for: self.heartbeatInterval - self.heartbeatTimeout)
                    } catch { return }
                }
            }
            do {
                while !Task.isCancelled && self.generation == generation {
                    let raw = try await task.receive()
                    guard self.generation == generation else { break }
                    guard case let .string(wire) = raw else { throw RemoteProtocolError.invalid }
                    if wire == "pong" { pongAt = Date(); continue }
                    if let data = wire.data(using: .utf8), let advisory = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       advisory["relay"] == "peer-offline" { onStatus?(false, false); continue }
                    do {
                        let message = try cipher.open(wire, as: RemoteMessage.self)
                        delay = 1
                        try dispatch(message, generation: generation)
                    } catch RemoteProtocolError.ignored { continue }
                }
            } catch { /* Reconnect below. Command delivery is never retried here. */ }
            heartbeat.cancel()
            guard self.generation == generation else { return }
            socket = nil
            let fatal = [4001, 4008, 4009].contains(task.closeCode.rawValue)
            task.cancel(with: .goingAway, reason: nil)
            onStatus?(false, fatal)
            if fatal { return }
            do { try await Task.sleep(for: .seconds(delay + Double.random(in: 0...0.3))) } catch { return }
            delay = min(delay * 2, 30)
        }
    }
}

private extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
