import Foundation

extension GlabService {
    /// Resolve a user-entered handle once; publication policy stores the server ID,
    /// so a renamed account or a reused display name cannot acquire its permission.
    func resolvePublicationUser(username: String, host: String) async throws -> PublicationIdentity {
        var handle = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !handle.isEmpty, handle.count <= 255, !host.isEmpty,
              handle.unicodeScalars.allSatisfy(allowed.contains),
              let escaped = handle.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw GlabError.decoding("Invalid GitLab username")
        }
        let users: [GitLabWorkflowUser] = try await mergeRequestAPI("/users?username=\(escaped)", host: host)
        guard users.count == 1, let user = users.first, user.id > 0,
              let canonical = user.username, canonical.caseInsensitiveCompare(handle) == .orderedSame else {
            throw GlabError.decoding("GitLab did not return the requested user")
        }
        return .init(host: host, entityID: user.id, label: "@\(canonical)")
    }
}
