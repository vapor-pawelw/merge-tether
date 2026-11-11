import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct RelayConfigurationTests {
    @Test func normalizesOnlyEquivalentHTTPSOrigins() throws {
        let configuration = RemoteRelayConfiguration(rawOrigin: " HTTPS://Relay.Example.org:443/\n")
        #expect(configuration.status == .configured)
        #expect(configuration.origin?.absoluteString == "https://relay.example.org")
        #expect(configuration.accepts(origin: URL(string: "https://RELAY.example.org:443/")!))
        #expect(!configuration.accepts(origin: URL(string: "https://relay.example.org:8443")!))
        #expect(!configuration.accepts(origin: URL(string: "https://relay.example.org.evil.test")!))
        #expect(!configuration.accepts(origin: URL(string: "https://relay-example.org")!))
    }

    @Test(arguments: ["http://relay.example.org", "http://localhost", "https://user@relay.example.org",
        "https://relay.example.org/path", "https://relay.example.org?", "https://relay.example.org#",
        "https://relay.example.org:0", "https://relay.example.org:65536", "https://%72elay.example.org",
        "https://relay.example.org\\@evil.test", "https://relay.example.org\n.evil.test", "$(UNSET_ORIGIN)"])
    func rejectsUnsafeOrNonOriginConfiguration(_ raw: String) {
        let configuration = RemoteRelayConfiguration(rawOrigin: raw)
        #expect(configuration.status == .invalid)
        #expect(configuration.origin == nil)
        #expect(!configuration.accepts(origin: URL(string: "https://relay.example.org")!))
    }

    @Test(arguments: [nil, "", " \n"] as [String?])
    func missingConfigurationCannotAuthorizeAnyRelay(_ raw: String?) {
        let configuration = RemoteRelayConfiguration(rawOrigin: raw)
        #expect(configuration.status == .missing)
        #expect(!configuration.accepts(origin: URL(string: "https://relay.example.org")!))
    }

    @Test func customHTTPSPortRemainsPartOfTheOrigin() {
        let configuration = RemoteRelayConfiguration(rawOrigin: "https://relay.example.org:8443/")
        #expect(configuration.origin?.absoluteString == "https://relay.example.org:8443")
        #expect(configuration.accepts(origin: URL(string: "https://relay.example.org:8443")!))
        #expect(!configuration.accepts(origin: URL(string: "https://relay.example.org")!))
    }
}
