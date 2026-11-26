import Foundation
import Observation

/// Tracks the last version the user has seen and parses CHANGELOG.md to
/// surface "What's New" content on upgrade. Release-time — not live update
/// checking: we don't hit the network, we just compare the bundled version
/// to a UserDefaults flag.
@MainActor
@Observable
final class UpdateService {
    private let defaults: UserDefaults
    private let bundle: Bundle

    private(set) var currentVersion: String
    private(set) var previouslySeenVersion: String?
    private(set) var whatsNewEntry: ChangelogEntry?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        self.currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.previouslySeenVersion = defaults.string(forKey: Key.lastSeenVersion)
    }

    var allowsWhatsNew: Bool { currentVersion != "2.0.0" }

    /// Opens release notes when an eligible version differs from the version the user saw.
    var shouldShowWhatsNew: Bool {
        guard allowsWhatsNew, let previouslySeenVersion else { return false }
        return previouslySeenVersion != currentVersion
    }

    /// Load + parse the changelog entry matching `currentVersion`. Called
    /// once on launch; safe to call again.
    func loadWhatsNew() {
        guard allowsWhatsNew, let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            whatsNewEntry = nil
            return
        }
        whatsNewEntry = Self.parseEntry(for: currentVersion, in: contents)
    }

    /// Marks the current version as seen. Called when the user dismisses the
    /// What's New window, or silently on first launch so upgrading from a
    /// pre-UpdateService build doesn't show a stale "new".
    func acknowledgeCurrentVersion() {
        defaults.set(currentVersion, forKey: Key.lastSeenVersion)
        previouslySeenVersion = currentVersion
    }

    /// Record a first launch or the MergeTether debut as the baseline for future updates.
    func seedIfNeeded() {
        if previouslySeenVersion != currentVersion && (previouslySeenVersion == nil || !allowsWhatsNew) {
            acknowledgeCurrentVersion()
        }
    }

    struct ChangelogEntry: Equatable, Sendable {
        let version: String
        let body: String
    }

    /// Pure parser: grabs the `## <version>` section of a Keep-a-Changelog
    /// document and returns its body stripped of surrounding whitespace.
    /// Matches against both `## 1.2.3` and `## 1.2.3 - 2026-05-01` headings.
    nonisolated static func parseEntry(for version: String, in contents: String) -> ChangelogEntry? {
        let lines = contents.components(separatedBy: "\n")
        var capturing = false
        var body: [String] = []
        for line in lines {
            if line.hasPrefix("## ") {
                if capturing { break }
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let firstToken = heading.split(separator: " ").first.map(String.init) ?? heading
                if firstToken == version {
                    capturing = true
                    continue
                }
            }
            if capturing {
                body.append(line)
            }
        }
        let trimmed = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard capturing, !trimmed.isEmpty else { return nil }
        return ChangelogEntry(version: version, body: trimmed)
    }

    private enum Key {
        static let lastSeenVersion = "lastSeenVersion"
    }
}
