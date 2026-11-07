import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct ConnectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MT_RELAY_TEST_URL"] != nil))
    func nativePeersExchangeEncryptedMessagesThroughRealWorker() async throws {
        let origin = try #require(URL(string: ProcessInfo.processInfo.environment["MT_RELAY_TEST_URL"]!))
        let pairing = try RemotePairing.generate(origin: origin, access: ProcessInfo.processInfo.environment["MT_RELAY_TEST_ACCESS"] ?? String(repeating: "A", count: 43))
        let host = try RemoteConnection(pairing: pairing, role: .host, heartbeatInterval: .milliseconds(200), heartbeatTimeout: .milliseconds(100))
        let phone = try RemoteConnection(pairing: pairing, role: .phone)
        defer { phone.stop(); host.stop() }
        let challenge = UUID()
        var received = false
        var board = CommandGateTests().board()
        board.lanes[0].cards[0].detail = String(repeating: "x", count: 100_000)
        host.onMessage = { message in
            if message.type == .hello {
                try? await Task.sleep(for: .milliseconds(800))
                try? await host.send(.init(type: .snapshot, challenge: message.challenge, board: board)) }
        }
        phone.onMessage = { message in received = message.type == .snapshot && message.challenge == challenge && message.board?.cards.first?.detail.count == 100_000 }
        host.start(); phone.start()
        let deadline = ContinuousClock.now + .seconds(6)
        while !received && ContinuousClock.now < deadline {
            try? await phone.send(.init(type: .hello, challenge: challenge))
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(received)
    }
}
