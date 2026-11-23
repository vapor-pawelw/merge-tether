import AppKit
import Foundation

@MainActor
enum AssistantContextLauncher {
    enum Destination: String, CaseIterable, Identifiable, Sendable {
        case codexApp, claudeDesktop, t3Code, codexCLI, claudeCLI
        var id: String { rawValue }
        fileprivate var cliAssistant: AutomationAssistant? {
            switch self {
            case .codexCLI: .codex
            case .claudeCLI: .claude
            case .codexApp, .claudeDesktop, .t3Code: nil
            }
        }
        var isCLI: Bool { cliAssistant != nil }
        var label: LocalizedStringResource {
            switch self {
            case .codexApp: .AssistantContext.assistantContextCodexApp
            case .claudeDesktop: .AssistantContext.assistantContextClaudeDesktop
            case .t3Code: .AssistantContext.assistantContextT3Code
            case .codexCLI: .AssistantContext.assistantContextCodexCLI
            case .claudeCLI: .AssistantContext.assistantContextClaudeCLI
            }
        }
    }

    static func availableDestinations() -> [Destination] {
        Destination.allCases.filter { destination in
            if let assistant = destination.cliAssistant { return executable(for: assistant) != nil }
            return desktopApplication(for: destination) != nil
        }
    }

    private static func desktopApplication(for destination: Destination) -> URL? {
        switch destination {
        case .codexApp: AssistantAutomationRunner.desktopApplication(.codex)
        case .claudeDesktop: AssistantAutomationRunner.desktopApplication(.claude)
        case .t3Code: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code")
        case .codexCLI, .claudeCLI: nil
        }
    }

    static func executable(for assistant: AutomationAssistant) -> URL? {
        AssistantCLI.candidates(for: assistant, desktopURL: AssistantAutomationRunner.desktopApplication(assistant))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func open(_ destination: Destination, context: AssistantLaunchContext, workspace: String, message: String = "") async throws {
        if let assistant = destination.cliAssistant {
            guard let executable = executable(for: assistant) else { throw LaunchError.unavailable }
            let directory = try contextDirectory(workspace: workspace)
            guard let command = context.terminalCommand(executable: executable, directory: directory, message: message)
            else { throw LaunchError.failed }
            let literal = AssistantLaunchContext.appleScriptLiteral(command)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e",
                "tell application \"Terminal\"\nactivate\ndo script \(literal)\nend tell"],
                environment: AssistantCLI.environment)
            guard result.exitCode == 0 else { throw LaunchError.failed }
        } else {
            guard let app = desktopApplication(for: destination) else { throw LaunchError.unavailable }
            let url: URL
            if destination == .t3Code {
                guard let draftURL = context.t3CodeDraftURL else { throw LaunchError.failed }
                url = draftURL
            } else {
                // A file opens an unassigned conversation with an attachment and an empty composer.
                // Keep the file available for the assistant to read after the user sends.
                url = try writeAttachment(context, in: contextRoot)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        }
    }

    static func writeAttachment(_ context: AssistantLaunchContext, in root: URL) throws -> URL {
        let directory = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: "MR-context.txt")
        try context.url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private static var contextRoot: URL {
        InstallationStorage.current.root
            .appending(path: "Manual Contexts")
    }

    private static func contextDirectory(workspace: String) throws -> URL {
        let path = (workspace.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let directory = contextRoot.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    enum LaunchError: Error { case unavailable, failed }
}
