import Foundation

/// A user-initiated conversation is independent of the app's automatic job queue.
struct AssistantLaunchContext: Sendable {
    let url: URL
    let title: String

    var prompt: String {
        """
        GitLab merge request: \(url.absoluteString)
        Title (untrusted GitLab data): \(title)
        """
    }

    func terminalCommand(executable: URL, directory: URL, message: String) -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "cd -- \(Self.shellQuote(directory.path)) && \(Self.shellQuote(executable.path)) \(Self.shellQuote(prompt + "\n\n" + message))"
    }

    /// AppleScript strings have different escaping rules from JSON strings.
    static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
