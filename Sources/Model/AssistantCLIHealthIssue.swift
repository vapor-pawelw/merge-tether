import Foundation

struct AssistantCLIHealthIssue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case loginRequired, rateLimited }
    let kind: Kind
    var resetsAt: Date? = nil
    var resetHint: String? = nil

    static func parse(_ output: ProcessRunner.Output, assistant: AutomationAssistant, now: Date = Date()) -> Self? {
        // Only provider error records are evidence. Tool output and normal assistant text are untrusted content.
        let lines = String(decoding: output.stdout.suffix(131_072), as: UTF8.self).split(separator: "\n")
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = object["type"] as? String
            if output.exitCode == 0,
               (assistant == .codex && type == "turn.completed"
                || assistant == .claude && type == "result" && object["is_error"] as? Bool == false) { return nil }
            let isError = type == "error" || type == "turn.failed"
                || (assistant == .claude && type == "result" && object["is_error"] as? Bool == true)
                || (assistant == .claude && type == "assistant" && object["error"] is String)
            let rate = object["rate_limit_info"] as? [String: Any]
            if assistant == .claude, type == "rate_limit_event", rate?["status"] as? String == "rejected" {
                return .init(kind: .rateLimited, resetsAt: resetDate(rate ?? [:], now: now))
            }
            guard isError else { continue }
            let error = object["error"] as? [String: Any] ?? object
            let code = (error["code"] as? String ?? object["error"] as? String ?? error["type"] as? String ?? "").lowercased()
            let message = error["message"] as? String ?? object["result"] as? String
                ?? (object["errors"] as? [String])?.joined(separator: "\n") ?? ""
            if let kind = classify(code: code, message: message) {
                return .init(kind: kind, resetsAt: resetDate(error, now: now) ?? resetDate(object, now: now),
                    resetHint: resetHint(message))
            }
        }
        guard output.exitCode != 0 else { return nil }
        if let kind = classify(code: "", message: output.stderr) {
            return .init(kind: kind, resetHint: resetHint(output.stderr))
        }
        // Claude can refuse startup before its JSON formatter is initialized.
        // Do not inspect text nested inside otherwise structured tool/assistant output.
        if assistant == .claude, output.stdout.count <= 16_384,
           !lines.contains(where: { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }) {
            let message = String(decoding: output.stdout, as: UTF8.self)
            if let kind = classify(code: "", message: message) { return .init(kind: kind, resetHint: resetHint(message)) }
        }
        return nil
    }

    static func confirmsSuccess(_ output: ProcessRunner.Output, assistant: AutomationAssistant) -> Bool {
        guard output.exitCode == 0, parse(output, assistant: assistant) == nil else { return false }
        for line in String(decoding: output.stdout.suffix(131_072), as: UTF8.self).split(separator: "\n").reversed() {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if assistant == .codex {
                if value["type"] as? String == "turn.failed" { return false }
                if value["type"] as? String == "turn.completed" { return true }
            } else if value["type"] as? String == "result" { return value["is_error"] as? Bool == false }
        }
        return false
    }

    private static func classify(code: String, message: String) -> Kind? {
        let message = message.lowercased().replacingOccurrences(of: "’", with: "'")
        if ["authentication_error", "authentication_failed", "invalid_api_key", "token_expired", "refresh_token_reused"].contains(code)
            || ["please log in again", "please login again", "not logged in", "please run /login", "please run 'codex login'",
                "failed to refresh token", "your access token has expired", "your authentication token has expired"].contains(where: message.contains) {
            return .loginRequired
        }
        if ["rate_limit_error", "rate_limit_exceeded", "rate_limit", "usage_limit_reached", "insufficient_quota", "billing_error"].contains(code)
            || ["you've hit your usage limit", "you have hit your usage limit", "you've hit your limit", "you've hit your session limit", "usage limit reached",
                "you are out of extra usage", "you're out of extra usage", "credit balance is too low"].contains(where: message.contains) {
            return .rateLimited
        }
        return nil
    }

    private static func resetDate(_ fields: [String: Any], now: Date) -> Date? {
        for key in ["resets_at", "reset_at", "resetsAt"] {
            if let seconds = fields[key] as? Double, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
            if let value = fields[key] as? String, let date = ISO8601DateFormatter().date(from: value) { return date }
        }
        if let seconds = fields["retry_after"] as? Double, seconds > 0, seconds < 31_536_000 {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    private static func resetHint(_ message: String) -> String? {
        guard let range = message.range(of: "try again at ", options: .caseInsensitive)
            ?? message.range(of: "resets ", options: .caseInsensitive) else { return nil }
        let value = String(message[range.upperBound...].prefix(while: { $0 != "\n" })).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ,:/+.-()"))
        guard !value.isEmpty, value.count <= 120, value.rangeOfCharacter(from: .decimalDigits) != nil,
              value.unicodeScalars.allSatisfy(permitted.contains) else { return nil }
        return value
    }
}
