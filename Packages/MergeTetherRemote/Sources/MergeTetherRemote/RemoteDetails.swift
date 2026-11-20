import Foundation
import Observation

public struct RemoteDetailRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let hostSession: UUID
    public let account: String
    public let cardID: String
    public let cardDigest: String
    public let contentDigest: String?
    public let cachedOnly: Bool?
    public init(card: RemoteCard, board: RemoteBoard, presentationIndependent: Bool = false, cachedOnly: Bool? = nil) throws {
        guard card.id.utf8.count <= 128, board.account.utf8.count <= 1_024 else { throw RemoteProtocolError.invalid }
        id = UUID(); hostSession = board.hostSession; account = board.account
        cardID = card.id; cardDigest = try RemoteDigest.token(card)
        contentDigest = presentationIndependent ? card.detailContextDigest : nil
        self.cachedOnly = cachedOnly
    }
    public func matches(_ board: RemoteBoard) -> Bool {
        isValid && hostSession == board.hostSession && account == board.account
            && board.cards.contains { card in
                guard card.id == cardID else { return false }
                if let contentDigest { return card.detailContextDigest == contentDigest }
                return Self.digests(card).contains(cardDigest)
            }
    }
    /// Older phones drop fields they do not know before hashing the card they open:
    /// action links and discussion destinations, the pending-drafts line and reply recipients,
    /// and before those the author identity. Phones may also omit the automatic approval note.
    static func digests(_ card: RemoteCard) -> Set<String> {
        var withoutPeopleMessages = card
        withoutPeopleMessages.presentation?.statusPeopleMessage = nil
        withoutPeopleMessages.presentation?.requirementPeopleMessage = nil
        withoutPeopleMessages.presentation?.pendingDraftsPeopleMessage = nil
        var withoutActions = withoutPeopleMessages
        withoutActions.primaryCTA?.actionID = nil
        withoutActions.presentation?.secondaryCTA?.actionID = nil
        var withoutDrafts = withoutActions
        withoutDrafts.presentation?.pendingDrafts = nil
        for index in withoutDrafts.drafts.indices { withoutDrafts.drafts[index].replyRecipients = nil }
        var legacy = withoutDrafts
        legacy.presentation?.authorUsername = nil
        legacy.presentation?.authorAvatarURL = nil
        let currentVersions = [card, withoutPeopleMessages, withoutActions, withoutDrafts, legacy]
        let versions = currentVersions + currentVersions.map { version in
            var version = version
            version.presentation?.approvalPeople = nil
            version.presentation?.viewerApprovalID = nil
            return version
        }
        let olderDestinations = versions.map { version in
            var version = version
            if version.primaryCTA?.destination == .discussions { version.primaryCTA?.destination = .overview }
            if version.presentation?.secondaryCTA?.destination == .discussions { version.presentation?.secondaryCTA?.destination = .overview }
            return version
        }
        let supported = versions + olderDestinations
        let withoutApprovalNote = supported.map { version in
            var version = version
            version.presentation?.approvedWithOpenFindings = nil
            return version
        }
        return Set((supported + withoutApprovalNote).compactMap { try? RemoteDigest.token($0) })
    }
    public var isValid: Bool {
        cardID.utf8.count <= 128 && account.utf8.count <= 1_024 && cardDigest.utf8.count == 64
            && (contentDigest == nil || contentDigest?.utf8.count == 64)
    }
}

/// A GitLab person; optional so older paired installations keep decoding details.
public struct RemotePerson: Codable, Equatable, Sendable {
    public var name: String?
    public var username: String?
    public let avatarURL: URL?
    public init(name: String?, username: String?, avatarURL: URL? = nil) {
        self.name = name; self.username = username; self.avatarURL = avatarURL
    }

    public func profileURL(on source: URL?) -> URL? {
        let handle = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" })
        guard handle.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]*/) != nil, !handle.hasSuffix("."),
              let source, var parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.path = "/" + handle
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func clipped(_ text: (String, Int) -> String) -> Self {
        .init(name: name.map { text($0, 512) }, username: username.map { text($0, 256) }, avatarURL: avatarURL)
    }
}

