import Foundation

enum GlabError: Error, Equatable, Sendable {
    case glabNotInstalled
    case notAuthenticated
    case network(String)
    case decoding(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case unknown(String)

    static func classify(exitCode: Int32, stderr: String) -> GlabError {
        let lower = stderr.lowercased()
        if lower.contains("dial tcp")
            || lower.contains("no such host")
            || lower.contains("connection refused")
            || lower.contains("network is unreachable")
            || lower.contains("tls handshake")
            || lower.contains("i/o timeout")
            || lower.contains("network unavailable")
            || lower.contains("connection reset")
            || lower.contains("could not resolve host")
            || lower.contains("context deadline exceeded")
        {
            return .network(stderr)
        }
        if lower.contains("not authenticated")
            || lower.contains("please authenticate")
            || lower.contains("not logged in")
            || lower.contains("no token found")
            || lower.contains("unauthorized")
            || hasHTTPStatus(401, in: stderr)
        {
            return .notAuthenticated
        }
        return .nonZeroExit(code: exitCode, stderr: stderr)
    }

    static func hasHTTPStatus(_ status: Int, in diagnostic: String) -> Bool {
        let reason = status == 401 ? "unauthorized" : "forbidden"
        return diagnostic.range(of: #"(?i)\bHTTP(?:/[0-9.]+)?\s+"# + String(status) + #"\b|\b"#
            + String(status) + #"\s+"# + reason + #"\b"#, options: .regularExpression) != nil
    }
}
