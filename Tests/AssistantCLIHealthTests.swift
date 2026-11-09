import Foundation
import Testing
@testable import GitLabTodos

struct AssistantCLIHealthTests {
    @MainActor @Test func aLongRunningOlderInvocationCanDiscoverANewQuotaFailure() throws {
        let suite = "AssistantCLIHealthTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantCLIHealthStore(defaults: defaults)
        store.recordSuccess(assistant: .codex, startedAt: Date(timeIntervalSince1970: 20))
        store.record(.init(kind: .rateLimited), assistant: .codex, executable: URL(fileURLWithPath: "/example/codex"),
            startedAt: Date(timeIntervalSince1970: 10), observedAt: Date(timeIntervalSince1970: 30))
        #expect(store.hold(for: .codex)?.issue.kind == .rateLimited)
        store.recordSuccess(assistant: .codex, startedAt: Date(timeIntervalSince1970: 25))
        #expect(store.hold(for: .codex) != nil)
        store.recordSuccess(assistant: .codex, startedAt: Date(timeIntervalSince1970: 40))
        #expect(store.hold(for: .codex) == nil)
    }

    @Test func claudeStartupLoginAndCurlyApostropheLimitAreRecognized() {
        let login = ProcessRunner.Output(stdout: Data("Not logged in · Please run /login".utf8), stderr: "", exitCode: 1)
        #expect(AssistantCLIHealthIssue.parse(login, assistant: .claude)?.kind == .loginRequired)
        let limit = ProcessRunner.Output(stdout: Data(#"{"type":"result","is_error":true,"result":"You’ve hit your limit · resets 5pm (Europe/Warsaw)"}"#.utf8), stderr: "", exitCode: 1)
        let issue = AssistantCLIHealthIssue.parse(limit, assistant: .claude)
        #expect(issue?.kind == .rateLimited && issue?.resetHint == "5pm (Europe/Warsaw)")
        let sessionLimit = ProcessRunner.Output(stdout: Data(),
            stderr: "You've hit your session limit · resets 2:40pm (Europe/Warsaw)", exitCode: 1)
        #expect(AssistantCLIHealthIssue.parse(sessionLimit, assistant: .claude)?.kind == .rateLimited)
    }

    @MainActor @Test func providerFailurePersistsAHoldAndPreventsTheNextInvocation() async throws {
        let suite = "AssistantCLIHealthTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let health = AssistantCLIHealthStore(defaults: defaults)
        let usage = AssistantUsageStore(file: folder.appendingPathComponent("usage.json"))
        let output = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"code\":\"usage_limit_reached\"}}'; exit 1"],
            environment: [:], usage: .init(role: .codingAgent, assistant: .codex), store: usage, healthStore: health)
        #expect(output.exitCode == 1)
        #expect(AssistantCLIHealthStore(defaults: defaults).hold(for: .codex)?.issue.kind == .rateLimited)
        do {
            _ = try await AssistantUsageRunner.run(URL(fileURLWithPath: "/must-not-launch"), environment: [:],
                usage: .init(role: .verifier, assistant: .codex), store: usage, healthStore: health)
            Issue.record("Provider hold must reject new work")
        } catch AssistantUsageRunner.AccessError.temporarilyUnavailable(.rateLimited) {}
        let snapshot = try await usage.snapshot()
        #expect(snapshot.total(for: .verifier).runs == 0)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func providerAuthenticationFailuresAreSeparateFromToolOutput(_ assistant: AutomationAssistant) throws {
        let error = ProcessRunner.Output(stdout: Data(#"{"type":"error","error":{"type":"authentication_error","message":"Token expired. Please log in again."}}"#.utf8), stderr: "", exitCode: 1)
        #expect(AssistantCLIHealthIssue.parse(error, assistant: assistant)?.kind == .loginRequired)
        let tool = ProcessRunner.Output(stdout: Data(#"{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"authentication_error: Token expired"}}"#.utf8), stderr: "", exitCode: 0)
        #expect(AssistantCLIHealthIssue.parse(tool, assistant: assistant) == nil)
    }

    @Test func quotaFailuresIncludeStructuredResetTimeAndIgnoreAssistantProse() {
        let output = ProcessRunner.Output(stdout: Data(#"{"type":"turn.failed","error":{"code":"usage_limit_reached","message":"You've hit your usage limit.","resets_at":1924992000}}"#.utf8), stderr: "", exitCode: 1)
        let issue = AssistantCLIHealthIssue.parse(output, assistant: .codex)
        #expect(issue?.kind == .rateLimited)
        #expect(issue?.resetsAt == Date(timeIntervalSince1970: 1924992000))
        let prose = ProcessRunner.Output(stdout: Data(#"{"type":"result","is_error":false,"result":"The downstream API returned rate_limit_exceeded. Add a retry."}"#.utf8), stderr: "", exitCode: 0)
        #expect(AssistantCLIHealthIssue.parse(prose, assistant: .claude) == nil)
    }

    @Test func textQuotaOnTheCLIsOwnFailureChannelKeepsABoundedResetHint() {
        let output = ProcessRunner.Output(stdout: Data(), stderr: "ERROR: You've hit your usage limit. Try again at Nov 13th, 2030 1:41 PM.", exitCode: 1)
        let issue = AssistantCLIHealthIssue.parse(output, assistant: .codex)
        #expect(issue?.kind == .rateLimited)
        #expect(issue?.resetHint == "Nov 13th, 2030 1:41 PM")
        #expect(AssistantCLIHealthIssue.parse(.init(stdout: Data(), stderr: "HTTP 429 from GitLab", exitCode: 1), assistant: .codex) == nil)
    }

    @MainActor @Test func holdsSurviveRestartAndStaleSuccessCannotClearANewerFailure() throws {
        // given
        let suite = "AssistantCLIHealthTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantCLIHealthStore(defaults: defaults)
        let executable = URL(fileURLWithPath: "/example/codex")
        let issue = AssistantCLIHealthIssue(kind: .rateLimited)
        // when
        store.record(issue, assistant: .codex, executable: executable, startedAt: Date(timeIntervalSince1970: 20))
        store.recordSuccess(assistant: .codex, startedAt: Date(timeIntervalSince1970: 10))
        // then
        #expect(store.hold(for: .codex) != nil)
        let reloaded = AssistantCLIHealthStore(defaults: defaults)
        #expect(reloaded.hold(for: .codex)?.issue.kind == .rateLimited)
        #expect(reloaded.hold(for: .claude) == nil)
        store.recordSuccess(assistant: .codex, startedAt: Date(timeIntervalSince1970: 30))
        #expect(store.hold(for: .codex) == nil)
        store.record(issue, assistant: .codex, executable: executable, startedAt: Date(timeIntervalSince1970: 15))
        #expect(store.hold(for: .codex) == nil)
    }
}