public struct RemoteDetailField: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public let url: URL?
    /// When set, the label names this person and the phone shows them with an avatar.
    public var person: RemotePerson?
    public var peopleMessage: RemotePeopleMessage?
    public var supportingText: String?
    public init(label: String, value: String, url: URL? = nil, person: RemotePerson? = nil,
                peopleMessage: RemotePeopleMessage? = nil, supportingText: String? = nil) {
        self.label = label; self.value = value; self.url = url; self.person = person
        self.peopleMessage = peopleMessage; self.supportingText = supportingText
    }
}

public struct RemoteApprovalPerson: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case approved, previouslyApproved, commented, assigned }
    public let id: Int
    public var name: String
    public var username: String
    public let status: Status
    public let changedAt: Date?
    public let avatarURL: URL?
    public init(id: Int, name: String, username: String, status: Status, changedAt: Date? = nil, avatarURL: URL? = nil) {
        self.id = id; self.name = name; self.username = username; self.status = status; self.changedAt = changedAt
        self.avatarURL = avatarURL
    }
}

public struct RemoteApprovalRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let required: Int
    public let approved: Bool?
    public var approvedBy: [String]
    public init(id: String, name: String, required: Int, approved: Bool?, approvedBy: [String] = []) {
        self.id = id; self.name = name; self.required = required; self.approved = approved; self.approvedBy = approvedBy
    }
}

public struct RemoteApprovalDetails: Codable, Equatable, Sendable {
    public var progress: RemoteApprovalProgress?
    public var people: [RemoteApprovalPerson]
    public var rules: [RemoteApprovalRule]?
    public let requirementsSatisfied: Bool?
    public let historyAvailable: Bool
    public var truncated = false
    public var viewerApprovalID: Int?
    public var viewerApproval: RemoteApprovalPerson? {
        people.first { $0.id == viewerApprovalID && [.approved, .previouslyApproved].contains($0.status) }
    }
    public var orderedPeople: [RemoteApprovalPerson] {
        guard let viewer = viewerApproval else { return people }
        return people.filter { $0.id == viewer.id } + people.filter { $0.id != viewer.id }
    }
    public init(progress: RemoteApprovalProgress?, people: [RemoteApprovalPerson] = [], rules: [RemoteApprovalRule]? = nil,
                requirementsSatisfied: Bool? = nil, historyAvailable: Bool = false, viewerApprovalID: Int? = nil) {
        self.progress = progress; self.people = people; self.rules = rules
        self.requirementsSatisfied = requirementsSatisfied; self.historyAvailable = historyAvailable
        self.viewerApprovalID = viewerApprovalID
    }
}

public struct RemoteDetailNote: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case ai, uncertain, human }
    public enum AuthorKind: String, Codable, Sendable { case regular, automation }
    public let id: String
    public var author: String?
    public var username: String?
    public var body: String
    public var location: String?
    public let createdAt: Date?
    public let url: URL?
    public var origin: Origin?
    /// Bot identity is a fixed display classification; the raw text verdict survives removal of that identity.
    public var displayOrigin: Origin? { authorKind == .automation ? .ai : origin }
    public let authorID: Int?
    public var authorKind: AuthorKind?
    public let avatarURL: URL?
    /// `true` when the user set `origin` by hand rather than an assessment.
    public var originManual: Bool?
    /// App-only Markdown from MergeTether's agent. Additive: older phones ignore it.
    public var extraContext: String?
    /// When true, the Extra context belongs to a proposed solution.
    public var proposedSolution: Bool?
    public init(id: String, author: String? = nil, username: String? = nil, body: String, location: String? = nil,
                createdAt: Date? = nil, url: URL? = nil, origin: Origin? = nil, authorID: Int? = nil,
                authorKind: AuthorKind? = nil, avatarURL: URL? = nil, originManual: Bool? = nil, extraContext: String? = nil,
                proposedSolution: Bool? = nil) {
        self.originManual = originManual
        self.id = id; self.author = author; self.username = username; self.body = body; self.location = location
        self.createdAt = createdAt; self.url = url; self.origin = origin
        self.authorID = authorID
        self.authorKind = authorKind
        self.avatarURL = avatarURL
        self.extraContext = extraContext
        self.proposedSolution = proposedSolution
    }
}

