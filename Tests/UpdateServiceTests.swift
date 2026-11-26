import Foundation
import Testing

@testable import MergeTether

@Suite("UpdateService")
struct UpdateServiceTests {
    @MainActor @Test func skipsReleaseNotesForTheRelaunchAndShowsThemOnTheNextUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "UpdateServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        func bundle(version: String) throws -> Bundle {
            let app = root.appendingPathComponent("\(version).app")
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try "## \(version)\n\n- Release notes.".write(to: resources.appendingPathComponent("CHANGELOG.md"),
                                                          atomically: true, encoding: .utf8)
            return try #require(Bundle(url: app))
        }

        let oldBundle = try bundle(version: "1.2.0")
        let firstLaunch = UpdateService(defaults: defaults, bundle: oldBundle)
        #expect(!firstLaunch.shouldShowWhatsNew)
        firstLaunch.seedIfNeeded()

        let relaunch = UpdateService(defaults: defaults, bundle: try bundle(version: "2.0.0"))
        #expect(!relaunch.allowsWhatsNew)
        #expect(!relaunch.shouldShowWhatsNew)
        relaunch.loadWhatsNew()
        #expect(relaunch.whatsNewEntry == nil)
        relaunch.seedIfNeeded()

        let updatedBundle = try bundle(version: "2.0.1")
        let afterRestart = UpdateService(defaults: defaults, bundle: updatedBundle)
        #expect(afterRestart.previouslySeenVersion == "2.0.0")
        #expect(afterRestart.allowsWhatsNew)
        #expect(afterRestart.shouldShowWhatsNew)
        afterRestart.loadWhatsNew()
        #expect(afterRestart.whatsNewEntry?.body == "- Release notes.")
        afterRestart.acknowledgeCurrentVersion()

        #expect(!UpdateService(defaults: defaults, bundle: updatedBundle).shouldShowWhatsNew)
    }

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
