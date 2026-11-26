/// The spelling from the active GitLab account. Permission and persistence lookups use it verbatim.
struct GitLabAccountIdentity: Hashable, Sendable {
    let host: String
    let username: String

    static func normalize(_ value: String) -> String { value.lowercased() }
}

struct GitLabAccountSession: Hashable, Sendable {
    private let account: GitLabAccountIdentity
    let revision: UInt64

    var host: String { account.host }
    var username: String { account.username }

    init(host: String, username: String, revision: UInt64) {
        account = .init(host: host, username: username)
        self.revision = revision
    }
}

/// A merge request within an already established GitLab host and account.
struct GitLabMergeRequestID: Codable, Hashable, Sendable {
    let projectID: Int
    let iid: Int
}
