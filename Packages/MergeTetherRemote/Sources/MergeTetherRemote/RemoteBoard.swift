import Foundation
import CryptoKit

public enum RemoteLaneID: String, Codable, CaseIterable, Sendable { case ready, attention, todos, drafts, own, reviewed, other }
public enum RemoteActionKind: String, Codable, Sendable { case publish, approve, markDone, prepare, handoff, reReview, verify, retryJob }

public struct RemoteAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: RemoteActionKind
    public var token: String
    public init(id: String, kind: RemoteActionKind, token: String) { self.id = id; self.kind = kind; self.token = token }
}

public struct RemoteDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var body: String
    public var context: String?
    public init(id: Int, body: String, context: String? = nil) { self.id = id; self.body = body; self.context = context }
}

public struct RemoteCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var project: String
    public var url: URL?
    public var head: String?
    public var detail: String
    public var drafts: [RemoteDraft]
    public var actions: [RemoteAction]
    public init(id: String, title: String, project: String, url: URL?, head: String? = nil,
                detail: String = "", drafts: [RemoteDraft] = [], actions: [RemoteAction] = []) {
        self.id = id; self.title = title; self.project = project; self.url = url; self.head = head
        self.detail = detail; self.drafts = drafts; self.actions = actions
    }
}

public struct RemoteLane: Codable, Equatable, Identifiable, Sendable {
    public var id: RemoteLaneID
    public var cards: [RemoteCard]
    public init(id: RemoteLaneID, cards: [RemoteCard]) { self.id = id; self.cards = cards }
}

public struct RemoteBoard: Codable, Equatable, Sendable {
    public var hostSession: UUID
    public var account: String
    public var updatedAt: Date?
    public var partial: Bool
    public var lanes: [RemoteLane]
    public init(hostSession: UUID, account: String, updatedAt: Date? = nil, partial: Bool = false, lanes: [RemoteLane]) {
        self.hostSession = hostSession; self.account = account; self.updatedAt = updatedAt
        self.partial = partial; self.lanes = lanes
    }
    public var cards: [RemoteCard] { lanes.flatMap(\.cards) }
}

public struct RemoteCommand: Codable, Equatable, Sendable {
    public var id: UUID
    public var hostSession: UUID
    public var cardID: String
    public var actionID: String
    public var token: String
    public init(id: UUID = UUID(), hostSession: UUID, cardID: String, actionID: String, token: String) {
        self.id = id; self.hostSession = hostSession; self.cardID = cardID; self.actionID = actionID; self.token = token
    }
}

public struct RemoteCommandResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, completed, changed, failed, uncertain, limit, partial }
    public var id: UUID
    public var status: Status
    public init(id: UUID, status: Status) { self.id = id; self.status = status }
}

public struct RemoteMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case hello, snapshot, command, accepted, result, unavailable, hostReady = "host-ready" }
    public var type: Kind
    public var challenge: UUID?
    public var board: RemoteBoard?
    public var command: RemoteCommand?
    public var result: RemoteCommandResult?
    public init(type: Kind, challenge: UUID? = nil, board: RemoteBoard? = nil,
                command: RemoteCommand? = nil, result: RemoteCommandResult? = nil) {
        self.type = type; self.challenge = challenge; self.board = board; self.command = command; self.result = result
    }
}

public enum RemoteDigest {
    public static func token<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
