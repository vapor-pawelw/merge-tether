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
        if lower.contains("not authenticated")
            || lower.contains("please authenticate")
            || lower.contains("401")
            || lower.contains("unauthorized")
        {
            return .notAuthenticated
        }
        if lower.contains("dial tcp")
            || lower.contains("no such host")
            || lower.contains("connection refused")
            || lower.contains("network is unreachable")
            || lower.contains("tls handshake")
            || lower.contains("i/o timeout")
        {
            return .network(stderr)
        }
        return .nonZeroExit(code: exitCode, stderr: stderr)
    }
}
