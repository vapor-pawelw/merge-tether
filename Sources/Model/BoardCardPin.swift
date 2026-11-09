import Foundation

/// Account-scoped display preference; an MR keeps its identity when a proposal is adopted.
struct BoardCardPin: Codable, Hashable, Sendable {
    enum Item: Codable, Hashable, Sendable {
        case mergeRequest(projectID: Int, iid: Int)
        case todo(Int)
        case completion(UUID)
    }
    let host: String
    let username: String
    let item: Item

    static func mergeRequest(host: String?, username: String?, projectID: Int, iid: Int) -> Self? {
        guard let host, !host.isEmpty, let username, !username.isEmpty, projectID > 0, iid > 0 else { return nil }
        return .init(host: host, username: username, item: .mergeRequest(projectID: projectID, iid: iid))
    }

    static func todo(host: String?, username: String?, id: Int) -> Self? {
        guard let host, !host.isEmpty, let username, !username.isEmpty, id > 0 else { return nil }
        return .init(host: host, username: username, item: .todo(id))
    }
}
