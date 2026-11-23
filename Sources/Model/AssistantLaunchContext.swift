import Foundation

/// A user-initiated conversation is independent of the app's automatic job queue.
struct AssistantLaunchContext: Sendable {
    let url: URL

    var t3CodeDraftURL: URL? {
        var components = URLComponents()
        components.scheme = "t3code"
        components.host = "new"
        components.queryItems = [URLQueryItem(name: "prompt", value: "Regarding \(url.absoluteString), ")]
        // T3 Code uses URLSearchParams, which interprets a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func terminalCommand(executable: URL, directory: URL, message: String) -> String? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prompt = url.absoluteString + "\n\n" + message
        return "cd -- \(Self.shellQuote(directory.path)) && \(Self.shellQuote(executable.path)) \(Self.shellQuote(prompt))"
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
