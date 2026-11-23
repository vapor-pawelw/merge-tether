import CryptoKit
import Foundation

public enum DraftRegenerationScope: Codable, Equatable, Sendable {
    public static let maximumInstructionsBytes = 2_000

    case all
    case mergeRequest(projectID: Int, iid: Int)
    case draft(projectID: Int, iid: Int, draftID: Int)
}

/// A fixed rewriting preference that a paired phone may request.
///
/// Remote clients never send prompt text. The Mac maps each case to its own wording,
/// so a phone cannot add instructions to the assistant run.
public enum DraftRegenerationStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case concise
    case friendlier
    case moreDetailed
    case moreDirect
}

public struct DraftRegenerationProposal: Codable, Equatable, Identifiable, Sendable {
    public enum Issue: String, Codable, Sendable { case unchanged, outdated, changed, unavailable, failed, saved }

    public let projectID: Int
    public let iid: Int
    public let draftID: Int
    public let mergeRequestTitle: String
    public let original: String
    public var replacement: String?
    public var issue: Issue?
    public var selectedByDefault: Bool
    public var explanation: String?

    public var id: String { "\(projectID):\(iid):\(draftID)" }

    public init(projectID: Int, iid: Int, draftID: Int, mergeRequestTitle: String, original: String,
                replacement: String? = nil, issue: Issue? = nil, selectedByDefault: Bool = false,
                explanation: String? = nil) {
        self.projectID = projectID
        self.iid = iid
        self.draftID = draftID
        self.mergeRequestTitle = mergeRequestTitle
        self.original = original
        self.replacement = replacement
        self.issue = issue
        self.selectedByDefault = selectedByDefault
        self.explanation = explanation
    }
}

public struct DraftRegenerationBatch: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case generating, ready, saving, finished }

    public let id: UUID
    public let scope: DraftRegenerationScope
    public let total: Int
    public var completed: Int
    public var phase: Phase
    public var proposals: [DraftRegenerationProposal]
    public var savingTotal: Int?
    public var savingCompleted: Int?

    public init(id: UUID, scope: DraftRegenerationScope, total: Int, completed: Int = 0,
                phase: Phase = .generating, proposals: [DraftRegenerationProposal] = [],
                savingTotal: Int? = nil, savingCompleted: Int? = nil) {
        self.id = id
        self.scope = scope
        self.total = total
        self.completed = completed
        self.phase = phase
        self.proposals = proposals
        self.savingTotal = savingTotal
        self.savingCompleted = savingCompleted
    }
}

public struct RemoteDraftRegenerationControl: Codable, Equatable, Sendable {
    public static let cardID = "draft-regeneration"
    public static let startID = "start"
    public static let applyID = "apply"
    public static let discardID = "discard"

    public var card: RemoteCard
    public var count: Int
    public var mergeRequestCount: Int
    /// Snapshot carries progress and counts. Review bodies travel separately in bounded pages.
    public var batch: DraftRegenerationBatch?
    public var previewToken: String?
    public var proposalCount: Int

    public init(card: RemoteCard, count: Int, batch: DraftRegenerationBatch? = nil,
                previewToken: String? = nil, proposalCount: Int = 0, mergeRequestCount: Int = 0) {
        self.card = card
        self.count = count
        self.batch = batch
        self.previewToken = previewToken
        self.proposalCount = proposalCount
        self.mergeRequestCount = mergeRequestCount
    }
}

public enum RemoteDraftRegenerationOperation: Codable, Equatable, Sendable {
    /// Remote hosts reject a non-nil `instructions` value; it remains decodable so legacy
    /// phones receive an explicit refusal instead of a malformed command.
    case start(scope: DraftRegenerationScope, count: Int, instructions: String?, style: DraftRegenerationStyle? = nil)
    case apply(batchID: UUID, proposalIDs: [String])
    case discard(batchID: UUID)

    public static let maximumArgumentBytes = 100_000

    public var argument: String? {
        guard let bytes = try? JSONEncoder().encode(self), bytes.count <= Self.maximumArgumentBytes,
              let argument = String(data: bytes, encoding: .utf8),
              // RemoteCommand embeds this JSON in a string. Leave room for re-escaping and the envelope.
              let encoded = try? JSONEncoder().encode(argument),
              encoded.count <= RemoteCipher.maximumPayloadBytes - 2_048 else { return nil }
        return argument
    }

    public init?(argument: String?) {
        guard let argument, argument.utf8.count <= Self.maximumArgumentBytes,
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(argument.utf8)) else { return nil }
        self = decoded
    }
}

public struct RemoteDraftRegenerationPageRequest: Codable, Equatable, Sendable {
    public let hostSession: UUID
    public let account: String
    public let batchID: UUID
    public let previewToken: String
    public let offset: Int

    public init(hostSession: UUID, account: String, batchID: UUID, previewToken: String, offset: Int) {
        self.hostSession = hostSession
        self.account = account
        self.batchID = batchID
        self.previewToken = previewToken
        self.offset = offset
    }
}

public struct RemoteDraftRegenerationPage: Codable, Equatable, Sendable {
    // A ready and saved preview can both transfer within the relay's per-minute message budget.
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let pageBytes = 48 * 1_024

    public let request: RemoteDraftRegenerationPageRequest
    /// A nil body reports the requested preview no longer exists.
    public let data: Data?
    public let totalBytes: Int

    public init(request: RemoteDraftRegenerationPageRequest, data: Data? = nil, totalBytes: Int = 0) {
        self.request = request
        self.data = data
        self.totalBytes = totalBytes
    }

    public static func token(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
