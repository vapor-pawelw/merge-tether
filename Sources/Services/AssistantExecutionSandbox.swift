import Foundation

/// Writable evidence is separate from app-owned permission records. Claude file
/// writes use Bash exclusively, so the OS-enforced Bash sandbox covers every edit.
struct AssistantExecutionSandbox {
    let workspace: URL
    let evidenceRoot: URL
    let host: String

    var writableEvidenceDirectories: [URL] {
        ["verdicts", "ai-assessments", "follow-up-preflight", "follow-up-verifications", "follow-up-locks"]
            .map { evidenceRoot.appending(path: $0, directoryHint: .isDirectory) }
    }

    var claudeTools: String { "Read,Glob,Grep,Bash" }

    var claudeSettings: String {
        let domain = URLComponents(string: "https://\(host)")?.host ?? host
        var network: [String: Any] = ["allowedDomains": [domain]]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], socket.hasPrefix("/") {
            network["allowUnixSockets"] = [socket]
        }
        let settings: [String: Any] = [
            "sandbox": [
                "enabled": true,
                "failIfUnavailable": true,
                "autoAllowBashIfSandboxed": true,
                "allowUnsandboxedCommands": false,
                "excludedCommands": [String](),
                "filesystem": [
                    "disabled": false,
                    "allowWrite": writableEvidenceDirectories.map(\.path),
                    "denyWrite": [evidenceRoot.appending(path: "follow-up-runs").path],
                ],
                "network": network,
            ],
            "permissions": ["deny": ["Edit", "Write", "NotebookEdit"]],
        ]
        // These fixed JSON values are serializable; the fallback also fails closed.
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func prepare() throws {
        for directory in writableEvidenceDirectories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }
}
