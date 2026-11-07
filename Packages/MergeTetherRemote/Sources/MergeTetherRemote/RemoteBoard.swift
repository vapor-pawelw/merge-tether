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

/// A read-only destination, separate from the host-authorized write actions.
public struct RemoteCardCTA: Codable, Equatable, Sendable {
    public enum Destination: String, Codable, Sendable {
        case overview, drafts, feedback, assistantRuns, setup, actions
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .overview
        }
    }
    public var title: String
    public var destination: Destination
    public init(title: String, destination: Destination) { self.title = title; self.destination = destination }
}

public struct RemoteCardChip: Codable, Equatable, Sendable {
    public var title: String
    public var symbol: String
    public init(title: String, symbol: String) { self.title = title; self.symbol = symbol }
}

public struct RemoteCardText: Codable, Equatable, Sendable {
    public var author: String?
    public var repository: String
    public var draftBadge: String?
    public var status: String?
    public var nextStep: String?
    public var working: Bool
    public var chips: [RemoteCardChip]
    public var secondaryCTA: RemoteCardCTA?
    public init(author: String? = nil, repository: String, draftBadge: String? = nil,
                status: String? = nil, nextStep: String? = nil, working: Bool = false,
                chips: [RemoteCardChip] = [], secondaryCTA: RemoteCardCTA? = nil) {
        self.author = author; self.repository = repository; self.draftBadge = draftBadge
        self.status = status; self.nextStep = nextStep; self.working = working
        self.chips = chips; self.secondaryCTA = secondaryCTA
    }
}

/// Optional read-only metadata so older paired installations keep decoding snapshots.
public struct RemoteMRPredecessor: Codable, Equatable, Sendable {
    public var reference: String
    public var title: String
    public var url: URL
    public var isCurrent: Bool
    public init(reference: String, title: String, url: URL, isCurrent: Bool = true) {
        self.reference = reference; self.title = title; self.url = url; self.isCurrent = isCurrent
    }
}

public struct RemoteMRDependencies: Codable, Equatable, Sendable {
    public var stackPosition: String?
    public var predecessors: [RemoteMRPredecessor]
    public var notice: String?
    public init(stackPosition: String? = nil, predecessors: [RemoteMRPredecessor] = [], notice: String? = nil) {
        self.stackPosition = stackPosition; self.predecessors = predecessors; self.notice = notice
    }
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
    // Optional so phones can still read snapshots from an older Mac.
    public var needsAttention: Bool?
    public var mergeRequestIID: Int?
    public var primaryCTA: RemoteCardCTA?
    public var presentation: RemoteCardText?
    public var dependencies: RemoteMRDependencies?
    public init(id: String, title: String, project: String, url: URL?, head: String? = nil,
                detail: String = "", drafts: [RemoteDraft] = [], actions: [RemoteAction] = [],
                needsAttention: Bool? = nil, mergeRequestIID: Int? = nil, primaryCTA: RemoteCardCTA? = nil, presentation: RemoteCardText? = nil, dependencies: RemoteMRDependencies? = nil) {
        self.id = id; self.title = title; self.project = project; self.url = url; self.head = head
        self.detail = detail; self.drafts = drafts; self.actions = actions
        self.needsAttention = needsAttention; self.mergeRequestIID = mergeRequestIID; self.primaryCTA = primaryCTA; self.presentation = presentation; self.dependencies = dependencies
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
