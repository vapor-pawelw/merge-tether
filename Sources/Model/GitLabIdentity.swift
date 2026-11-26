/// The host-local GitLab ID is stable across changes to the account's username.
struct GitLabAccountIdentity: Codable, Hashable, Sendable {
    let host: String
    let username: String
    let userID: Int?

    init(host: String, username: String, userID: Int? = nil) {
        self.host = host
        self.username = username
        self.userID = userID
    }

    func matches(_ other: Self) -> Bool {
        guard host == other.host else { return false }
        if let userID, let otherID = other.userID { return userID == otherID }
        return username == other.username
    }

    // Legacy matching is deliberately separate from Hashable: an unbound username
    // cannot be equal to two distinct IDs that used the same name at different times.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.host == rhs.host && lhs.userID == rhs.userID
            && (lhs.userID != nil || lhs.username == rhs.username)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(userID)
        if userID == nil { hasher.combine(username) }
    }

    static func normalize(_ value: String) -> String { value.lowercased() }
}

struct GitLabAccountSession: Hashable, Sendable {
    let account: GitLabAccountIdentity
    let revision: UInt64

    var host: String { account.host }
    var username: String { account.username }

    init(host: String, username: String, userID: Int? = nil, revision: UInt64) {
        account = .init(host: host, username: username, userID: userID)
        self.revision = revision
    }
}

/// A merge request within an already established GitLab host and account.
struct GitLabMergeRequestID: Codable, Hashable, Sendable {
    let projectID: Int
    let iid: Int
}
