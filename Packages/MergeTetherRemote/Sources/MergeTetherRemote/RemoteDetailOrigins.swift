import Foundation

public struct RemoteDetailOriginChange: Codable, Equatable, Sendable {
    public let threadID: String
    public let noteID: String
    public let identity: String
    public let origin: RemoteDetailNote.Origin
    public let revision: UInt64

    public init(threadID: String, noteID: String, identity: String, origin: RemoteDetailNote.Origin, revision: UInt64 = 1) {
        self.threadID = threadID; self.noteID = noteID; self.identity = identity; self.origin = origin
        self.revision = revision
    }
}

/// Metadata for one already delivered conversation; never a board lease or an action grant.
public struct RemoteDetailOrigins: Codable, Equatable, Sendable {
    public let request: RemoteDetailRequest
    public let changes: [RemoteDetailOriginChange]

    public init(request: RemoteDetailRequest, changes: [RemoteDetailOriginChange]) {
        self.request = request; self.changes = changes
    }
}

extension RemoteDetailNote {
    public func originIdentity(in threadID: String) -> String? {
        guard !threadID.isEmpty, let noteID = Int(id), noteID > 0, let authorID, authorID > 0 else { return nil }
        return try? RemoteDigest.token([threadID, id, String(authorID), body])
    }
}
