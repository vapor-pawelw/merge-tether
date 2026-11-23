import Foundation

enum GlabError: Error, Equatable, Sendable {
    case glabNotInstalled
    case notAuthenticated
    case network(String)
    case decoding(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case unknown(String)

    var isTransientReadFailure: Bool {
        switch self {
        case .network, .timedOut: true
        case .nonZeroExit(_, let diagnostic):
            [408, 429, 500, 502, 503, 504].contains { Self.hasHTTPStatus($0, in: diagnostic) }
        default: false
        }
    }

    var isNotFound: Bool {
        guard case .nonZeroExit(_, let diagnostic) = self else { return false }
        return Self.hasHTTPStatus(404, in: diagnostic)
    }

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
        let reason: String? = switch status {
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not found"
        case 408: "request timeout"
        case 429: "too many requests"
        case 500: "internal server error"
        case 502: "bad gateway"
        case 503: "service unavailable"
        case 504: "gateway timeout"
        default: nil
        }
        let bareStatus = reason.map { reason in #"|\b\#(status)\s+\#(reason)\b"# } ?? ""
        let pattern = #"(?i)\bHTTP(?:/[0-9.]+)?\s+\#(status)\b\#(bareStatus)"#
        return diagnostic.range(of: pattern, options: .regularExpression) != nil
    }
}
