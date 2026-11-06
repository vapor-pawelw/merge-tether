import Foundation

enum AssistantDependencyStatus: Equatable, Sendable {
    case ready(URL), desktopOnly, missingDesktop, missingCLI, invalidCLI, loginRequired(URL)

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
    static func detect(_ assistant: AutomationAssistant, requireCLI: Bool) async -> AssistantDependencyStatus {
        let optionalApp = AssistantAutomationRunner.desktopApplication(assistant)
        return await check(assistant, desktopURL: nil, candidates: candidates(for: assistant, desktopURL: optionalApp))
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

    static func check(_ assistant: AutomationAssistant, desktopURL: URL?, candidates: [URL],
                      requireCLI: Bool = true) async -> AssistantDependencyStatus {
        // Legacy desktop/verification parameters cannot weaken the automation dependency gate.
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

    enum SetupError: Error { case installationFailed }

    static func install(_ assistant: AutomationAssistant) async throws {
        let url = URL(string: assistant == .codex ? "https://chatgpt.com/codex/install.sh" : "https://claude.ai/install.sh")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty, data.count < 2_000_000 else {
            throw SetupError.installationFailed
        }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "install.sh")
        try data.write(to: script)
        var env = environment
        env["CODEX_NON_INTERACTIVE"] = "1"
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path],
                                                 environment: env, currentDirectory: .homeDirectory, timeout: 180)
        guard output.exitCode == 0 else { throw SetupError.installationFailed }
    }

    @MainActor
    static func openLogin(_ assistant: AutomationAssistant, executable: URL) async throws {
        let command = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' "
            + (assistant == .codex ? "login" : "auth login")
        let literal = AssistantLaunchContext.appleScriptLiteral(command)
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e",
            "tell application \"Terminal\"\nactivate\ndo script \(literal)\nend tell"], environment: environment)
        guard result.exitCode == 0 else { throw SetupError.installationFailed }
    }
}
