import AppKit
import Foundation

@MainActor
enum AssistantContextLauncher {
    enum Destination: String, CaseIterable, Identifiable {
        case codexApp, claudeDesktop, codexCLI, claudeCLI
        var id: String { rawValue }
        var assistant: AutomationAssistant {
            switch self { case .codexApp, .codexCLI: .codex; case .claudeDesktop, .claudeCLI: .claude }
        }
        var isCLI: Bool { self == .codexCLI || self == .claudeCLI }
        var label: LocalizedStringResource {
            switch self {
            case .codexApp: .AssistantContext.assistantContextCodexApp
            case .claudeDesktop: .AssistantContext.assistantContextClaudeDesktop
            case .codexCLI: .AssistantContext.assistantContextCodexCLI
            case .claudeCLI: .AssistantContext.assistantContextClaudeCLI
            }
        }
    }

    static func availableDestinations() -> [Destination] {
        Destination.allCases.filter { destination in
            destination.isCLI ? executable(for: destination.assistant) != nil
                : AssistantAutomationRunner.desktopApplication(destination.assistant) != nil
        }
    }

    static func executable(for assistant: AutomationAssistant) -> URL? {
        AssistantCLI.candidates(for: assistant, desktopURL: AssistantAutomationRunner.desktopApplication(assistant))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func open(_ destination: Destination, context: AssistantLaunchContext, workspace: String) async throws {
        if destination.isCLI {
            guard let executable = executable(for: destination.assistant) else { throw LaunchError.unavailable }
            let directory = try contextDirectory(workspace: workspace)
            let command = context.terminalCommand(executable: executable, directory: directory)
            let literal = AssistantLaunchContext.appleScriptLiteral(command)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e",
                "tell application \"Terminal\"\nactivate\ndo script \(literal)\nend tell"],
                environment: AssistantCLI.environment)
            guard result.exitCode == 0 else { throw LaunchError.failed }
        } else {
            guard let app = AssistantAutomationRunner.desktopApplication(destination.assistant),
                  let url = AssistantAutomationRunner.draftURL(for: destination.assistant, prompt: context.prompt, path: nil)
            else { throw LaunchError.unavailable }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // Very long GitLab titles should not overflow URL dispatch. In that case the
            // explicit manual action puts the context on the clipboard for the user to paste.
            if url.absoluteString.utf8.count > 12_000 {
                AssistantAutomationRunner.copyPrompt(context.prompt)
                guard let plain = AssistantAutomationRunner.draftURL(for: destination.assistant, prompt: nil, path: nil)
                else { throw LaunchError.failed }
                _ = try await NSWorkspace.shared.open([plain], withApplicationAt: app, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            }
        }
    }

    private static func contextDirectory(workspace: String) throws -> URL {
        let path = (workspace.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let directory = URL.homeDirectory.appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Manual Contexts")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    enum LaunchError: Error { case unavailable, failed }
}
