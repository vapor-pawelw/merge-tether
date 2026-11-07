import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct PairingStoreTests {
    @Test func pairingPersistsAndReplacementRevokesTheOldRoomLocally() throws {
        let service = "MergeTetherRemoteTests.\(UUID())"
        let store = RemotePairingStore(service: service)
        defer { try? store.remove() }
        let first = try RemotePairing.generate(origin: URL(string: "https://example.org")!, access: String(repeating: "A", count: 43))
        try store.save(first)
        #expect(try RemotePairingStore(service: service).load() == first)
        let second = try RemotePairing.generate(origin: first.origin, access: first.access)
        try store.save(second)
        #expect(try store.load() == second)
        try store.remove()
        #expect(try store.load() == nil)
    }
}
