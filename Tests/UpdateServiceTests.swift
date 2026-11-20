import Foundation
import Testing

@testable import MergeTether

@Suite("UpdateService")
struct UpdateServiceTests {
    @Test("parses the matching version section and stops at the next heading")
    func parseMatchingSection() {
        let changelog = """
        # Changelog

        ## Unreleased

        - Work in progress.

        ## 0.2.0 - 2026-05-10

        ### Features

        - Adds the widget.

        ## 0.1.0 - 2026-04-01

        - Initial release.
        """

        let entry = UpdateService.parseEntry(for: "0.2.0", in: changelog)
        #expect(entry?.version == "0.2.0")
        #expect(entry?.body.contains("Adds the widget.") == true)
        #expect(entry?.body.contains("Initial release.") == false)
    }

    @Test("returns nil when the version is absent")
    func parseMissingSection() {
        let changelog = """
        ## 0.1.0

        - Initial release.
        """
        #expect(UpdateService.parseEntry(for: "2.0.0", in: changelog) == nil)
    }

    @Test("matches the version token even when followed by a date")
    func parseVersionWithDate() {
        let changelog = """
        ## 1.0.0 - 2026-06-01

        - Shipped it.
        """
        let entry = UpdateService.parseEntry(for: "1.0.0", in: changelog)
        #expect(entry != nil)
        #expect(entry?.body == "- Shipped it.")
    }

    @Test("trims trailing whitespace in the captured section")
    func parseTrimsWhitespace() {
        let changelog = """
        ## 0.3.0


        - Entry.


        """
        let entry = UpdateService.parseEntry(for: "0.3.0", in: changelog)
        #expect(entry?.body == "- Entry.")
    }
}
