import Darwin
import Foundation
import Testing
@testable import GitLabTodos

@Suite struct LegacyGUIQueueRetirementTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "GUIQueueRetirement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func write(_ content: String, _ path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    @Test func archivesPendingQueuesAndPreservesClaimsReceiptsAndConfiguration() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("pending", "jobs/one.json", in: root)
        try write("pending Claude", "claude-jobs/two.json", in: root)
        try write("receipt", "receipts/one.json", in: root)
        try write("claim", "claims/three/job.json", in: root)
        try write("configuration", "template.json", in: root)
        #expect(try CodexDesktopRelay.retirePendingGUIJobs(in: root))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "jobs/one.json").path))
        #expect(try String(contentsOf: root.appending(path: "retired-gui-jobs/jobs/one.json"), encoding: .utf8) == "pending")
        #expect(try String(contentsOf: root.appending(path: "retired-gui-jobs/claude-jobs/two.json"), encoding: .utf8) == "pending Claude")
        #expect(try String(contentsOf: root.appending(path: "receipts/one.json"), encoding: .utf8) == "receipt")
        #expect(try String(contentsOf: root.appending(path: "claims/three/job.json"), encoding: .utf8) == "claim")
        #expect(try String(contentsOf: root.appending(path: "template.json"), encoding: .utf8) == "configuration")
        #expect(try CodexDesktopRelay.retirePendingGUIJobs(in: root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "retired-gui-jobs/jobs").path).count == 1)
    }

    @Test func skipsSymlinksAndDirectoriesAndNeverOverwritesPriorArchive() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("new", "jobs/one.json", in: root)
        try write("old", "retired-gui-jobs/jobs/one.json", in: root)
        try write("outside", "outside.json", in: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "jobs/link.json"), withDestinationURL: root.appending(path: "outside.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "jobs/directory.json"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "claude-jobs"), withDestinationURL: root.appending(path: "jobs"))
        #expect(try CodexDesktopRelay.retirePendingGUIJobs(in: root))
        #expect(try String(contentsOf: root.appending(path: "retired-gui-jobs/jobs/one.json"), encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "retired-gui-jobs/jobs").path).count == 2)
        #expect(try String(contentsOf: root.appending(path: "outside.json"), encoding: .utf8) == "outside")
        #expect(try root.appending(path: "jobs/link.json").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "jobs/directory.json").path))
    }

    @Test func busyListenerLockReturnsImmediatelyAndRetiresOnTheNextAttempt() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("pending", "jobs/one.json", in: root)
        let descriptor = open(root.appending(path: ".plugin.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(try !CodexDesktopRelay.retirePendingGUIJobs(in: root))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "jobs/one.json").path))
        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(try CodexDesktopRelay.retirePendingGUIJobs(in: root))
    }
}
