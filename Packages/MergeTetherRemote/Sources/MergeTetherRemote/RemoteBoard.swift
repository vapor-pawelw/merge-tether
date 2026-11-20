import Foundation
import CryptoKit

public enum RemoteLaneID: String, Codable, CaseIterable, Sendable { case ready, attention, todos, drafts, own, reviewed, other }
public enum RemoteActionKind: String, Codable, Sendable { case publish, approve, markDone, prepare, handoff, reReview, verify, retryJob, deleteDraft, finishCommentReview, merge, enqueueMerge, resolveThreads, checkThreads
    // MR controls; sent only to phones that announce `mrControlsCapability`.
    case publishDraft, runReview, stopJob, ignoreSuggestion, restoreSuggestion
    public static let mrControls: Set<RemoteActionKind> = [.publishDraft, .runReview, .stopJob, .ignoreSuggestion, .restoreSuggestion]
    // Sent only to phones that announce `commentOriginCapability`; its command carries a `RemoteCommentOriginRequest`.
    case setCommentOrigin
    case markReady
    // Sent only to clients that advertise draftRegenerationCapability.
    case startDraftRegeneration, applyDraftRegeneration, discardDraftRegeneration
}

public struct RemoteAction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: RemoteActionKind
    public var token: String
    public var confirmationText: String?
    /// Button text when one card offers several actions of the same kind, such as one per suggestion.
    public var label: String?
    public init(id: String, kind: RemoteActionKind, token: String, confirmationText: String? = nil, label: String? = nil) {
        self.id = id; self.kind = kind; self.token = token; self.confirmationText = confirmationText; self.label = label
    }
}

public struct RemoteDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var body: String
    public var context: String?
    public var publicationWarnings: [String]?
    /// Other participants of the thread a reply draft answers; older Macs omit it.
    public var replyRecipients: [RemotePerson]?
    public init(id: Int, body: String, context: String? = nil, publicationWarnings: [String]? = nil,
                replyRecipients: [RemotePerson]? = nil) {
        self.id = id; self.body = body; self.context = context; self.publicationWarnings = publicationWarnings
        self.replyRecipients = replyRecipients
    }
}

/// A destination, optionally bound to one of the card's host-authorized actions.
public struct RemoteCardCTA: Codable, Equatable, Sendable {
    public var duplicatesCardTap: Bool { destination == .overview && actionID == nil }
    public enum Destination: String, Codable, Sendable {
        case overview, drafts, feedback, assistantRuns, setup, actions, discussions
        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value) ?? .overview
        }
    }
    public var title: String
    public var destination: Destination
    public var actionID: String?
    public init(title: String, destination: Destination, actionID: String? = nil) {
        self.title = title; self.destination = destination; self.actionID = actionID
    }
}

public struct RemoteCardChip: Codable, Equatable, Sendable {
    public var title: String
    public var symbol: String
    public init(title: String, symbol: String) { self.title = title; self.symbol = symbol }
}

/// The named people in a status line, plus the count of people omitted from the line.
public struct RemotePeopleMessage: Codable, Equatable, Sendable {
    public let prefix: String
    public let people: [RemotePerson]
    public let remainingCount: Int

    public init(prefix: String, people: [RemotePerson], remainingCount: Int) {
        self.prefix = prefix
        self.people = people
        self.remainingCount = remainingCount
    }
}

