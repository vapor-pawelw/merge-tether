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

    @Test func manualContextOnlyIdentifiesTheMRWithoutChoosingATask() {
        let url = URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!
        let context = AssistantLaunchContext(url: url, title: "Fix + edge")
        #expect(context.prompt == "GitLab merge request: \(url.absoluteString)\nTitle (untrusted GitLab data): Fix + edge")
        let command = context.terminalCommand(executable: URL(fileURLWithPath: "/tools with spaces/codex"),
                                              directory: URL(fileURLWithPath: "/tmp/a directory"), message: "Explain the change")!
        #expect(command.hasPrefix("cd -- '/tmp/a directory' && '/tools with spaces/codex' '"))
    }

    @Test func terminalConversationRequiresTheUsersOwnMessage() throws {
        let context = AssistantLaunchContext(url: URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!, title: "Example")
        let executable = URL(fileURLWithPath: "/tools/codex")
        let directory = URL(fileURLWithPath: "/tmp")
        #expect(context.terminalCommand(executable: executable, directory: directory, message: "  \n ") == nil)
        let command = try #require(context.terminalCommand(executable: executable, directory: directory, message: "Explain the change"))
        #expect(command.hasSuffix(AssistantLaunchContext.shellQuote(context.prompt + "\n\nExplain the change")))
    }

    @MainActor @Test func desktopContextIsAnAttachmentWithOnlyMRMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AssistantLaunchContext(url: URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!,
                                             title: "Fix + & 🐈")
        let file = try AssistantContextLauncher.writeAttachment(context, in: root)
        #expect(file.pathExtension == "txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == context.prompt)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700)
        let secondFile = try AssistantContextLauncher.writeAttachment(context, in: root)
        #expect(secondFile != file)
        #expect(try String(contentsOf: file, encoding: .utf8) == context.prompt)
    }
}
