import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct CipherTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func pair() throws -> RemotePairing {
        try .generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "B", count: 43), now: date)
    }
    @Test func authenticatedEnrollmentIsPinnedBeforeDeliveryAndSurvivesInvitationExpiry() throws {
        let invitation = try pair(), phonePair = try RemotePairing(url: invitation.deepLink, now: date)
        var saved: RemotePairing?
        let host = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { saved = $0 })
        let phone = try RemoteCipher(pairing: phonePair, role: .phone, saveEstablishedPairing: { _ in })
        let wire = try phone.seal(["type": "hello"], now: date)
        #expect(try host.open(wire, as: [String: String].self, now: date) == ["type": "hello"])
        #expect(saved?.peerPublicKey == phonePair.publicKey)
        let durablePair = try #require(saved)
        let resumed = try RemoteCipher(pairing: durablePair, role: .host, saveEstablishedPairing: { _ in })
        let later = date.addingTimeInterval(601)
        #expect(try phone.open(resumed.seal(["type": "snapshot"], now: later), as: [String: String].self, now: later)["type"] == "snapshot")
        #expect(try resumed.open(phone.seal(["type": "command"], now: later), as: [String: String].self, now: later)["type"] == "command")
        #expect(throws: RemoteProtocolError.ignored) { try host.open(wire, as: [String: String].self, now: date) }
    }
    @Test func expiredInvitationAndDifferentPhoneCannotEnrollOrReadAnEstablishedSession() throws {
        let invitation = try pair()
        let phonePair = try RemotePairing(url: invitation.url, now: date)
        let otherPair = try RemotePairing(url: invitation.url, now: date)
        let phone = try RemoteCipher(pairing: phonePair, role: .phone, saveEstablishedPairing: { _ in })
        let other = try RemoteCipher(pairing: otherPair, role: .phone, saveEstablishedPairing: { _ in })
        let expired = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { _ in })
        let later = date.addingTimeInterval(601)
        let almostExpired = try phone.seal(["type": "hello"], now: date.addingTimeInterval(599))
        #expect(throws: (any Error).self) { try expired.open(almostExpired, as: [String: String].self, now: date.addingTimeInterval(600)) }
        #expect(throws: (any Error).self) { try expired.open(phone.seal(["type": "hello"], now: later), as: [String: String].self, now: later) }
        let host = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { _ in })
        _ = try host.open(phone.seal(["type": "hello"], now: date), as: [String: String].self, now: date)
        #expect(throws: (any Error).self) { try host.open(other.seal(["type": "hello"], now: date), as: [String: String].self, now: date) }
        #expect(throws: (any Error).self) { try other.open(host.seal(["type": "snapshot"], now: date), as: [String: String].self, now: date) }
    }
    @Test func failedTrustPersistenceDoesNotPinOrDeliverTheMessage() throws {
        let invitation = try pair(), phonePair = try RemotePairing(url: invitation.url, now: date)
        let host = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { _ in throw RemoteProtocolError.invalid })
        let phone = try RemoteCipher(pairing: phonePair, role: .phone, saveEstablishedPairing: { _ in })
        #expect(throws: (any Error).self) { try host.open(phone.seal(["type": "hello"], now: date), as: [String: String].self, now: date) }
        #expect(throws: (any Error).self) { try host.seal(["type": "snapshot"], now: date) }
    }
    @Test func versionSessionRoleAndCiphertextTamperingAreRejected() throws {
        let invitation = try pair(), phonePair = try RemotePairing(url: invitation.url, now: date)
        let phone = try RemoteCipher(pairing: phonePair, role: .phone, saveEstablishedPairing: { _ in })
        let wire = try phone.seal(["type": "hello"], now: date)
        for (field, value) in [("v", 1 as Any), ("v", 3 as Any), ("session", UUID().uuidString as Any), ("sender", "host" as Any)] {
            let host = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { _ in })
            var frame = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as! [String: Any]
            frame[field] = value
            let edited = String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
            #expect(throws: (any Error).self) { try host.open(edited, as: [String: String].self, now: date) }
        }
        let rotated = try RemoteCipher(pairing: pair(), role: .host, saveEstablishedPairing: { _ in })
        #expect(throws: (any Error).self) { try rotated.open(wire, as: [String: String].self, now: date) }
        #expect(throws: (any Error).self) { try phone.open(wire, as: [String: String].self, now: date) }
    }
    @Test func expiryAndAheadClockKeepReplayProtectionAligned() throws {
        let invitation = try pair(), phonePair = try RemotePairing(url: invitation.url, now: date)
        let host = try RemoteCipher(pairing: invitation, role: .host, saveEstablishedPairing: { _ in }), phone = try RemoteCipher(pairing: phonePair, role: .phone, saveEstablishedPairing: { _ in })
        let wire = try phone.seal(["type": "hello"], now: date.addingTimeInterval(50))
        #expect(try host.open(wire, as: [String: String].self, now: date)["type"] == "hello")
        #expect(throws: RemoteProtocolError.ignored) { try host.open(wire, as: [String: String].self, now: date.addingTimeInterval(61)) }
        #expect(throws: RemoteProtocolError.ignored) { try host.open(phone.seal(["type": "hello"], now: date), as: [String: String].self, now: date.addingTimeInterval(61)) }
    }
}
