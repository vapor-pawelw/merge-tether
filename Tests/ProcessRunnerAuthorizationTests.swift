import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ProcessRunnerAuthorizationTests {
    @MainActor private final class Admission {
        var allowed = true
        var checks = 0
    }

    private func fixture() throws -> (folder: URL, executable: URL, marker: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let executable = folder.appendingPathComponent("fixture-write")
        try Data("#!/bin/sh\nprintf started > \"$0.marker\"\nprintf acknowledged\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (folder, executable, URL(fileURLWithPath: executable.path + ".marker"))
    }

    @Test(arguments: [true, false])
    func theRealProcessBoundaryRequiresAdmission(_ allowed: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let admission = Admission()
        admission.allowed = allowed
        do {
            let output = try await ProcessRunner.run(fixture.executable, environment: [:], timeout: 2,
                authorizeLaunch: { admission.checks += 1; return admission.allowed })
            #expect(allowed)
            #expect(output.exitCode == 0)
            #expect(String(decoding: output.stdout, as: UTF8.self) == "acknowledged")
        } catch is CancellationError {
            #expect(!allowed)
        }
        #expect(admission.checks == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path) == allowed)
    }

    /// Hold the actor while ProcessRunner prepares capture on its executor. The
    /// guarded launch then queues behind this actor turn, before any child exists.
    private func holdActorUntilCaptureIsPrepared(_ capture: URL) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: capture.appendingPathComponent("stderr").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let ready = FileManager.default.fileExists(atPath: capture.appendingPathComponent("stderr").path)
        // Give the detached timeout/cancellation handling time while the actor
        // remains occupied. This never gives the queued launch an actor turn.
        Thread.sleep(forTimeInterval: 0.1)
        return ready
    }

    @Test(arguments: ["denied", "cancelled", "timedOut"])
    func aQueuedLaunchCannotStartAfterRevocationCancellationOrTimeout(_ reason: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let admission = Admission()
        let capture = fixture.folder.appendingPathComponent("capture")
        let timeout: TimeInterval = reason == "timedOut" ? 0.02 : 5
        let pending = Task.detached {
            try await ProcessRunner.run(fixture.executable, environment: [:], timeout: timeout, outputDirectory: capture,
                authorizeLaunch: { admission.checks += 1; return admission.allowed })
        }
        let capturePrepared = holdActorUntilCaptureIsPrepared(capture)
        #expect(capturePrepared)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        if reason == "denied" { admission.allowed = false }
        if reason == "cancelled" || !capturePrepared { pending.cancel() }
        do {
            _ = try await pending.value
            Issue.record("A revoked, cancelled or expired queued launch succeeded")
        } catch is CancellationError {
            #expect(reason != "timedOut" || !capturePrepared)
        } catch ProcessRunner.RunError.timedOut {
            #expect(reason == "timedOut")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        #expect(admission.checks == (reason == "denied" ? 1 : 0))
    }

    @Test func guardedLaunchFailuresRetainTheirErrorClassification() async {
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/fixture-write"), environment: [:],
                timeout: 2, authorizeLaunch: { !Task.isCancelled })
            Issue.record("A missing executable succeeded")
        } catch ProcessRunner.RunError.launchFailed {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