public struct RemoteCardText: Codable, Equatable, Sendable {
    public var author: String?
    /// Optional so older paired installations keep decoding snapshots.
    public var authorUsername: String?
    public var authorAvatarURL: URL?
    public var repository: String
    public var draftBadge: String?
    public var status: String?
    public var statusPeopleMessage: RemotePeopleMessage?
    /// Additive marker for active AI work; absent for deterministic reads and older hosts.
    public var statusSymbol: String?
    public var nextStep: String?
    public var working: Bool
    public var chips: [RemoteCardChip]
    public var secondaryCTA: RemoteCardCTA?
    /// Merge requirements, one per line; `status` keeps the joined sentence for older phones.
    public var requirements: [String]?
    public var requirementPeopleMessage: RemotePeopleMessage?
    /// When present, the first requirement is a thread resolution wait for these people.
    public var threadResolutionPeople: [RemotePerson]?
    /// The automation order behind `nextStep`, with the current step's index.
    public var steps: [String]?
    public var currentStep: Int?
    /// Unpublished drafts and who still has no published reply; older phones ignore it.
    public var pendingDrafts: String?
    public var pendingDraftsPeopleMessage: RemotePeopleMessage?
    public var approvalPeople: [RemoteApprovalPerson]?
    public var viewerApprovalID: Int?
    /// GitLab's reviewer assignments, independent of approval or discussion participation.
    public var assignedReviewerCount: Int?
    /// The paired Mac confirmed automatic approval of this head while findings were open.
    public var approvedWithOpenFindings: Bool?
    public init(author: String? = nil, repository: String, draftBadge: String? = nil,
                status: String? = nil, nextStep: String? = nil, working: Bool = false,
                chips: [RemoteCardChip] = [], secondaryCTA: RemoteCardCTA? = nil,
                authorUsername: String? = nil, authorAvatarURL: URL? = nil,
                requirements: [String]? = nil, steps: [String]? = nil, currentStep: Int? = nil,
                pendingDrafts: String? = nil, statusSymbol: String? = nil,
                approvalPeople: [RemoteApprovalPerson]? = nil, viewerApprovalID: Int? = nil,
                assignedReviewerCount: Int? = nil) {
        self.approvalPeople = approvalPeople; self.viewerApprovalID = viewerApprovalID
        self.assignedReviewerCount = assignedReviewerCount
        self.pendingDrafts = pendingDrafts
        self.requirements = requirements; self.steps = steps; self.currentStep = currentStep
        self.author = author; self.authorUsername = authorUsername; self.authorAvatarURL = authorAvatarURL
        self.repository = repository; self.draftBadge = draftBadge
        self.statusSymbol = statusSymbol
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

public struct RemoteApprovalProgress: Codable, Equatable, Sendable {
    public let completed: Int
    public let required: Int
    public let received: Int?
    public var requirementsSatisfied: Bool? = nil
    public init?(completed: Int, required: Int, received: Int? = nil, requirementsSatisfied: Bool? = nil) {
        guard required >= 0, completed >= 0, completed <= required,
              received.map({ $0 >= 0 }) ?? true else { return nil }
        self.completed = completed; self.required = required
        self.received = received
        self.requirementsSatisfied = requirementsSatisfied
    }
    private enum CodingKeys: String, CodingKey { case completed, required, received, requirementsSatisfied }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let completed = try values.decode(Int.self, forKey: .completed)
        let required = try values.decode(Int.self, forKey: .required)
        let received = try values.decodeIfPresent(Int.self, forKey: .received)
        guard let progress = Self(completed: completed, required: required, received: received) else {
            throw DecodingError.dataCorruptedError(forKey: .completed, in: values, debugDescription: "Invalid required approval progress")
        }
        self = progress
        self.requirementsSatisfied = try values.decodeIfPresent(Bool.self, forKey: .requirementsSatisfied)
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
    public var approvals: RemoteApprovalProgress?
    public var contextRevision: String?
    public init(id: String, title: String, project: String, url: URL?, head: String? = nil,
                detail: String = "", drafts: [RemoteDraft] = [], actions: [RemoteAction] = [],
                needsAttention: Bool? = nil, mergeRequestIID: Int? = nil, primaryCTA: RemoteCardCTA? = nil, presentation: RemoteCardText? = nil, dependencies: RemoteMRDependencies? = nil, approvals: RemoteApprovalProgress? = nil, contextRevision: String? = nil) {
        self.id = id; self.title = title; self.project = project; self.url = url; self.head = head
        self.detail = detail; self.drafts = drafts; self.actions = actions
        self.needsAttention = needsAttention; self.mergeRequestIID = mergeRequestIID; self.primaryCTA = primaryCTA; self.presentation = presentation; self.dependencies = dependencies
        self.approvals = approvals
        self.contextRevision = contextRevision
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
    public var automationPaused: Bool?
    public var lanes: [RemoteLane]
    public var draftRegeneration: RemoteDraftRegenerationControl?
    public init(hostSession: UUID, account: String, updatedAt: Date? = nil, partial: Bool = false, lanes: [RemoteLane],
                automationPaused: Bool? = nil, draftRegeneration: RemoteDraftRegenerationControl? = nil) {
        self.hostSession = hostSession; self.account = account; self.updatedAt = updatedAt
        self.partial = partial; self.lanes = lanes; self.automationPaused = automationPaused
        self.draftRegeneration = draftRegeneration
    }
    public var commandCards: [RemoteCard] { cards + (draftRegeneration.map { [$0.card] } ?? []) }
    public var cards: [RemoteCard] { lanes.flatMap(\.cards) }

    public var avatarThumbnailURLs: [URL] {
        let presentations = cards.compactMap(\.presentation)
        let authors = presentations.compactMap(\.authorAvatarURL)
        let approvers = presentations.flatMap { ($0.approvalPeople ?? []).compactMap(\.avatarURL) }
        let people = presentations.flatMap { presentation -> [RemotePerson] in
            let messages = [presentation.statusPeopleMessage, presentation.requirementPeopleMessage,
                            presentation.pendingDraftsPeopleMessage].compactMap { $0 }
            return messages.flatMap(\.people) + (presentation.threadResolutionPeople ?? [])
        }
        let recipients = cards.flatMap(\.drafts).flatMap { $0.replyRecipients ?? [] }
        return RemoteAvatarThumbnail.eligibleURLs(authors + approvers + (people + recipients).compactMap(\.avatarURL))
    }
}

public struct RemoteAvatarThumbnail: Codable, Equatable, Sendable {
    public static let maximumBytes = 4096
    // Leave room in the encrypted payload for base64 and JSON slash escaping.
    public static let batchSize = 8
    public let url: URL
    public let jpeg: Data

    public init(url: URL, jpeg: Data) {
        self.url = url
        self.jpeg = jpeg
    }

    static func eligibleURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { url in
            url.scheme?.lowercased() == "https" && url.absoluteString.utf8.count <= 1024 && seen.insert(url).inserted
        }
    }
}

public struct RemoteCommand: Codable, Equatable, Sendable {
    public var id: UUID
    public var hostSession: UUID
    public var account: String
    public var cardID: String
    public var actionID: String
    public var token: String
    /// Parameters for an action that takes them, such as `RemoteCommentOriginRequest`. The host validates them itself.
    public var argument: String?
    public var isFeedbackSuggestionDecision: Bool {
        actionID.hasPrefix("ignoreSuggestion:") || actionID.hasPrefix("restoreSuggestion:")
    }
    public var isCompletionAcknowledgement: Bool {
        cardID.hasPrefix("completion:") && actionID == "seen"
    }
    public var isDraftRegeneration: Bool { cardID == RemoteDraftRegenerationControl.cardID }
    public var receiptIdentity: Self {
        guard isDraftRegeneration, let argument else { return self }
        if argument.hasPrefix("sha256:"), argument.utf8.count == 71,
           argument.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) { return self }
        var receipt = self
        // Store additional user instructions in command receipts by digest.
        receipt.argument = "sha256:" + RemoteDraftRegenerationPage.token(Data(argument.utf8))
        return receipt
    }
    public init(id: UUID = UUID(), hostSession: UUID, account: String, cardID: String, actionID: String, token: String,
                argument: String? = nil) {
        self.id = id; self.hostSession = hostSession; self.account = account; self.cardID = cardID; self.actionID = actionID; self.token = token
        self.argument = argument
    }
}

public struct RemoteCommandResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, completed, changed, failed, uncertain, limit, partial, queued, inTrain, checked }
    public var id: UUID
    public var status: Status
    public init(id: UUID, status: Status) { self.id = id; self.status = status }
}

