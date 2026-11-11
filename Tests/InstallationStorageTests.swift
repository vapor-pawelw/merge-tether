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
        #expect(local.evidence.path == local.root.appending(path: "Codex Desktop Relay").path)
        #expect(local.runs != release.runs)
        #expect(local.pipelineWork != release.pipelineWork)
        #expect(local.usageFile != release.usageFile)
    }

    @Test("worker environment and recorded helper commands carry the same explicit authority")
    func childAndStandaloneAuthority() {
        let workspace = URL(fileURLWithPath: "/tmp/run")
        let root = URL(fileURLWithPath: "/tmp/local app's data/Codex Desktop Relay")
        let invocation = AssistantJobInvocation(workspace: workspace, evidenceRoot: root)
        #expect(invocation.childEnvironment(["MERGETETHER_STORAGE_ROOT": "/wrong"])["MERGETETHER_STORAGE_ROOT"]
            == root.deletingLastPathComponent().path)
        let storage = InstallationStorage(bundleIdentifier: "com.test.local", home: URL(fileURLWithPath: "/tmp/user's home"))
        #expect(storage.helperEnvironmentPrefix.contains("MERGETETHER_STORAGE_ROOT="))
        #expect(storage.helperEnvironmentPrefix.contains("'\\''"))
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
