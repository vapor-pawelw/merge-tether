import Foundation

@MainActor
enum CodexPluginInstaller {
    enum Installation: Equatable {
        case missing, disabled, enabled
    }

    enum InstallationError: Error {
        case unsupportedDesktop
        case missingPython
        case commandFailed
    }

    private static let name = "merge-tether"
    private static let marketplace = "merge-tether-desktop"
    private static let bundledPluginID = "\(name)@\(marketplace)"
    private static let dispatchID = "mergetether-dispatch"
    private static let oldBundledVersions = ["0.1.0", "0.1.1", "0.1.2", "0.1.3", "0.1.4", "0.1.5", "0.1.6", "0.1.7", "0.1.8", "0.1.9", "0.1.10", "0.1.11", "0.1.12", "0.1.13", "0.1.14", "0.1.15", "0.1.16"]
    private static var attemptedBundledUpdate = false
    private static let source = URL.homeDirectory
        .appending(path: "Library/Application Support/com.vaporpw.GitLabTodos/Codex Plugin Marketplace")

    private struct Listing: Decodable {
        struct Plugin: Decodable {
            let pluginId: String
            let enabled: Bool
            let version: String?
        }
        let installed: [Plugin]
    }

    static func installation(in data: Data) throws -> Installation {
        let installed = try knownPlugins(in: data)
        if installed.contains(where: \.enabled) { return .enabled }
        return installed.isEmpty ? .missing : .disabled
    }

    private static func knownPlugins(in data: Data) throws -> [Listing.Plugin] {
        let known = ["\(name)@\(marketplace)", "\(name)@merge-tether-local"]
        return try JSONDecoder().decode(Listing.self, from: data).installed
            .filter { known.contains($0.pluginId) }
    }

    static func listenerURL(home: URL = .homeDirectory) -> URL? {
        // Codex doesn't expose external schedule lookup. Read only its known
        // generated record for our heartbeat; if the format changes, use setup.
        let file = home.appending(path: ".codex/automations/\(dispatchID)/automation.toml")
        guard let record = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        let expected = ["id", "kind", "name", "status", "target_thread_id"]
        for line in record.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard expected.contains(key) else { continue }
            let literal = parts[1].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil, let value = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) else {
                return nil
            }
            fields[key] = value
        }
        guard fields["id"] == dispatchID, fields["kind"] == "heartbeat", fields["name"] == "MergeTether dispatch",
              let status = fields["status"], ["ACTIVE", "PAUSED"].contains(status),
              let threadID = fields["target_thread_id"] else { return nil }
        return AssistantAutomationRunner.codexChatURL(threadID)
    }

    static func setupURL() async throws -> URL? {
        try setupURL(in: await currentListing())
    }

    static func setupURL(in data: Data) throws -> URL? {
        let installed = try knownPlugins(in: data)
        guard let plugin = installed.first(where: \.enabled) ?? installed.first else { return nil }
        guard plugin.enabled else { return URL(string: "codex://plugins/\(plugin.pluginId)") }
        let prompt = """
            [@MergeTether](plugin://\(plugin.pluginId))
            Help me set up MergeTether's local Codex listener. Use the merge-tether-setup skill. Check the queue connection and offer the MergeTether dispatch schedule for my approval. If a schedule already exists, show me how to check it. Do not claim any jobs during setup.
            Once Codex confirms which chat owns the schedule, name that chat "[MT] Listener" and organize it in the MergeTether sidebar section using native tools. Reuse the existing listener chat when there is one. If the chat ID cannot be confirmed, leave the sidebar unchanged. Suggest GPT-5.6 Luna with Low reasoning for this listener chat if available.
            """
        var url = URLComponents()
        url.scheme = "codex"
        url.host = "new"
        url.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        return url.url
    }

    static func detect() async throws -> Installation {
        try installation(in: await currentListing())
    }

    private static func currentListing() async throws -> Data {
        let listing = try await run(["plugin", "list", "--json"])
        guard !attemptedBundledUpdate, try knownPlugins(in: listing).contains(where: {
            $0.pluginId == bundledPluginID && $0.enabled && oldBundledVersions.contains($0.version ?? "")
        }) else { return listing }
        attemptedBundledUpdate = true
        do {
            try await installBundledPlugin()
            return try await run(["plugin", "list", "--json"])
        } catch {
            Log.monitor.error("Could not update the enabled Codex plugin: \(String(describing: error), privacy: .private)")
            return listing
        }
    }

    static func installIfMissing() async throws -> Installation {
        let current = try await detect()
        guard current == .missing else { return current }
        try await installBundledPlugin()
        let installed = try await detect()
        guard installed != .missing else { throw InstallationError.commandFailed }
        return installed
    }

    private static func installBundledPlugin() async throws {
        try await checkPython()

        try prepareMarketplace()
        _ = try await run(["plugin", "marketplace", "add", source.path, "--json"])
        _ = try await run(["plugin", "add", bundledPluginID, "--json"])
    }

    static func checkPython() async throws {
        // Avoid invoking the macOS Python shim on machines that lack developer tools.
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"],
                                                 environment: AssistantAutomationRunner.environment, timeout: 5)
        let developer = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, developer.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/python3") else {
            throw InstallationError.missingPython
        }
    }

    private static func prepareMarketplace() throws {
        guard let bundled = Bundle.main.resourceURL?.appending(path: name) else {
            throw InstallationError.commandFailed
        }
        let destination = source.appending(path: "plugins/\(name)")
        for path in [".codex-plugin/plugin.json", "relay.py", "author_follow_up.py", "skills/merge-tether-setup/SKILL.md"] {
            let contents = try Data(contentsOf: bundled.appending(path: path))
            try write(contents, to: destination.appending(path: path))
        }
        // Some Codex versions load legacy MCP entries without expanding PLUGIN_ROOT.
        let template = try String(contentsOf: bundled.appending(path: ".mcp.json"), encoding: .utf8)
        let marker = #""${PLUGIN_ROOT}/relay.py""#
        guard template.contains(marker) else { throw InstallationError.commandFailed }
        let script = try JSONEncoder().encode(destination.appending(path: "relay.py").path)
        let mcp = template.replacingOccurrences(of: marker, with: String(decoding: script, as: UTF8.self))
        try write(Data(mcp.utf8), to: destination.appending(path: ".mcp.json"))
        // Codex gives the previous portable manifest precedence if it remains in the marketplace.
        for path in ["plugin.json", "mcp.json"] {
            let old = destination.appending(path: path)
            if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
        }
        let manifest = """
            {"name":"\(marketplace)","interface":{"displayName":"MergeTether Desktop"},
             "plugins":[{"name":"\(name)","source":{"source":"local","path":"./plugins/\(name)"},
                         "policy":{"installation":"AVAILABLE","authentication":"ON_INSTALL"}}]}
            """
        try write(Data(manifest.utf8), to: source.appending(path: ".agents/plugins/marketplace.json"))
    }

    private static func write(_ contents: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try contents.write(to: file, options: .atomic)
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let app = AssistantAutomationRunner.desktopApplication(.codex),
              let executable = ["Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
                  .map({ app.appending(path: $0) })
                  .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw InstallationError.unsupportedDesktop
        }
        let result = try await ProcessRunner.run(executable, arguments: arguments,
                                                 environment: AssistantAutomationRunner.environment,
                                                 currentDirectory: URL.homeDirectory, timeout: 15)
        guard result.exitCode == 0 else { throw InstallationError.commandFailed }
        return result.stdout
    }
}