public struct RemoteMessage: Codable, Sendable {
    public static let mergeActionsCapability = "merge-actions-v1"
    public static let commentReviewCapability = "comment-review-v1"
    public static let detailsCapability = "mr-details-v1"
    public static let detailContextCapability = "detail-context-v1"
    public static let detailPreviewCapability = "detail-preview-v1"
    public static let detailOriginsCapability = "detail-origins-v1"
    public static let mrControlsCapability = "mr-controls-v1"
    public static let commentOriginCapability = "comment-origin-v1"
    public static let markReadyCapability = "mark-ready-v1"
    public static let draftRegenerationCapability = "draft-regeneration-v1"
    public static let boardAvatarsCapability = "board-avatars-v1"
    public static let detailAvatarsCapability = "detail-avatars-v1"
    public enum Kind: String, Codable, Sendable { case hello, snapshot, command, accepted, result, receipt, receiptResult = "receipt-result", unavailable, hostReady = "host-ready", detailRequest = "detail-request", details, cancelDetails = "cancel-details"
        case draftRegenerationRequest = "draft-regeneration-request", draftRegenerationPage = "draft-regeneration-page"
        case avatarThumbnails = "avatar-thumbnails"
    }
    public var type: Kind
    public var challenge: UUID?
    public var board: RemoteBoard?
    public var command: RemoteCommand?
    public var result: RemoteCommandResult?
    public var capabilities: [String]?
    public var detailRequest: RemoteDetailRequest?
    public var detailResponse: RemoteDetailResponse?
    public var detailOrigins: RemoteDetailOrigins?
    public var draftRegenerationRequest: RemoteDraftRegenerationPageRequest?
    public var draftRegenerationPage: RemoteDraftRegenerationPage?
    public var cachedAvatarURLs: [URL]?
    public var avatarThumbnails: [RemoteAvatarThumbnail]?
    /// True reads GitLab before answering. False reads only the host's current board.
    /// When omitted, initial connections and stale boards may cause a GitLab refresh.
    public var refresh: Bool?
    public init(type: Kind, challenge: UUID? = nil, board: RemoteBoard? = nil,
                command: RemoteCommand? = nil, result: RemoteCommandResult? = nil, capabilities: [String]? = nil,
                detailRequest: RemoteDetailRequest? = nil, detailResponse: RemoteDetailResponse? = nil,
                detailOrigins: RemoteDetailOrigins? = nil, refresh: Bool? = nil,
                draftRegenerationRequest: RemoteDraftRegenerationPageRequest? = nil,
                draftRegenerationPage: RemoteDraftRegenerationPage? = nil,
                cachedAvatarURLs: [URL]? = nil, avatarThumbnails: [RemoteAvatarThumbnail]? = nil) {
        self.type = type; self.challenge = challenge; self.board = board; self.command = command; self.result = result
        self.refresh = refresh
        self.capabilities = capabilities
        self.detailRequest = detailRequest; self.detailResponse = detailResponse
        self.detailOrigins = detailOrigins
        self.draftRegenerationRequest = draftRegenerationRequest; self.draftRegenerationPage = draftRegenerationPage
        self.cachedAvatarURLs = cachedAvatarURLs
        self.avatarThumbnails = avatarThumbnails
    }
}

