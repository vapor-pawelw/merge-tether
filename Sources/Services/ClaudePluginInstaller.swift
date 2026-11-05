import Foundation

/// Installs MergeTether's relay tools into Claude Code (and so Claude Desktop's Code sessions)
/// as a local plugin. It mirrors `CodexPluginInstaller` but shares only the relay script.
@MainActor
enum ClaudePluginInstaller {
    enum Installation: Equatable {
        case missing, disabled, enabled
    }

    enum InstallationError: Error {
        case missingCLI
        case missingPython
        case commandFailed
    }

    static let pluginID = "merge-tether@merge-tether-desktop"
    private static let name = "merge-tether"
    private static let marketplace = "merge-tether-desktop"
    static let source = URL.homeDirectory
        .appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Claude Plugin Marketplace")

    private struct Listed: Decodable {
        let id: String
        let enabled: Bool
    }

    static func installation(in data: Data) throws -> Installation {
        let plugins = try JSONDecoder().decode([Listed].self, from: data).filter { $0.id == pluginID }
        if plugins.contains(where: \.enabled) { return .enabled }
        return plugins.isEmpty ? .missing : .disabled
    }

    static func executable(home: URL = .homeDirectory) -> URL? {
        [home.appending(path: ".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
         URL(fileURLWithPath: "/usr/local/bin/claude")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func detect() async throws -> Installation {
        let state = try installation(in: await run(["plugin", "list", "--json"]))
        // A local plugin loads in place, so refreshing its files keeps it current.
        if state != .missing { try? prepareMarketplace() }
        return state
    }

    static func installIfMissing() async throws -> Installation {
        let current = try await detect()
        guard current == .missing else { return current }
        try await CodexPluginInstaller.checkPython()
        try prepareMarketplace()
        _ = try await run(["plugin", "marketplace", "add", source.path])
        _ = try await run(["plugin", "install", pluginID])
        let installed = try await detect()
        guard installed != .missing else { throw InstallationError.commandFailed }
        return installed
    }

    private static func prepareMarketplace() throws {
        guard let bundled = Bundle.main.resourceURL?.appending(path: name) else { throw InstallationError.commandFailed }
        let destination = source.appending(path: "plugins/\(name)")
        for path in [".claude-plugin/plugin.json", "relay.py", "author_follow_up.py"] {
            try write(Data(contentsOf: bundled.appending(path: path)), to: destination.appending(path: path))
        }
        let script = try JSONEncoder().encode(destination.appending(path: "relay.py").path)
        let mcp = #"{"mcpServers":{"merge-tether-relay":{"command":"/usr/bin/python3","args":["-B",\#(String(decoding: script, as: UTF8.self))]}}}"#
        try write(Data(mcp.utf8), to: destination.appending(path: ".mcp.json"))
        let manifest = """
            {"name":"\(marketplace)","owner":{"name":"MergeTether"},
             "plugins":[{"name":"\(name)","source":"./plugins/\(name)",
                         "description":"MergeTether tools for Claude Code."}]}
            """
        try write(Data(manifest.utf8), to: source.appending(path: ".claude-plugin/marketplace.json"))
    }

    private static func write(_ contents: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try contents.write(to: file, options: .atomic)
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let executable = executable() else { throw InstallationError.missingCLI }
        let result = try await ProcessRunner.run(executable, arguments: arguments,
                                                 environment: AssistantAutomationRunner.environment,
                                                 currentDirectory: URL.homeDirectory, timeout: 60)
        guard result.exitCode == 0 else { throw InstallationError.commandFailed }
        return result.stdout
    }
}
