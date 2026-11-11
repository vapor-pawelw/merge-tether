import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct PairingTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func invitation() throws -> RemotePairing {
        try .generate(origin: URL(string: "https://relay.example.org")!, access: String(repeating: "B", count: 43), now: date)
    }
    @Test func invitationCarriesOnlyPublicDeviceKeyAndExpiresAtTheBoundary() throws {
        let host = try invitation()
        let phone = try RemotePairing(url: host.deepLink, now: date)
        #expect(phone.origin == host.origin)
        #expect(phone.sessionID == host.sessionID)
        #expect(phone.peerPublicKey == host.publicKey)
        #expect(phone.publicKey != host.publicKey)
        #expect(host.url.query == nil)
        #expect(!host.deepLink.absoluteString.contains(host.privateKey))
        #expect(throws: (any Error).self) { try RemotePairing(url: host.url, now: date.addingTimeInterval(600)) }
        #expect(throws: (any Error).self) { try RemotePairing(url: host.url, now: date.addingTimeInterval(-1)) }
    }
    @Test func oldUnknownMissingAndDuplicateVersionsFailClosed() throws {
        let host = try invitation()
        for replacement in ["v=1", "v=3", "version=2", "v=2&v=2"] {
            let raw = host.deepLink.absoluteString.replacingOccurrences(of: "v=2", with: replacement)
            #expect(throws: (any Error).self) { try RemotePairing(url: URL(string: raw)!, now: date) }
        }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]
        for version in [1, 3] {
            json["version"] = version
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RemotePairing.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
        json.removeValue(forKey: "version")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RemotePairing.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
    @Test func rotationChangesKeysSessionAndRoomAndDoesNotExportPrivateKeys() throws {
        let first = try invitation(), second = try invitation()
        #expect(first.secret != second.secret)
        #expect(first.sessionID != second.sessionID)
        #expect(first.publicKey != second.publicKey)
        #expect(first.room != second.room)
        #expect(!first.url.absoluteString.contains(first.privateKey))
    }
    @Test func rejectsInsecureAndMalformedOrigins() {
        for raw in ["http://relay.example.org", "https://user:password@relay.example.org", "https://relay.example.org/path"] {
            #expect(throws: (any Error).self) { try RemotePairing.generate(origin: URL(string: raw)!, access: String(repeating: "B", count: 43)) }
        }
    }
}
