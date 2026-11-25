import AppKit
import Foundation

enum AssistantDependencyStatus: Equatable, Sendable {
    case ready(URL), missingCLI, invalidCLI, loginRequired(URL)

    var isReady: Bool {
        switch self {
        case .ready: true
        default: false
        }
    }
}

enum AssistantCLI {
    static var environment: [String: String] {
        var environment = ["HOME": NSHomeDirectory(), "PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME",
                    "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
                    "NODE_EXTRA_CA_CERTS", "CODEX_CA_CERTIFICATE", "SSH_AUTH_SOCK"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        return environment
    }

    @MainActor
    static func detect(_ assistant: AutomationAssistant) async -> AssistantDependencyStatus {
        #if DEBUG
        if ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .testHost {
            return await check(assistant,
                               candidates: [URL.homeDirectory.appending(path: ".local/bin/\(assistant.rawValue)")])
        }
        #endif
        let optionalApp = AssistantAutomationRunner.desktopApplication(assistant)
        return await check(assistant, candidates: candidates(for: assistant, desktopURL: optionalApp))
    }

    static func candidates(for assistant: AutomationAssistant, desktopURL: URL?, home: URL = .homeDirectory) -> [URL] {
        // A bundled CLI is still an executable CLI, never a GUI dependency.
        // Prefer it when present so an older package-manager binary does not
        // shadow the compatible runtime used by the installed Codex app.
        let bundled = assistant == .codex ? [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex",
        ].compactMap { desktopURL?.appending(path: $0) } : []
        return bundled + [home.appending(path: ".local/bin/\(assistant.rawValue)")]
            + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map {
                URL(fileURLWithPath: $0).appending(path: assistant.rawValue)
            }
    }

    static func check(_ assistant: AutomationAssistant, candidates: [URL]) async -> AssistantDependencyStatus {
        var failure: AssistantDependencyStatus = .missingCLI
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            guard !Task.isCancelled else { return failure }
            do {
                let version = try await ProcessRunner.run(candidate, arguments: ["--version"], environment: environment, timeout: 5)
                let help = try await ProcessRunner.run(candidate, arguments: assistant == .codex ? ["exec", "--help"] : ["--help"],
                                                       environment: environment, timeout: 5)
                let text = String(decoding: help.stdout, as: UTF8.self)
                guard version.exitCode == 0, help.exitCode == 0,
                      assistant == .codex ? (text.contains("--output-schema") && text.contains("--ignore-user-config")
                        && text.contains("--ignore-rules") && text.contains("--dangerously-bypass-approvals-and-sandbox"))
                        : (text.contains("--json-schema") && text.contains("--tools") && text.contains("--safe-mode")
                            && text.contains("--dangerously-skip-permissions")) else {
                    failure = .invalidCLI
                    continue
                }
                let auth = try await ProcessRunner.run(candidate, arguments: assistant == .codex ? ["login", "status"] : ["auth", "status"],
                                                       environment: environment, timeout: 10)
                guard auth.exitCode == 0 else { failure = .loginRequired(candidate); continue }
                if assistant == .claude {
                    struct Auth: Decodable { let loggedIn: Bool }
                    guard (try? JSONDecoder().decode(Auth.self, from: auth.stdout).loggedIn) == true else {
                        failure = .loginRequired(candidate)
                        continue
                    }
                }
                return .ready(candidate)
            } catch { failure = .invalidCLI }
        }
        return failure
    }

    static func checkUsageLimit(_ assistant: AutomationAssistant, executable: URL) async -> AssistantCLIHealthCheck {
        if assistant == .codex {
            return await CodexAccountProbe.check(executable: executable, environment: environment)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = try await ProcessRunner.run(executable,
                arguments: ["-p", "Reply with OK.", "--tools", "", "--setting-sources", "",
                    "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                    "--no-session-persistence", "--output-format", "json"],
                environment: environment, currentDirectory: folder, timeout: 30)
            if let issue = AssistantCLIHealthIssue.parse(output, assistant: assistant) { return .held(issue) }
            if AssistantCLIHealthIssue.confirmsSuccess(output, assistant: assistant) { return .available }
        } catch {}
        return .unavailable
    }

    enum SetupError: Error { case loginLaunchFailed }

    static func installationGuide(for assistant: AutomationAssistant) -> URL {
        switch assistant {
        case .codex: URL(string: "https://learn.chatgpt.com/docs/codex/cli#install-codex")!
        case .claude: URL(string: "https://code.claude.com/docs/en/setup#install-claude-code")!
        }
    }

    @MainActor
    static func openLogin(_ assistant: AutomationAssistant, executable: URL) async throws {
        let folder = URL.homeDirectory.appending(path: "Library/Application Support/MergeTether/CLI Login")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = folder.appending(path: "Sign in to \(assistant.rawValue).command")
        let command = "#!/bin/zsh\nexec " + AssistantLaunchContext.shellQuote(executable.path)
            + (assistant == .codex ? " login\n" : " auth login\n")
        try Data(command.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // .command uses the user's macOS file association for terminal scripts.
        guard NSWorkspace.shared.open(script) else { throw SetupError.loginLaunchFailed }
    }
}
