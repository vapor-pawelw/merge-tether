import Foundation
import Testing
@testable import GitLabTodos

@Suite struct AssistantJobExecutionTests {
    @Test func runningAndQueuedJobsBecomeInterruptedAfterRestart() {
        #expect(AssistantJobExecution(state: .running).recoverAfterRestart().state == .interrupted)
        #expect(AssistantJobExecution(state: .queued).recoverAfterRestart().state == .interrupted)
        #expect(AssistantJobExecution(state: .succeeded).recoverAfterRestart().state == .succeeded)
    }

    @Test func structuredClaudeErrorIsNeverACompletedJob() throws {
        let data = Data(#"{"type":"result","is_error":true,"subtype":"error_max_turns","result":"Incomplete"}"#.utf8)
        #expect(throws: AssistantJobResult.Error.self) {
            try AssistantJobResult.claude(data)
        }
    }

    @Test func structuredResultDistinguishesBlockedWorkFromSuccess() throws {
        let data = Data(#"{"type":"result","is_error":false,"structured_output":{"status":"blocked","summary":"Need repository access"}}"#.utf8)
        let result = try AssistantJobResult.claude(data)
        #expect(result.status == .blocked)
        #expect(result.summary == "Need repository access")
    }

    @Test func codexRequiresExplicitValidStructuredResult() throws {
        #expect(throws: AssistantJobResult.Error.self) { try AssistantJobResult.codex(Data("Everything is fine".utf8)) }
        let result = try AssistantJobResult.codex(Data(#"{"status":"succeeded","summary":"Saved two private drafts"}"#.utf8))
        #expect(result.status == .succeeded)
        #expect(result.summary == "Saved two private drafts")
    }

    @Test func missingEmptyOrUnknownResultIsNotSuccess() {
        for payload in [#"{"status":"succeeded","summary":" "}"#, #"{"summary":"Done"}"#, #"{"status":"complete","summary":"Done"}"#] {
            #expect(throws: AssistantJobResult.Error.self) { try AssistantJobResult.codex(Data(payload.utf8)) }
        }
        #expect(throws: AssistantJobResult.Error.self) {
            try AssistantJobResult.claude(Data(#"{"is_error":false,"result":"Done"}"#.utf8))
        }
    }
    @Test func claudePermissionDenialsOrIncompleteSubtypeAreNotSuccess() {
        for payload in [
            #"{"is_error":false,"subtype":"error_max_turns","structured_output":{"status":"succeeded","summary":"Done"}}"#,
            #"{"is_error":false,"permission_denials":[{"tool_name":"Bash"}],"structured_output":{"status":"succeeded","summary":"Done"}}"#
        ] {
            #expect(throws: AssistantJobResult.Error.self) { try AssistantJobResult.claude(Data(payload.utf8)) }
        }
    }

    @Test func codexEventStreamMustFinishWithoutFatalErrors() throws {
        try AssistantJobResult.validateCodexEvents(Data("{\"type\":\"turn.started\"}\n{\"type\":\"turn.completed\"}\n".utf8))
        for text in ["{\"type\":\"turn.started\"}\n", "{\"type\":\"turn.completed\"}\n{\"type\":\"error\"}\n", "{\"type\":\"turn.failed\"}\n"] {
            #expect(throws: AssistantJobResult.Error.self) { try AssistantJobResult.validateCodexEvents(Data(text.utf8)) }
        }
    }

}
