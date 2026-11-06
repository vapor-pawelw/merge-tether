import Foundation
import Testing
@testable import GitLabTodos

struct AssistantLaunchContextTests {
    @Test func shellArgumentsPreserveUntrustedTextLiterally() async throws {
        let text = "title'; printf unwanted\n$(printf unwanted) `printf unwanted` + 🐈"
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s " + AssistantLaunchContext.shellQuote(text)], environment: [:])
        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == text)
    }

    @Test func appleScriptPreservesCommandsPathsAndUntrustedPromptLiterally() async throws {
        let text = "cd -- '/tmp/a path' && '/opt/homebrew/bin/codex' 'quote \" hello\n\t\\ $() 🐈'"
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", "return " + AssistantLaunchContext.appleScriptLiteral(text)], environment: [:])
        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == text + "\n")
    }

    @Test func manualContextIncludesMRAndDoesNotGrantAutomaticWritePermission() {
        let url = URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!
        let context = AssistantLaunchContext(url: url, title: "Fix + edge")
        #expect(context.prompt.contains(url.absoluteString))
        #expect(context.prompt.contains("Do not publish"))
        #expect(context.prompt.contains("manual conversation"))
        let command = context.terminalCommand(executable: URL(fileURLWithPath: "/tools with spaces/codex"),
                                              directory: URL(fileURLWithPath: "/tmp/a directory"))
        #expect(command.hasPrefix("cd -- '/tmp/a directory' && '/tools with spaces/codex' '"))
    }
}
