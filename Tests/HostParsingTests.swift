import Foundation
import Testing
@testable import MergeTether

@Suite("Host parsing")
struct HostParsingTests {
    @Test("extracts gitlab.com from a standard target URL")
    func gitlabCom() {
        let url = URL(string: "https://gitlab.com/acme/frontend/-/merge_requests/1369")
        #expect(GlabService.parseHost(from: url) == "gitlab.com")
    }

    @Test("extracts a self-hosted host")
    func selfHosted() {
        let url = URL(string: "https://gitlab.corp.example.com/acme/thing/-/widgets/1")
        #expect(GlabService.parseHost(from: url) == "gitlab.corp.example.com")
    }

    @Test("returns nil for nil URL")
    func nilURL() {
        #expect(GlabService.parseHost(from: nil) == nil)
    }

    @Test("returns nil for URL without a host")
    func hostless() {
        let url = URL(string: "file:///tmp/x")
        #expect(GlabService.parseHost(from: url) == nil)
    }
}
