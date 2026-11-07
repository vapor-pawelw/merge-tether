import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct PairingTests {
    let secret = String(repeating: "A", count: 43)
    let access = String(repeating: "B", count: 43)

    @Test func pairingRoundTripsWithoutPuttingCredentialsInQuery() throws {
        let pair = try RemotePairing(origin: URL(string: "https://relay.example.org")!, secret: secret, access: access)
        #expect(pair.url.query == nil)
        #expect(pair.url.fragment?.contains(secret) == true)
        #expect(try RemotePairing(url: pair.url) == pair)
        #expect(pair.room != secret)
        #expect(pair.room.count == 43)
    }

    @Test func rejectsInsecureAndMalformedOrigins() {
        for raw in ["http://relay.example.org", "https://user:password@relay.example.org", "https://relay.example.org/path"] {
            #expect(throws: (any Error).self) {
                try RemotePairing(origin: URL(string: raw)!, secret: secret, access: access)
            }
        }
    }

    @Test func acceptsNativeDeepLinkForCameraPairing() throws {
        let url = URL(string: "mergetether://pair?relay=https%3A%2F%2Frelay.example.org#v=1&secret=\(secret)&access=\(access)")!
        let pair = try RemotePairing(url: url)
        #expect(pair.origin.host == "relay.example.org")
        #expect(pair.secret == secret)
    }
}