public struct RemoteDetailThread: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case open, resolved, general }
    public enum Reply: String, Codable, Sendable { case none, published, earlier, unknown, unavailable }
    public enum Feedback: String, Codable, Sendable {
        case addressed, pending, needsVerification, informational, ignored, partlyIgnored, notApplicable
    }
    public let id: String
    public let state: State
    public var location: String?
    public var notes: [RemoteDetailNote]
    public var reply: Reply
    public let draftCount: Int
    /// Links to the current board's draft bodies; older hosts omit this field.
    public var draftIDs: [Int]?
    public var feedback: Feedback?
    public var showsPublishedReply: Bool { draftCount == 0 && reply == .published }
    public var truncated = false
    public init(id: String, state: State, location: String? = nil, notes: [RemoteDetailNote], reply: Reply = .unavailable,
                draftCount: Int = 0, feedback: Feedback? = nil, draftIDs: [Int]? = nil) {
        self.id = id; self.state = state; self.location = location; self.notes = notes; self.reply = reply; self.draftCount = draftCount
        self.feedback = feedback
        self.draftIDs = draftIDs
    }

    public var origin: RemoteDetailNote.Origin? {
        guard !truncated else { return nil }
        var aggregate: RemoteDetailNote.Origin?
        for note in notes {
            guard let origin = note.displayOrigin else { return nil }
            if let previous = aggregate, previous != origin {
                guard previous != .human, origin != .human else { return nil }
                aggregate = .uncertain
            } else { aggregate = origin }
        }
        return aggregate
    }
}

public struct RemoteDetailBranches: Codable, Equatable, Sendable {
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

/// This MR's saved automation state and what decides it, as the Mac's automation panel shows it. Read-only.
public struct RemoteAutomationStatus: Codable, Equatable, Sendable {
    public var active: Bool
    /// Localized on the Mac, for example "Automation enabled · Decided by: Repository".
    public var summary: String
    public init(active: Bool, summary: String) { self.active = active; self.summary = summary }
}

public struct RemoteDetailActivity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var status: String
    public var summary: String?
    public let createdAt: Date
    public var head: String?
    public init(id: String, title: String, status: String, summary: String? = nil, createdAt: Date, head: String? = nil) {
        self.id = id; self.title = title; self.status = status; self.summary = summary; self.createdAt = createdAt; self.head = head
    }
}

public struct RemoteMRDetails: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public var metadata: [RemoteDetailField]
    public var description: String?
    public var approvals: RemoteApprovalDetails?
    public var threads: [RemoteDetailThread]?
    public var reasons: [String]
    public var policy: [String]
    /// The saved rules within `policy`; newer phones list them with reference data, apart from holds.
    public var rules: [String]?
    public var feedback: [RemoteDetailField]
    public var activity: [RemoteDetailActivity]
    public var usage: [RemoteDetailField]?
    public var truncated: Bool
    public var discussionFingerprint: String?
    public var activeDiscussionFingerprint: String?
    public var branches: RemoteDetailBranches?
    /// A comment-origin change waiting before it lets automation publish drafts.
    public var originResume: RemoteOriginResume?
    /// App-only Markdown from MergeTether's agent for pending board drafts, keyed by draft ID. Additive.
    public var draftContexts: [String: String]?
    /// Drafts whose Extra context describes a proposed solution.
    public var proposedSolutionDraftIDs: [Int]?
    /// Additive; older hosts send none and older phones ignore it.
    public var automation: RemoteAutomationStatus?

    public var avatarThumbnailURLs: [URL] {
        let fields = metadata + feedback + (usage ?? [])
        let people = fields.compactMap(\.person) + fields.flatMap { $0.peopleMessage?.people ?? [] }
        let reviewers = (approvals?.people ?? []).compactMap(\.avatarURL)
        let commenters = (threads ?? []).flatMap(\.notes).compactMap(\.avatarURL)
        return RemoteAvatarThumbnail.eligibleURLs(people.compactMap(\.avatarURL) + reviewers + commenters)
    }

    public init(checkedAt: Date, metadata: [RemoteDetailField] = [], description: String? = nil,
                approvals: RemoteApprovalDetails? = nil, threads: [RemoteDetailThread]? = nil,
                reasons: [String] = [], policy: [String] = [], feedback: [RemoteDetailField] = [],
                activity: [RemoteDetailActivity] = [], usage: [RemoteDetailField]? = nil, truncated: Bool = false,
                branches: RemoteDetailBranches? = nil) {
        self.checkedAt = checkedAt; self.metadata = metadata; self.description = description; self.approvals = approvals
        self.threads = threads; self.reasons = reasons; self.policy = policy; self.feedback = feedback
        self.activity = activity; self.usage = usage; self.truncated = truncated
        self.branches = branches
    }
}

