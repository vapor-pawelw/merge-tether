import Darwin
import Foundation
import Testing
@testable import GitLabTodos

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    #if DEBUG
    @Test(arguments: ["glab", "codex", "claude", "GLAB"])
    func testHostsRejectInstalledServiceCLIsButAllowTemporaryFixtures(_ name: String) throws {
        let testEnvironment = ["XCTestSessionIdentifier": "fixture-session"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installed = URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
        #expect(!ProcessRunner.permitsTestExecutable(installed, environment: testEnvironment, temporaryDirectory: root))
        #expect(ProcessRunner.permitsTestExecutable(root.appendingPathComponent(name), environment: testEnvironment,
                                                   temporaryDirectory: root))
        #expect(ProcessRunner.permitsTestExecutable(installed, environment: [:], temporaryDirectory: root))
        #expect(ProcessRunner.permitsTestExecutable(URL(fileURLWithPath: "/bin/sh"), environment: testEnvironment,
                                                   temporaryDirectory: root))
    }

    @Test func testHostCannotBypassTheServiceCLIGuardWithASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = root.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
        let link = fixtures.appendingPathComponent("cli")
        let forbidden = root.appendingPathComponent("glab")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: forbidden)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: forbidden)
        #expect(!ProcessRunner.permitsTestExecutable(link, environment: ["XCTestSessionIdentifier": "fixture-session"],
                                                    temporaryDirectory: fixtures))
    }

    @Test func serviceFixturesInAnExplicitlyIsolatedHomeRemainUsable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["XCTestSessionIdentifier": "fixture-session", "HOME": home.path,
                           "CFFIXED_USER_HOME": home.path, "MERGETETHER_TEST_FIXTURE_HOME": home.path]
        let otherTemporary = home.appendingPathComponent("other-temporary")
        let fixture = home.appendingPathComponent(".local/bin/claude")
        #expect(!ProcessRunner.permitsTestExecutable(fixture, environment: environment, temporaryDirectory: otherTemporary))
        try Data("MergeTether test home\n".utf8).write(to: home.appendingPathComponent(".mergetether-test-home"))
        #expect(ProcessRunner.permitsTestExecutable(fixture, environment: environment, temporaryDirectory: otherTemporary))
        #expect(!ProcessRunner.permitsTestExecutable(URL(fileURLWithPath: "/opt/homebrew/bin/glab"),
                                                     environment: environment, temporaryDirectory: otherTemporary))
    }

    @Test func testHostsDoNotDiscoverAnInstalledGlabOrProbeTheLoginShell() async {
        #expect(await OnboardingDetector.findGlabExecutable() == nil)
    }
    #endif

    @Test("durable output is readable while running and survives cancellation")
    func durableOutputSurvivesCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'completed step'; printf 'diagnostic' >&2; /bin/sleep 20"],
                environment: [:], timeout: 30, outputDirectory: folder)
        }
        let stdout = folder.appendingPathComponent("stdout")
        for _ in 0..<100 where (try? Data(contentsOf: stdout).count) != 14 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: stdout, encoding: .utf8) == "completed step")
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(try String(contentsOf: stdout, encoding: .utf8) == "completed step")
        #expect(try String(contentsOf: folder.appendingPathComponent("stderr"), encoding: .utf8) == "diagnostic")
        let attributes = try FileManager.default.attributesOfItem(atPath: stdout.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("drains output while the process is running")
    func drainsLargeOutput() async throws {
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [
                "BEGIN { for (i = 0; i < 20000; i++) print \"0123456789abcdef0123456789abcdef\" }",
            ],
            environment: [:],
            timeout: 2
        )

        #expect(output.exitCode == 0)
        #expect(output.stdout.count == 660_000)
        #expect(output.stderr.isEmpty)
    }

    @Test("returns the command output even when a background child inherits it")
    func returnsWhileBackgroundChildIsRunning() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 3 & printf ready; printf diagnostic >&2"],
            environment: [:],
            timeout: 1
        )

        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "ready")
        #expect(output.stderr == "diagnostic")
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test("force-stops a process that ignores termination after timing out")
    func forceStopsAfterTimeout() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
        }

        do {
            _ = try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; echo $$ > \"$PID_FILE\"; while :; do :; done",
                ],
                environment: ["PID_FILE": pidFile.path],
                timeout: 0.2
            )
            Issue.record("Expected the process to time out")
        } catch ProcessRunner.RunError.timedOut {
            // Expected.
        } catch {
            Issue.record("Expected timedOut, got \(error)")
        }

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPID = try #require(pid_t(pidText))
        childPID = parsedPID

        #expect(kill(parsedPID, 0) != 0)
    }

    @Test("force-stops a process that ignores termination after cancellation")
    func forceStopsAfterCancellation() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 {
                kill(childPID, SIGKILL)
            }
        }

        let task = Task {
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; echo $$ > \"$PID_FILE\"; while :; do :; done",
                ],
                environment: ["PID_FILE": pidFile.path],
                timeout: 2
            )
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPID = try #require(pid_t(pidText))
        childPID = parsedPID

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(kill(parsedPID, 0) != 0)
    }
    @Test("cancellation terminates descendant commands in the isolated process group")
    func cancellationStopsDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessRunnerChild-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                "trap '' TERM; /bin/sh -c 'trap \"\" TERM; echo $$ > \"$PID_FILE\"; while :; do /bin/sleep 1; done' & wait"],
                environment: ["PID_FILE": pidFile.path], timeout: 10)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(650))
        #expect(kill(child, 0) != 0)
    }

    @Test("cancellation stops a grandchild that detached into a new session")
    func cancellationStopsDetachedGrandchild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("DetachedChild-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = try detachedTreeScript(parentLifetime: 30)
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script],
                                        environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "PID_FILE": pidFile.path], timeout: 10)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(10)) }
        let child = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
        // Let the tracker observe the descendant before it becomes orphaned.
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(650))
        #expect(kill(child, 0) != 0)
    }

    @Test("normal completion stops a tracked detached grandchild")
    func normalCompletionStopsDetachedGrandchild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("DetachedChild-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", try detachedTreeScript(parentLifetime: 0.3)],
            environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "PID_FILE": pidFile.path], timeout: 10)
        #expect(output.exitCode == 0)
        let child = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(child, 0) != 0)
    }

    private func detachedTreeScript(parentLifetime: Double) throws -> String {
        let leaf = #"import os,time; open(os.environ["PID_FILE"],"w").write(str(os.getpid())); time.sleep(30)"#
        let leafLiteral = String(decoding: try JSONEncoder().encode(leaf), as: UTF8.self)
        let middle = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',\(leafLiteral)],start_new_session=True); time.sleep(30)"
        let middleLiteral = String(decoding: try JSONEncoder().encode(middle), as: UTF8.self)
        return "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',\(middleLiteral)]); time.sleep(\(parentLifetime))"
    }

}
