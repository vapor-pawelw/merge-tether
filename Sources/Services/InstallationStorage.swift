import Darwin
import Foundation

/// Runtime storage follows preferences' installation identity. The interactive
/// instance lock and operator-owned relay configuration deliberately stay shared.
struct InstallationStorage: Sendable {
    static let releaseBundleIdentifier = "com.vaporpw.MergeTether"
    static let current = InstallationStorage(bundleIdentifier: Bundle.main.bundleIdentifier)
    static let environmentKey = "MERGETETHER_STORAGE_ROOT"

    let bundleIdentifier: String
    let root: URL

    init(bundleIdentifier: String?, home: URL = .homeDirectory) {
        let identifier = bundleIdentifier ?? Self.releaseBundleIdentifier
        precondition(!identifier.isEmpty && identifier != "." && identifier != ".."
            && identifier.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) })
        self.bundleIdentifier = identifier
        root = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: identifier, directoryHint: .isDirectory)
    }

    var evidence: URL { root.appending(path: "Automation Evidence", directoryHint: .isDirectory) }
    var runs: URL { root.appending(path: "Assistant Runs", directoryHint: .isDirectory) }
    var preparation: URL { root.appending(path: "Assistant Preparation", directoryHint: .isDirectory) }
    var pipelineWork: URL { root.appending(path: "Pipeline Work", directoryHint: .isDirectory) }
    var usageFile: URL { root.appending(path: "Assistant Usage/usage.json") }
    var checkpoints: URL { root.appending(path: "Worker Checkpoints", directoryHint: .isDirectory) }

    struct LegacyRun: Codable, Sendable {
        let id: UUID
        let workingDirectory: String
    }
    struct LegacyHistory: Codable, Sendable {
        let version: Int
        let legacyRoot: String
        let runs: [LegacyRun]
    }
    var legacy: InstallationStorage {
        InstallationStorage(bundleIdentifier: nil, home: root.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent())
    }

    var legacyEvidence: URL { legacy.evidence }
    var legacyRuns: URL { legacy.runs }

    /// Run under the application instance lock before any evidence reader or writer starts.
    func moveAutomationEvidence() throws {
        try moveEvidenceForInstallation()
        if root != legacy.root { try legacy.moveEvidenceForInstallation() }
    }

    private func moveEvidenceForInstallation() throws {
        let source = root.appending(path: "Codex Desktop Relay", directoryHint: .isDirectory)
        guard try isDirectory(source) else { return }
        let archive = root.appending(path: "Retired Desktop Automation", directoryHint: .isDirectory)
        guard try !isDirectory(archive) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: archive]) }

        // Move only stores used by the CLI and the app. Older queue, claim and chat records stay together.
        let stores = ["ai-assessments", "author-feedback-assessments", "display-ai-assessments", "display-comment-origins",
                      "draft-repair-attempts", "follow-up-locks", "follow-up-preflight", "follow-up-proof-recoveries",
                      "follow-up-proof-recovery-attempts", "follow-up-runs", "follow-up-verifications",
                      "follow-up-verifications-archive", "verdicts"]
        let existing = try stores.map { source.appending(path: $0, directoryHint: .isDirectory) }.filter { try isDirectory($0) }
        if !existing.isEmpty {
            if try !isDirectory(evidence) {
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let moves = existing.map { ($0, evidence.appending(path: $0.lastPathComponent, directoryHint: .isDirectory)) }
            for (_, destination) in moves where try isDirectory(destination) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: destination])
            }
            for (original, destination) in moves { try moveDirectory(original, to: destination) }
        }
        try moveDirectory(source, to: archive)
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let failure = errno
            if failure == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSURLErrorKey: url])
        }
        return true
    }

    private func moveDirectory(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let failure = errno
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// Retain undelivered clones/worktrees in place. This index is history only;
    /// it must never be used to import legacy unsigned proof into current gates.
    func preserveLegacyHistory(runs: [LegacyRun]) throws {
        guard root != legacy.root else { return }
        let known = runs.filter {
            URL(fileURLWithPath: $0.workingDirectory).standardizedFileURL
                == legacy.runs.appending(path: $0.id.uuidString).standardizedFileURL
                && $0.workingDirectory == legacy.runs.appending(path: $0.id.uuidString).path
        }
        let history = LegacyHistory(version: 1, legacyRoot: legacy.root.path, runs: known)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appending(path: "legacy-history.json")
        let bytes = try JSONEncoder().encode(history)
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
            if try Data(contentsOf: file) == bytes { return }
        }
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    var helperEnvironmentPrefix: String {
        "/usr/bin/env \(Self.environmentKey)='" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