public struct RemoteDetailResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case current, changed, unavailable }
    public let request: RemoteDetailRequest
    public var status: Status
    public var details: RemoteMRDetails?
    /// A display-only response while the same request's GitLab read continues.
    public let isPreview: Bool?
    var isDisplayOnly: Bool { isPreview == true || request.cachedOnly == true }
    public init(request: RemoteDetailRequest, status: Status, details: RemoteMRDetails? = nil, isPreview: Bool? = nil) {
        self.request = request; self.status = status; self.details = details; self.isPreview = isPreview
    }

    /// The encrypted message budget includes its envelope and JSON escaping, not just body characters.
    public func bounded() -> Self {
        var result = self
        if var details = result.details {
            var clipped = details.truncated
            func text(_ value: String, _ maximum: Int) -> String {
                guard value.count > maximum else { return value }
                clipped = true
                return String(value.prefix(maximum))
            }
            func list<T>(_ value: [T], _ maximum: Int) -> [T] {
                if value.count > maximum { clipped = true }
                return Array(value.prefix(maximum))
            }
            details.description = details.description.map { text($0, 16_000) }
            if let branches = details.branches {
                details.branches = .init(source: text(branches.source, 4_000), target: text(branches.target, 4_000))
            }
            details.metadata = list(details.metadata, 30).map { .init(label: text($0.label, 256), value: text($0.value, 4_000), url: $0.url,
                                                                     person: $0.person?.clipped(text)) }
            details.feedback = list(details.feedback, 40).map { field in
                let message = field.peopleMessage.map {
                    RemotePeopleMessage(prefix: text($0.prefix, 512), people: list($0.people, 2).map { $0.clipped(text) },
                                        remainingCount: $0.remainingCount)
                }
                return .init(label: text(field.label, 256), value: text(field.value, 4_000), url: field.url,
                             person: field.person?.clipped(text), peopleMessage: message,
                             supportingText: field.supportingText.map { text($0, 4_000) })
            }
            details.policy = list(details.policy, 20).map { text($0, 2_000) }
            details.rules = details.rules.map { list($0, 20).map { text($0, 2_000) } }
            details.automation = details.automation.map { .init(active: $0.active, summary: text($0.summary, 512)) }
            details.reasons = list(details.reasons, 20).map { text($0, 2_000) }
            details.usage = details.usage.map { fields in
                list(fields, 10).map { .init(label: text($0.label, 256), value: text($0.value, 4_000), url: $0.url,
                                             person: $0.person?.clipped(text)) }
            }
            if var approvals = details.approvals {
                if approvals.people.count > 100 || (approvals.rules?.count ?? 0) > 100 { approvals.truncated = true }
                approvals.people = list(approvals.people, 100).map { original in
                    if original.name.count > 512 || original.username.count > 256 { approvals.truncated = true }
                    var person = original; person.name = text(person.name, 512); person.username = text(person.username, 256)
                    return person
                }
                approvals.rules = approvals.rules.map { rules in
                    list(rules, 100).map { original in
                        var rule = original; rule.name = text(rule.name, 512)
                        if original.name.count > 512 || rule.approvedBy.count > 100 || rule.approvedBy.contains(where: { $0.count > 256 }) {
                            approvals.truncated = true
                        }
                        rule.approvedBy = list(rule.approvedBy, 100).map { text($0, 256) }
                        return rule
                    }
                }
                details.approvals = approvals
            }
            details.threads = details.threads.map { threads in
                list(threads, 100).map { original in
                    var thread = original
                    thread.draftIDs = thread.draftIDs.map { list($0, 100) }
                    if original.notes.count > 30 { thread.truncated = true }
                    thread.notes = list(original.notes, 30).map { original in
                        var note = original
                        if note.body.count > 4_000 { thread.truncated = true }
                        note.body = text(note.body, 4_000)
                        note.extraContext = note.extraContext.map { text($0, 4_000) }
                        if note.extraContext == nil { note.proposedSolution = nil }
                        return note
                    }
                    return thread
                }
            }
            details.draftContexts = details.draftContexts.map { contexts in
                if contexts.count > 100 { clipped = true }
                return Dictionary(uniqueKeysWithValues: contexts.sorted { $0.key < $1.key }.prefix(100)
                    .filter { $0.key.utf8.count <= 32 }.map { ($0.key, text($0.value, 4_000)) })
            }
            details.proposedSolutionDraftIDs = details.proposedSolutionDraftIDs.flatMap { ids in
                let retained = list(ids, 100).filter { details.draftContexts?[String($0)] != nil }
                return retained.isEmpty ? nil : retained
            }
            details.activity = list(details.activity, 30).map { original in
                var activity = original
                activity.summary = activity.summary.map { text($0, 4_000) }
                return activity
            }
            details.truncated = clipped
            result.details = details
        }
        func size() -> Int { (try? JSONEncoder().encode(RemoteMessage(type: .details, detailResponse: result)).count) ?? Int.max }
        guard size() > RemoteCipher.maximumPayloadBytes else { return result }
        result.details?.truncated = true
        while size() > RemoteCipher.maximumPayloadBytes, var details = result.details {
            // Optional explanations go first: they are shown on demand and the comments stay readable without them.
            if details.draftContexts?.isEmpty == false {
                details.draftContexts = nil
                details.proposedSolutionDraftIDs = nil
            }
            else if details.threads?.contains(where: { $0.notes.contains { $0.extraContext != nil } }) == true {
                details.threads = details.threads?.map { thread in
                    var thread = thread
                    for index in thread.notes.indices {
                        thread.notes[index].extraContext = nil
                        thread.notes[index].proposedSolution = nil
                    }
                    return thread
                }
            }
            else if var threads = details.threads, !threads.isEmpty {
                if threads.count > 1 { threads = Array(threads.prefix(threads.count / 2)) }
                else if threads[0].notes.count > 1 {
                    threads[0].notes = Array(threads[0].notes.prefix(threads[0].notes.count / 2)); threads[0].truncated = true
                } else if (threads[0].notes.first?.body.count ?? 0) > 1 {
                    threads[0].notes[0].body = String(threads[0].notes[0].body.prefix(threads[0].notes[0].body.count / 2))
                    threads[0].truncated = true
                } else { threads = [] }
                details.threads = threads
            }
            else if !details.activity.isEmpty { details.activity = Array(details.activity.prefix(details.activity.count / 2)) }
            else if !(details.approvals?.rules?.isEmpty ?? true) {
                if let rules = details.approvals?.rules { details.approvals?.rules = Array(rules.prefix(rules.count / 2)) }
                details.approvals?.truncated = true
            }
            else if !(details.approvals?.people.isEmpty ?? true) {
                if let people = details.approvals?.people { details.approvals?.people = Array(people.prefix(people.count / 2)) }
                details.approvals?.truncated = true
            }
            else if let text = details.description, !text.isEmpty { details.description = String(text.prefix(text.count / 2)) }
            else if !details.feedback.isEmpty { details.feedback = Array(details.feedback.prefix(details.feedback.count / 2)) }
            else if !details.policy.isEmpty {
                details.policy = Array(details.policy.prefix(details.policy.count / 2))
                details.rules = details.rules?.filter(details.policy.contains)
            }
            else if !details.reasons.isEmpty { details.reasons = Array(details.reasons.prefix(details.reasons.count / 2)) }
            else if let usage = details.usage, !usage.isEmpty { details.usage = Array(usage.prefix(usage.count / 2)) }
            else if !details.metadata.isEmpty { details.metadata = Array(details.metadata.prefix(details.metadata.count / 2)) }
            else { result.status = .unavailable; result.details = nil; break }
            result.details = details
        }
        return result
    }
}

