import Foundation
import Testing
@testable import GitLabTodos

@Suite("Existing pipeline work")
struct ExistingPipelineWorkDetectorTests {
    @Test("failed active open and owner mkdir roll back only the new admission")
    func admissionDirectoryFailures() throws {
        try assertAdmissionRollsBack(.init(openActive: { _ in throw POSIXError(.EMFILE) }))
        try assertAdmissionRollsBack(.init(createOwner: { _, _ in throw POSIXError(.ENOSPC) }))
    }

    @Test("failed empty and partial metadata writes leave no new reservation or receipt")
    func admissionMetadataFailures() throws {
        try assertAdmissionRollsBack(.init(writeMetadata: { _, _ in throw POSIXError(.ENOSPC) }))
        try assertAdmissionRollsBack(.init(writeMetadata: { descriptor, bytes in
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: bytes.prefix(7))
            throw POSIXError(.ENOSPC)
        }))
    }

    @Test("failed admission never removes a preexisting unknown external reservation")
    func failedAdmissionPreservesExistingReservation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root,
            admissionIO: .init(createOwner: { _, _ in throw POSIXError(.ENOSPC) },
                               writeMetadata: { _, _ in throw POSIXError(.ENOSPC) }))
        let candidate = key(pipelineID: 12)
        let active = try detector.externalRegistrationURL(for: candidate)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let unknown = active.appending(path: "external-owner.txt")
        let bytes = Data("do not remove".utf8)
        try bytes.write(to: unknown)
        #expect(try detector.registerRun(for: candidate) == nil)
        #expect(try Data(contentsOf: unknown) == bytes)
        #expect(detector.hasActiveReservation(for: candidate))
        #expect(!FileManager.default.fileExists(atPath: active.deletingLastPathComponent()
            .appending(path: "pipeline-12").path))
    }

    @Test("admission rollback preserves a replacement empty active directory")
    func admissionRollbackPreservesReplacement() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = key(pipelineID: 12)
        let active = try ExistingPipelineWorkDetector(directory: root).externalRegistrationURL(for: candidate)
        let moved = active.deletingLastPathComponent().appending(path: "moved-original")
        let detector = ExistingPipelineWorkDetector(directory: root, admissionIO: .init(openActive: { _ in
            try FileManager.default.moveItem(at: active, to: moved)
            try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
            throw POSIXError(.EMFILE)
        }))
        #expect(throws: POSIXError.self) { try detector.registerRun(for: candidate) }
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: active.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: active.deletingLastPathComponent()
            .appending(path: "pipeline-12").path))
    }

    private func assertAdmissionRollsBack(_ io: ExistingPipelineWorkDetector.AdmissionIO) throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = key(pipelineID: 12)
        let failing = ExistingPipelineWorkDetector(directory: root, admissionIO: io)
        #expect(throws: POSIXError.self) { try failing.registerRun(for: candidate) }
        #expect(!failing.hasActiveReservation(for: candidate))
        #expect(failing.status(for: candidate) == .unverified)
        let healthy = ExistingPipelineWorkDetector(directory: root)
        let optionalRetry = try healthy.registerRun(for: candidate)
        let retry = try #require(optionalRetry)
        try healthy.finishHandoff(for: retry)
    }

    @Test("legacy receipts and unknown reservations block duplicate work without becoming new ownership")
    func legacyDeduplicationIsReadOnly() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ExistingPipelineWorkDetector(directory: root.appending(path: "legacy"))
        let current = ExistingPipelineWorkDetector(directory: root.appending(path: "current"), legacyDirectory: legacy.directory)
        let first = key(pipelineID: 12)
        #expect(try legacy.registerHandoff(for: first))
        #expect(current.hasActiveReservation(for: first))
        #expect(try current.registerRun(for: first, explicitRetry: true) == nil)
        try legacy.finishHandoff(for: first)
        #expect(current.status(for: first) == .registered)
        #expect(try current.registerRun(for: first) == nil)
        #expect(!FileManager.default.fileExists(atPath: current.directory.path))
        let optionalRetried = try current.registerRun(for: first, explicitRetry: true)
        let retried = try #require(optionalRetried)
        try current.finishHandoff(for: retried)
        #expect(legacy.status(for: first) == .registered)
        #expect(!legacy.hasActiveReservation(for: first))
    }

    @Test("a missing registration is unverified and an external MR claim covers later pipelines")
    func externalRegistration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root)
        let first = key(pipelineID: 12)
        let next = key(pipelineID: 13)
        #expect(detector.status(for: first) == .unverified)

        let marker = try detector.externalRegistrationURL(for: first)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        #expect(detector.status(for: next) == .registered)
        #expect(try !detector.registerHandoff(for: next))
        try detector.finishHandoff(for: next)
        #expect(detector.status(for: first) == .registered)

        try FileManager.default.removeItem(at: marker)
        #expect(detector.status(for: first) == .unverified)
    }

    @Test("a handoff remains registered for its exact pipeline after active work finishes")
    func exactPipelineReceipt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root)
        let first = key(pipelineID: 12)
        let next = key(pipelineID: 13)

        #expect(try detector.registerHandoff(for: first))
        #expect(try !detector.registerHandoff(for: next))
        try detector.finishHandoff(for: first)

        let relaunched = ExistingPipelineWorkDetector(directory: root)
        #expect(relaunched.status(for: first) == .registered)
        #expect(relaunched.status(for: next) == .unverified)
        #expect(try !relaunched.registerHandoff(for: first))
        #expect(try relaunched.registerHandoff(for: next))
    }

    @Test("independent callers can only claim one handoff for the same merge request")
    func atomicHandoff() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = key(pipelineID: 12)
        let second = key(pipelineID: 13)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for candidate in [first, second] {
                group.addTask {
                    let detector = ExistingPipelineWorkDetector(directory: root)
                    return (try? detector.registerHandoff(for: candidate)) ?? false
                }
            }
            var claims: [Bool] = []
            for await claim in group {
                claims.append(claim)
            }
            return claims
        }
        #expect(results.filter { $0 }.count == 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func key(pipelineID: Int) -> ExistingPipelineWorkDetector.Key {
        .init(host: "gitlab.example.org", projectID: 42, mergeRequestIID: 7, pipelineID: pipelineID)
    }
    @Test("explicit retry owns a fresh reservation that an old terminal run cannot release")
    func explicitRetryHasDistinctOwnership() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root)
        let firstClaim = try detector.registerRun(for: key(pipelineID: 12))
        let original = try #require(firstClaim)
        #expect(try detector.registerRun(for: key(pipelineID: 12), explicitRetry: true) == nil)
        try detector.finishHandoff(for: original)
        #expect(try detector.registerRun(for: key(pipelineID: 12)) == nil)
        let retryClaim = try detector.registerRun(for: key(pipelineID: 12), explicitRetry: true)
        let retry = try #require(retryClaim)
        #expect(retry.reservationID != original.reservationID)
        try detector.finishHandoff(for: original)
        #expect(FileManager.default.fileExists(atPath: try detector.externalRegistrationURL(for: retry).path))
        try detector.finishHandoff(for: retry)
        #expect(!FileManager.default.fileExists(atPath: try detector.externalRegistrationURL(for: retry).path))
        #expect(detector.status(for: retry) == .registered)
    }

    @Test("dead app-owned terminal runs recover their reservation but preserve the receipt")
    func staleOwnedTerminalRun() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ExistingPipelineWorkDetector(directory: root, installationID: "com.test.local", processID: 700)
        let optionalClaim = try owner.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try owner.bindRun(runID, to: claim)
        let restarted = ExistingPipelineWorkDetector(directory: root, installationID: "com.test.local",
            processState: { _ in .dead })
        let diagnostic = try #require(restarted.reservationOwner(for: claim))
        #expect(diagnostic.runID == runID)
        #expect(diagnostic.owner.processID == 700)
        #expect(restarted.activeReservationOwner(for: key(pipelineID: 13)) == diagnostic)
        #expect(try !restarted.recoverTerminalRun(runID, reservation: claim, state: .running))
        // Force Quit can leave a child running even though the app PID died.
        #expect(try !restarted.recoverTerminalRun(runID, reservation: claim, state: .interrupted))
        #expect(try !restarted.recoverTerminalRun(UUID(), reservation: claim, state: .succeeded))
        #expect(try restarted.recoverTerminalRun(runID, reservation: claim, state: .succeeded))
        #expect(!restarted.hasActiveReservation(for: claim))
        #expect(restarted.status(for: claim) == .registered)
        #expect(try restarted.registerRun(for: key(pipelineID: 12)) == nil)
    }

    @Test("live, unknown or reused PIDs and a different installation never authorize recovery")
    func conservativeProcessOwnership() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ExistingPipelineWorkDetector(directory: root, installationID: "com.test.local", processID: 700)
        let optionalClaim = try owner.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try owner.bindRun(runID, to: claim)
        for state in [ExistingPipelineWorkDetector.ProcessState.alive, .unknown] {
            let restarted = ExistingPipelineWorkDetector(directory: root, installationID: "com.test.local",
                processState: { _ in state })
            #expect(try !restarted.recoverTerminalRun(runID, reservation: claim, state: .succeeded))
        }
        let foreign = ExistingPipelineWorkDetector(directory: root, installationID: "com.test.other",
            processState: { _ in .dead })
        #expect(try !foreign.recoverTerminalRun(runID, reservation: claim, state: .succeeded))
        #expect(owner.ownsReservation(for: claim))
    }

    @Test("unknown and symlinked reservations remain inspectable and cannot be removed")
    func unknownAndSymlinkedOwners() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root, processState: { _ in .dead })
        let optionalClaim = try detector.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try detector.bindRun(runID, to: claim)
        let active = try detector.externalRegistrationURL(for: claim)
        let mr = active.deletingLastPathComponent()
        let moved = mr.appending(path: "preserved")
        try FileManager.default.moveItem(at: active, to: moved)
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: moved)
        #expect(detector.reservationOwner(for: claim) == nil)
        #expect(try !detector.recoverTerminalRun(runID, reservation: claim, state: .succeeded))
        try detector.finishHandoff(for: claim)
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("a symlinked reservation ancestor never permits registration or recovery")
    func symlinkedAncestor() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root.appending(path: "claims"), processState: { _ in .dead })
        let optionalClaim = try detector.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try detector.bindRun(runID, to: claim)
        let active = try detector.externalRegistrationURL(for: claim)
        let project = active.deletingLastPathComponent().deletingLastPathComponent()
        let preserved = root.appending(path: "preserved-project")
        try FileManager.default.moveItem(at: project, to: preserved)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: preserved)
        #expect(!detector.ownsReservation(for: claim))
        #expect(try !detector.recoverTerminalRun(runID, reservation: claim, state: .succeeded))
        #expect(throws: (any Error).self) { try detector.registerRun(for: key(pipelineID: 13)) }
        try detector.finishHandoff(for: claim)
        #expect(FileManager.default.fileExists(atPath: preserved.appending(path: "mr-7/active").path))
    }

    @Test("a replacement owner and unexpected content cannot be recursively removed")
    func changedOwnerAndExtraContent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root, processState: { _ in .dead })
        let optionalOriginal = try detector.registerRun(for: key(pipelineID: 12))
        let original = try #require(optionalOriginal)
        let runID = UUID()
        try detector.bindRun(runID, to: original)
        try detector.finishHandoff(for: original)
        let optionalReplacement = try detector.registerRun(for: key(pipelineID: 12), explicitRetry: true)
        let replacement = try #require(optionalReplacement)
        try detector.bindRun(UUID(), to: replacement)
        #expect(try !detector.recoverTerminalRun(runID, reservation: original, state: .succeeded))
        let active = try detector.externalRegistrationURL(for: replacement)
        let owners = try FileManager.default.contentsOfDirectory(at: active, includingPropertiesForKeys: nil)
        let ownerDirectory = try #require(owners.first)
        try Data("external".utf8).write(to: ownerDirectory.appending(path: "unknown.txt"))
        #expect(throws: (any Error).self) { try detector.finishHandoff(for: replacement) }
        #expect(detector.ownsReservation(for: replacement))
        #expect(FileManager.default.fileExists(atPath: ownerDirectory.appending(path: "unknown.txt").path))
    }

    @Test("an owner replaced between stale inspection and recovery keeps the new reservation")
    func ownerReplacedDuringRecovery() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ExistingPipelineWorkDetector(directory: root)
        let optionalClaim = try original.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try original.bindRun(runID, to: claim)
        let probe = ReusedPIDProbe(onFirst: {
            try? original.finishHandoff(for: claim)
            _ = try? original.registerRun(for: claim, explicitRetry: true)
        })
        let restarted = ExistingPipelineWorkDetector(directory: root, processState: { _ in probe.next() })
        #expect(try !restarted.recoverTerminalRun(runID, reservation: claim, state: .failed))
        let replacement = try #require(restarted.activeReservationOwner(for: claim))
        #expect(replacement.owner.reservationID != claim.reservationID)
        #expect(restarted.hasActiveReservation(for: claim))
    }

    @Test("a PID becoming live during recovery preserves its exact reservation")
    func pidRecheckedBeforeDeletion() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ExistingPipelineWorkDetector(directory: root)
        let optionalClaim = try original.registerRun(for: key(pipelineID: 12))
        let claim = try #require(optionalClaim)
        let runID = UUID()
        try original.bindRun(runID, to: claim)
        let probe = ReusedPIDProbe()
        let restarted = ExistingPipelineWorkDetector(directory: root, processState: { _ in probe.next() })
        #expect(try !restarted.recoverTerminalRun(runID, reservation: claim, state: .failed))
        #expect(restarted.ownsReservation(for: claim))
        #expect(restarted.reservationOwner(for: claim)?.runID == runID)
    }

}

private final class ReusedPIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let onFirst: @Sendable () -> Void
    init(onFirst: @escaping @Sendable () -> Void = {}) { self.onFirst = onFirst }
    func next() -> ExistingPipelineWorkDetector.ProcessState {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls == 1 { onFirst() }
        return calls == 1 ? .dead : .alive
    }
}
