import Darwin
import Foundation
import Testing
@testable import GitLabTodos

@Suite("ProcessRunner")
struct ProcessRunnerTests {
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
}