@MainActor @Observable public final class RemoteDetailState {
    public private(set) var pending: RemoteDetailRequest?
    public private(set) var openRequest: RemoteDetailRequest?
    public private(set) var response: RemoteDetailResponse?
    public private(set) var failure: RemoteDetailResponse.Status?
    private var displayCache: [String: RemoteDetailResponse] = [:]
    private var deadline = Date.distantPast
    private var originRevisions: [String: UInt64] = [:]
    private var authorKindRevisions: [String: UInt64] = [:]
    public init() {}
    public func begin(card: RemoteCard, board: RemoteBoard, now: Date = Date(), force: Bool = false,
                      presentationIndependent: Bool = true, cachedOnly: Bool? = nil) -> RemoteDetailRequest? {
        guard board.cards.contains(card), card.id.hasPrefix("mr:"),
              force || pending == nil || !isLoading(now: now),
              let request = try? RemoteDetailRequest(card: card, board: board, presentationIndependent: presentationIndependent,
                                                     cachedOnly: cachedOnly) else { return nil }
        pending = request; openRequest = request; deadline = now.addingTimeInterval(45); failure = nil
        originRevisions = [:]
        authorKindRevisions = [:]
        return request
    }
    public func receive(_ value: RemoteDetailResponse, board: RemoteBoard) {
        guard value.request == pending, value.request.matches(board) else { return }
        if value.isPreview == true {
            if value.status == .current, value.details != nil { cacheForDisplay(value) }
            return
        }
        pending = nil
        if value.status == .current, value.details != nil {
            if !value.isDisplayOnly { response = value }
            failure = nil
            cacheForDisplay(value)
        }
        else {
            openRequest = nil
            failure = value.status
            if value.status == .changed { response = nil }
        }
    }
    public func update(board: RemoteBoard) {
        if displayCache.values.contains(where: { $0.request.hostSession != board.hostSession || $0.request.account != board.account }) {
            displayCache.removeAll()
        }
        if let openRequest, !openRequest.matches(board) { self.openRequest = nil }
        if let response, !response.request.matches(board) { self.response = nil }
        if let pending, !pending.matches(board) { self.pending = nil; failure = .changed }
    }
    public func disconnect() { pending = nil; openRequest = nil; originRevisions = [:]; authorKindRevisions = [:] }
    public func prepareToReload() { disconnect(); failure = nil }
    public func reset() { prepareToReload(); response = nil; displayCache.removeAll() }

