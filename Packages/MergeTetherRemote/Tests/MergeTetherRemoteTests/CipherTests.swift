import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct CipherTests {
    func pair() throws -> RemotePairing {
        try RemotePairing(origin: URL(string: "https://relay.example.org")!, secret: String(repeating: "A", count: 43), access: String(repeating: "B", count: 43))
    }

    @Test func encryptedPayloadRoundTripsAndRejectsReplay() throws {
        let host = try RemoteCipher(pairing: pair(), role: .host)
        let phone = try RemoteCipher(pairing: pair(), role: .phone)
        let wire = try host.seal(["type": "hello", "challenge": "abc"])
        #expect(!wire.contains("hello"))
        #expect(try phone.open(wire, as: [String: String].self)["challenge"] == "abc")
        #expect(throws: RemoteProtocolError.ignored) { try phone.open(wire, as: [String: String].self) }
    }

    @Test func wrongDirectionAndWrongPairCannotDecrypt() throws {
        let pair = try pair()
        let host = try RemoteCipher(pairing: pair, role: .host)
        let otherPair = try RemotePairing.generate(origin: pair.origin, access: pair.access)
        let other = try RemoteCipher(pairing: otherPair, role: .phone)
        let wire = try host.seal(["type": "private"])
        #expect(throws: (any Error).self) { try other.open(wire, as: [String: String].self) }
        #expect(throws: (any Error).self) { try host.open(wire, as: [String: String].self) }
    }

    @Test func expiryAndAheadClockKeepReplayProtectionAligned() throws {
        let host = try RemoteCipher(pairing: pair(), role: .host)
        let phone = try RemoteCipher(pairing: pair(), role: .phone)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let wire = try host.seal(["type": "snapshot"], now: base.addingTimeInterval(50))
        #expect(try phone.open(wire, as: [String: String].self, now: base)["type"] == "snapshot")
        #expect(throws: RemoteProtocolError.ignored) { try phone.open(wire, as: [String: String].self, now: base.addingTimeInterval(61)) }
        let expired = try host.seal(["type": "snapshot"], now: base)
        #expect(throws: RemoteProtocolError.ignored) { try phone.open(expired, as: [String: String].self, now: base.addingTimeInterval(61)) }
    }

    @Test func decryptsAnActualJavaScriptWebCryptoFrame() throws {
        let phone = try RemoteCipher(pairing: pair(), role: .phone)
        let wire = #"{"v":1,"sender":"host","at":1700000000000,"nonce":"mcFPBHCi8Hmc3i4v","data":"cO41k7PisipR6IvN5krnXaZqgCvOGY9vN0nxfDlzroqjL-XHg6sqR7nMnZqaBEuICHZoj7Nb"}"#
        let value = try phone.open(wire, as: [String: String].self, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(value == ["type": "hello", "challenge": "interop"])
    }
}
