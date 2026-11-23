import Foundation

public struct ReviewerCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let username: String
    public let avatarURL: URL?

    public init(id: Int, name: String, username: String, avatarURL: URL? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.avatarURL = avatarURL
    }
}

public struct ReviewerChange: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case add, remove }

    public let operation: Operation
    public let reviewerID: Int
    public let username: String

    public init(_ operation: Operation, reviewerID: Int, username: String) {
        self.operation = operation
        self.reviewerID = reviewerID
        self.username = username
    }

    public init?(argument: String?) {
        guard let argument, argument.utf8.count <= 512,
              let change = try? JSONDecoder().decode(Self.self, from: Data(argument.utf8)),
              change.reviewerID > 0, !change.username.isEmpty else { return nil }
        self = change
    }

    public var argument: String? {
        try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)
    }

    public struct Batch: Encodable, Sendable {
        public static let maximumCount = 30
        private static let maximumArgumentBytes = 16_384
        public let changes: [ReviewerChange]

        public init?(_ changes: [ReviewerChange]) {
            guard (2...Self.maximumCount).contains(changes.count),
                  changes.allSatisfy({ $0.operation == .add && $0.reviewerID > 0 && !$0.username.isEmpty && $0.username.utf8.count <= 255 }),
                  Set(changes.map(\.reviewerID)).count == changes.count else { return nil }
            self.changes = changes
        }

        public init?(argument: String?) {
            struct Payload: Decodable { let changes: [ReviewerChange] }
            guard let argument, argument.utf8.count <= Self.maximumArgumentBytes,
                  let payload = try? JSONDecoder().decode(Payload.self, from: Data(argument.utf8)) else { return nil }
            self.init(payload.changes)
        }

        public var argument: String? {
            guard let data = try? JSONEncoder().encode(self), data.count <= Self.maximumArgumentBytes else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

public struct RemoteReviewerSearch: Codable, Equatable, Sendable {
    public let id: UUID
    public let hostSession: UUID
    public let account: String
    public let cardID: String
    public let token: String
    public let query: String

    public init(board: RemoteBoard, card: RemoteCard, action: RemoteAction, query: String) {
        id = UUID()
        hostSession = board.hostSession
        account = board.account
        cardID = card.id
        token = action.token
        self.query = query
    }

    public func matches(_ board: RemoteBoard) -> Bool {
        guard !board.partial, hostSession == board.hostSession, account == board.account,
              query.utf8.count <= 128 else { return false }
        return board.cards.contains { card in
            card.id == cardID && card.actions.contains { $0.kind == .editReviewers && $0.token == token }
        }
    }
}

public struct RemoteReviewerResults: Codable, Sendable {
    public let id: UUID
    public let candidates: [ReviewerCandidate]?

    public init(id: UUID, candidates: [ReviewerCandidate]?) {
        self.id = id
        self.candidates = candidates
    }

    public var avatarThumbnailURLs: [URL] {
        RemoteAvatarThumbnail.eligibleURLs(candidates?.compactMap(\.avatarURL) ?? [])
    }
}
