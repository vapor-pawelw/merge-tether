import Foundation

public struct ReviewerCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let username: String

    public init(id: Int, name: String, username: String) {
        self.id = id
        self.name = name
        self.username = username
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
}
