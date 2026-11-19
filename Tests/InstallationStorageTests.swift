import Foundation
import Testing
@testable import GitLabTodos

@Suite("Installation storage")
struct InstallationStorageTests {
    @Test("release defaults remain compatible and custom installations have isolated runtime roots")
    func roots() {
        let home = URL(fileURLWithPath: "/tmp/storage-test-home")
        let release = InstallationStorage(bundleIdentifier: nil, home: home)
        let local = InstallationStorage(bundleIdentifier: "com.vaporpw.MergeTether", home: home)
        #expect(release.root.path == "/tmp/storage-test-home/Library/Application Support/com.vaporpw.GitLabTodos")
        #expect(local.root.path == "/tmp/storage-test-home/Library/Application Support/com.vaporpw.MergeTether")
        #expect(local.evidence.path == local.root.appending(path: "Automation Evidence").path)
        #expect(local.runs != release.runs)
        #expect(local.pipelineWork != release.pipelineWork)
        #expect(local.usageFile != release.usageFile)
    }

    @Test("worker environment and recorded helper commands carry the same explicit authority")
    func childAndStandaloneAuthority() {
        let workspace = URL(fileURLWithPath: "/tmp/run")
        let root = URL(fileURLWithPath: "/tmp/local app's data/Automation Evidence")
        let invocation = AssistantJobInvocation(workspace: workspace, evidenceRoot: root)
        #expect(invocation.childEnvironment(["MERGETETHER_STORAGE_ROOT": "/wrong"])["MERGETETHER_STORAGE_ROOT"]
            == root.deletingLastPathComponent().path)
        let storage = InstallationStorage(bundleIdentifier: "com.test.local", home: URL(fileURLWithPath: "/tmp/user's home"))
        #expect(storage.helperEnvironmentPrefix.contains("MERGETETHER_STORAGE_ROOT="))
        #expect(storage.helperEnvironmentPrefix.contains("'\\''"))
    }

    @Test func movesEvidenceForCurrentAndReleaseInstallationsAndSkipsDesktopQueues() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = InstallationStorage(bundleIdentifier: "com.test.local", home: home)
        let release = InstallationStorage(bundleIdentifier: nil, home: home)
        let contents = Data("fixture evidence".utf8)
        for installation in [local, release] {
            let old = installation.root.appending(path: "Codex Desktop Relay")
            let verdicts = old.appending(path: "verdicts")
            let jobs = old.appending(path: "jobs")
            try FileManager.default.createDirectory(at: verdicts, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            try contents.write(to: verdicts.appending(path: "evidence.json"))
            try contents.write(to: jobs.appending(path: "pending.json"))
        }

        try local.moveAutomationEvidence()
        try local.moveAutomationEvidence()

        for installation in [local, release] {
            let old = installation.root.appending(path: "Codex Desktop Relay")
            #expect(try Data(contentsOf: installation.evidence.appending(path: "verdicts/evidence.json")) == contents)
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: installation.root.appending(path: "Retired Desktop Automation/jobs/pending.json").path))
            #expect(!FileManager.default.fileExists(atPath: installation.evidence.appending(path: "jobs").path))
        }
    }

    @Test(arguments: ["destination", "symlink"])
    func rejectsConflictingOrLinkedEvidenceDirectories(_ conflict: String) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = InstallationStorage(bundleIdentifier: nil, home: home)
        let old = installation.root.appending(path: "Codex Desktop Relay/verdicts")
        let destination = installation.evidence.appending(path: "verdicts")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        if conflict == "symlink" {
            try FileManager.default.createSymbolicLink(at: old, withDestinationURL: destination)
        } else {
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        }
        let marker = destination.appending(path: "verified.json")
        let contents = Data("current evidence".utf8)
        try contents.write(to: marker)

        #expect(throws: (any Error).self) { try installation.moveAutomationEvidence() }
        #expect(try Data(contentsOf: marker) == contents)
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
    @Test("legacy preservation indexes only explicitly known exact run paths and leaves data in place")
    func legacyHistoryIndex() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = InstallationStorage(bundleIdentifier: "com.test.local", home: home)
        let legacy = InstallationStorage(bundleIdentifier: nil, home: home)
        let id = UUID()
        let path = legacy.runs.appending(path: id.uuidString).path
        try local.preserveLegacyHistory(runs: [.init(id: id, workingDirectory: path),
            .init(id: UUID(), workingDirectory: legacy.runs.appending(path: "unknown").path)])
        let file = local.root.appending(path: "legacy-history.json")
        let index = try JSONDecoder().decode(InstallationStorage.LegacyHistory.self, from: Data(contentsOf: file))
        #expect(index.runs.map(\.id) == [id])
        #expect(index.runs.first?.workingDirectory == path)
        #expect(index.legacyRoot == legacy.root.path)
        #expect(!FileManager.default.fileExists(atPath: legacy.root.path))
        #expect(!FileManager.default.fileExists(atPath: local.evidence.path))
    }

}