    @discardableResult public func receiveOrigins(_ update: RemoteDetailOrigins, board: RemoteBoard) -> Bool {
        let authors = update.authorKinds ?? []
        guard pending == nil, update.request == openRequest, update.request.matches(board),
              var response, response.request == update.request, response.status == .current,
              var details = response.details, let threads = details.threads,
              !update.changes.isEmpty || !authors.isEmpty, update.changes.count + authors.count <= 100,
              update.changes.allSatisfy({ $0.revision > 0 }),
              authors.allSatisfy({ $0.revision > 0 }),
              Set(update.changes.map(\.identity)).count == update.changes.count,
              Set(authors.map(\.identity)).count == authors.count else { return false }
        var edits: [(thread: Int, note: Int, change: RemoteDetailOriginChange)] = []
        var authorEdits: [(thread: Int, note: Int, change: RemoteDetailAuthorKindChange)] = []
        for change in update.changes {
            let matchingThreads = threads.indices.filter { threads[$0].id == change.threadID }
            guard matchingThreads.count == 1, let thread = matchingThreads.first else { return false }
            let matchingNotes = threads[thread].notes.indices.filter { threads[thread].notes[$0].id == change.noteID }
            guard matchingNotes.count == 1, let note = matchingNotes.first,
                  threads[thread].notes[note].originIdentity(in: change.threadID) == change.identity else { return false }
            if change.revision > originRevisions[change.identity, default: 0] { edits.append((thread, note, change)) }
        }
        for change in authors {
            let matchingThreads = threads.indices.filter { threads[$0].id == change.threadID }
            guard matchingThreads.count == 1, let thread = matchingThreads.first else { return false }
            let matchingNotes = threads[thread].notes.indices.filter { threads[thread].notes[$0].id == change.noteID }
            guard matchingNotes.count == 1, let note = matchingNotes.first,
                  threads[thread].notes[note].originIdentity(in: change.threadID) == change.identity else { return false }
            if change.revision > authorKindRevisions[change.identity, default: 0] { authorEdits.append((thread, note, change)) }
        }
        guard !edits.isEmpty || !authorEdits.isEmpty else { return false }
        for edit in edits {
            details.threads?[edit.thread].notes[edit.note].origin = edit.change.origin
            originRevisions[edit.change.identity] = edit.change.revision
        }
        for edit in authorEdits {
            details.threads?[edit.thread].notes[edit.note].authorKind = edit.change.authorKind
            authorKindRevisions[edit.change.identity] = edit.change.revision
        }
        response.details = details
        self.response = response
        cacheForDisplay(response)
        return true
    }
    public func isLoading(now: Date = Date()) -> Bool { pending != nil && now < deadline }
    public func hasTimedOut(now: Date = Date()) -> Bool { pending != nil && now >= deadline }
    public func details(for card: RemoteCard, board: RemoteBoard) -> RemoteMRDetails? {
        guard let response, card.id == response.request.cardID, response.request.matches(board), board.cards.contains(card) else { return nil }
        return response.details
    }

