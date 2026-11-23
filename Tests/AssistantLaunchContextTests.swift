import Foundation
import Testing
@testable import MergeTether

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

    @Test func terminalConversationRequiresTheUsersOwnMessage() throws {
        let mrURL = URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!
        let context = AssistantLaunchContext(url: mrURL)
        let executable = URL(fileURLWithPath: "/tools with spaces/codex")
        let directory = URL(fileURLWithPath: "/tmp/a directory")
        #expect(context.terminalCommand(executable: executable, directory: directory, message: "  \n ") == nil)
        let command = try #require(context.terminalCommand(executable: executable, directory: directory, message: "Explain the change"))
        #expect(command == "cd -- '/tmp/a directory' && '/tools with spaces/codex' '\(mrURL.absoluteString)\n\nExplain the change'")
    }

    @Test func t3CodeDraftLinkPrefillsAConversationStarterAndPreservesURLCharacters() throws {
        let mrURL = URL(string: "https://gitlab.example.org/team+owner/repo/-/merge_requests/7?tab=changes&view=inline#diff")!
        let context = AssistantLaunchContext(url: mrURL)
        let url = try #require(context.t3CodeDraftURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "t3code")
        #expect(components.host == "new")
        #expect(components.path.isEmpty)
        #expect(components.fragment == nil)
        #expect(components.queryItems == [URLQueryItem(name: "prompt", value: "Regarding \(mrURL.absoluteString), ")])
        #expect(components.percentEncodedQuery?.contains("+") == false)
    }

    @MainActor @Test func desktopContextIsAnAttachmentWithOnlyTheMRURL() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mrURL = URL(string: "https://gitlab.example.org/team/repo/-/merge_requests/7")!
        let context = AssistantLaunchContext(url: mrURL)
        let file = try AssistantContextLauncher.writeAttachment(context, in: root)
        #expect(file.pathExtension == "txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == mrURL.absoluteString)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700)
        let secondFile = try AssistantContextLauncher.writeAttachment(context, in: root)
        #expect(secondFile != file)
        #expect(try String(contentsOf: secondFile, encoding: .utf8) == mrURL.absoluteString)
    }
}