extension RemoteBoard {
    public func forClient(supportsCommentReview: Bool, supportsMergeActions: Bool = false, supportsMRControls: Bool = false,
                          supportsCommentOrigins: Bool = false, supportsMarkReady: Bool = false,
                          supportsDraftRegeneration: Bool = false) -> Self {
        var compatible = self
        if !supportsDraftRegeneration { compatible.draftRegeneration = nil }
        for lane in compatible.lanes.indices {
            for card in compatible.lanes[lane].cards.indices {
                if !supportsMarkReady {
                    let removed = Set(compatible.lanes[lane].cards[card].actions.filter { $0.kind == .markReady }.map(\.id))
                    compatible.lanes[lane].cards[card].actions.removeAll { $0.kind == .markReady }
                    if let id = compatible.lanes[lane].cards[card].primaryCTA?.actionID, removed.contains(id) {
                        compatible.lanes[lane].cards[card].primaryCTA = nil
                    }
                    if let id = compatible.lanes[lane].cards[card].presentation?.secondaryCTA?.actionID, removed.contains(id) {
                        compatible.lanes[lane].cards[card].presentation?.secondaryCTA = nil
                    }
                }
                if !supportsCommentOrigins {
                    compatible.lanes[lane].cards[card].actions.removeAll { $0.kind == .setCommentOrigin }
                }
                if !supportsMRControls {
                    // Older phones cannot decode these kinds; one unknown value would reject the whole board.
                    compatible.lanes[lane].cards[card].actions.removeAll { RemoteActionKind.mrControls.contains($0.kind) }
                }
                if !supportsMergeActions {
                    compatible.lanes[lane].cards[card].actions.removeAll { [.merge, .enqueueMerge, .resolveThreads, .checkThreads].contains($0.kind) }
                }
                if !supportsCommentReview, compatible.lanes[lane].cards[card].drafts.isEmpty,
                   compatible.lanes[lane].cards[card].primaryCTA?.destination == .drafts {
                    compatible.lanes[lane].cards[card].primaryCTA = nil
                }
                if !supportsCommentReview {
                    compatible.lanes[lane].cards[card].actions.removeAll { $0.kind == .deleteDraft || $0.kind == .finishCommentReview }
                }
            }
        }
        return compatible
    }
}

public enum RemoteDigest {
    public static func token<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