    public func displayedDetails(for card: RemoteCard, board: RemoteBoard) -> RemoteMRDetails? {
        guard let cached = displayCache[card.id],
              cached.request.hostSession == board.hostSession, cached.request.account == board.account,
              var details = cached.details else { return nil }
        if (details.draftContexts != nil || details.originResume != nil), !cached.request.matches(board) {
            details.draftContexts = nil
            details.proposedSolutionDraftIDs = nil
            details.originResume = nil
        }
        return details
    }

    private func cacheForDisplay(_ value: RemoteDetailResponse) {
        guard var details = value.details else { return }
        let id = value.request.cardID
        if let cached = displayCache[id], let previous = cached.details,
           cached.request.hostSession == value.request.hostSession, cached.request.account == value.request.account {
            let sameContent = (value.request.contentDigest ?? value.request.cardDigest)
                == (cached.request.contentDigest ?? cached.request.cardDigest)
            // Keep richer sections through a partial host preview or an optional GitLab read failure.
            if value.isDisplayOnly, !cached.isDisplayOnly, sameContent, details.checkedAt <= previous.checkedAt {
                return
            }
            if details.threads == nil {
                details.threads = previous.threads
                details.discussionFingerprint = previous.discussionFingerprint
                details.activeDiscussionFingerprint = previous.activeDiscussionFingerprint
                if sameContent, details.draftContexts == nil {
                    details.draftContexts = previous.draftContexts
                    details.proposedSolutionDraftIDs = previous.proposedSolutionDraftIDs
                }
            }
            details.usage = details.usage ?? previous.usage
            if var approvals = details.approvals {
                approvals.progress = approvals.progress ?? previous.approvals?.progress
                approvals.rules = approvals.rules ?? previous.approvals?.rules
                details.approvals = approvals
            } else { details.approvals = previous.approvals }
        }
        var cached = value
        cached.details = details
        displayCache[id] = cached
        if displayCache.count > 16, let oldest = displayCache.keys.filter({ $0 != id }).min(by: {
            (displayCache[$0]?.details?.checkedAt ?? .distantPast) < (displayCache[$1]?.details?.checkedAt ?? .distantPast)
        }) {
            displayCache.removeValue(forKey: oldest)
        }
    }
}
