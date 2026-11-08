import Foundation
import Testing
@testable import GitLabTodos

@Suite("Assistant usage process capture")
struct AssistantUsageRunnerTests {
    @Test("Transient accounting failures retain measured runs for the next successful write")
    func transientAccountingRecovery() async throws {
        let file = temporaryFile()
        let parent = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // A regular file blocks creation of the usage directory without changing global permissions.
        try Data("temporary blocker".utf8).write(to: parent)
        let store = AssistantUsageStore(file: file)
        let first = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: [#"{"total_cost_usd":0.25}"#],
            environment: [:], usage: .init(role: .codingAgent, assistant: .claude), store: store)
        #expect(first.exitCode == 0)
        await #expect(throws: (any Error).self) { try await store.snapshot() }
        try FileManager.default.removeItem(at: parent)
        let second = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: [#"{"total_cost_usd":0.5}"#],
            environment: [:], usage: .init(role: .codingAgent, assistant: .claude), store: store)
        #expect(second.exitCode == 0)
        let restarted = AssistantUsageStore(file: file)
        let total = try await restarted.snapshot().total(for: .codingAgent)
        #expect(total.runs == 2 && total.estimatedUSD == 0.75 && total.unknownCostRuns == 0)
    }

    @Test("Codex failure after a completed turn retains a partial subtotal", arguments: [0, 1])
    func incompleteCodexExit(_ exitCode: Int) async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let output = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}' '{"type":"turn.failed","error":{"message":"later request failed"}}'; exit \(exitCode)
            """], environment: [:], usage: .init(role: .codingAgent, assistant: .codex, model: "gpt-6-luna"), store: store)
        #expect(output.exitCode == exitCode)
        let total = try await store.snapshot().total(for: .codingAgent)
        #expect(total.estimatedUSD == 0.1)
        #expect(total.inputTokens == 1_000_000)
        #expect(total.unknownCostRuns == 1)
    }

    @Test("Nonzero CLI exits still retain reported usage")
    func failingProcess() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let output = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s' '{"total_cost_usd":0.25}'; exit 7"#], environment: [:],
            usage: .init(role: .codingAgent, assistant: .claude), store: store)
        #expect(output.exitCode == 7)
        let total = try await store.snapshot().total(for: .codingAgent)
        #expect(total.runs == 1 && total.estimatedUSD == 0.25 && total.unknownCostRuns == 0)
    }

    @Test("Timeout preserves completed-turn usage and marks the run as partial")
    func timeout() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        do {
            _ = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                #"printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}'; /bin/sleep 10"#],
                environment: [:], timeout: 0.3, usage: .init(role: .verifier, assistant: .codex, model: "gpt-6-luna"), store: store)
            Issue.record("Expected timeout")
        } catch ProcessRunner.RunError.timedOut {}
        let total = try await store.snapshot().total(for: .verifier)
        #expect(total.runs == 1 && total.estimatedUSD == 0.1 && total.unknownCostRuns == 1)
        #expect(total.inputTokens == 1_000_000)
    }

    @Test("Cancellation is retained as unknown instead of zero; launch failure adds no run")
    func cancellationAndLaunchFailure() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let task = Task {
            try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:],
                usage: .init(role: .verifier, assistant: .codex), store: store)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        do {
            _ = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/missing/cli"), environment: [:],
                usage: .init(role: .codingAgent, assistant: .codex), store: store)
            Issue.record("Expected launch failure")
        } catch ProcessRunner.RunError.launchFailed {}
        let snapshot = try await store.snapshot()
        #expect(snapshot.total(for: .verifier).runs == 1)
        #expect(snapshot.total(for: .verifier).unknownCostRuns == 1)
        #expect(snapshot.total(for: .codingAgent).runs == 0)
    }

    @Test("Accounting failure cannot turn a successful CLI run into failed automation")
    func accountingFailure() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: file)
        let output = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["ready"], environment: [:],
            usage: .init(role: .verifier, assistant: .codex), store: AssistantUsageStore(file: file))
        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "ready\n")
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "UsageRunnerTests-\(UUID())/usage.json")
    }
}
