import Foundation
import Observation

public struct RemoteDetailRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let hostSession: UUID
    public let account: String
    public let cardID: String
    public let cardDigest: String
    public init(card: RemoteCard, board: RemoteBoard) throws {
        guard card.id.utf8.count <= 128, board.account.utf8.count <= 1_024 else { throw RemoteProtocolError.invalid }
        id = UUID(); hostSession = board.hostSession; account = board.account
        cardID = card.id; cardDigest = try RemoteDigest.token(card)
    }
    public func matches(_ board: RemoteBoard) -> Bool {
        isValid && hostSession == board.hostSession && account == board.account
            && board.cards.contains { $0.id == cardID && (try? RemoteDigest.token($0)) == cardDigest }
    }
    public var isValid: Bool { cardID.utf8.count <= 128 && account.utf8.count <= 1_024 && cardDigest.utf8.count == 64 }
}

public struct RemoteDetailField: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public let url: URL?
    public init(label: String, value: String, url: URL? = nil) { self.label = label; self.value = value; self.url = url }
}

public struct RemoteApprovalPerson: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case approved, previouslyApproved, commented, assigned }
    public let id: Int
    public var name: String
    public var username: String
    public let status: Status
    public let changedAt: Date?
    public init(id: Int, name: String, username: String, status: Status, changedAt: Date? = nil) {
        self.id = id; self.name = name; self.username = username; self.status = status; self.changedAt = changedAt
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
    public init(progress: RemoteApprovalProgress?, people: [RemoteApprovalPerson] = [], rules: [RemoteApprovalRule]? = nil,
                requirementsSatisfied: Bool? = nil, historyAvailable: Bool = false) {
        self.progress = progress; self.people = people; self.rules = rules
        self.requirementsSatisfied = requirementsSatisfied; self.historyAvailable = historyAvailable
    }
}

public struct RemoteDetailNote: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case ai, uncertain, human }
    public let id: String
    public var author: String?
    public var username: String?
    public var body: String
    public var location: String?
    public let createdAt: Date?
    public let url: URL?
    public var origin: Origin?
    public let authorID: Int?
    public init(id: String, author: String? = nil, username: String? = nil, body: String, location: String? = nil,
                createdAt: Date? = nil, url: URL? = nil, origin: Origin? = nil, authorID: Int? = nil) {
        self.id = id; self.author = author; self.username = username; self.body = body; self.location = location
        self.createdAt = createdAt; self.url = url; self.origin = origin
        self.authorID = authorID
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
    public let reply: Reply
    public let draftCount: Int
    public var feedback: Feedback?
    public var truncated = false
    public init(id: String, state: State, location: String? = nil, notes: [RemoteDetailNote], reply: Reply = .unavailable,
                draftCount: Int = 0, feedback: Feedback? = nil) {
        self.id = id; self.state = state; self.location = location; self.notes = notes; self.reply = reply; self.draftCount = draftCount
        self.feedback = feedback
    }

    public var origin: RemoteDetailNote.Origin? {
        guard !truncated else { return nil }
        var aggregate: RemoteDetailNote.Origin?
        for note in notes {
            guard let origin = note.origin else { return nil }
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
    public var feedback: [RemoteDetailField]
    public var activity: [RemoteDetailActivity]
    public var usage: [RemoteDetailField]?
    public var truncated: Bool
    public var discussionFingerprint: String?
    public var branches: RemoteDetailBranches?
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
    public init(request: RemoteDetailRequest, status: Status, details: RemoteMRDetails? = nil) {
        self.request = request; self.status = status; self.details = details
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
            details.metadata = list(details.metadata, 30).map { .init(label: text($0.label, 256), value: text($0.value, 4_000), url: $0.url) }
            details.feedback = list(details.feedback, 40).map { .init(label: text($0.label, 256), value: text($0.value, 4_000), url: $0.url) }
            details.policy = list(details.policy, 20).map { text($0, 2_000) }
            details.reasons = list(details.reasons, 20).map { text($0, 2_000) }
            details.usage = details.usage.map { fields in
                list(fields, 10).map { .init(label: text($0.label, 256), value: text($0.value, 4_000), url: $0.url) }
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
                    if original.notes.count > 30 { thread.truncated = true }
                    thread.notes = list(original.notes, 30).map { original in
                        var note = original
                        if note.body.count > 4_000 { thread.truncated = true }
                        note.body = text(note.body, 4_000)
                        return note
                    }
                    return thread
                }
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
            if var threads = details.threads, !threads.isEmpty {
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
            else if !details.policy.isEmpty { details.policy = Array(details.policy.prefix(details.policy.count / 2)) }
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
    private var deadline = Date.distantPast
    private var originRevisions: [String: UInt64] = [:]
    public init() {}
    public func begin(card: RemoteCard, board: RemoteBoard, now: Date = Date(), force: Bool = false) -> RemoteDetailRequest? {
        guard board.cards.contains(card), card.id.hasPrefix("mr:"),
              force || pending == nil || !isLoading(now: now),
              let request = try? RemoteDetailRequest(card: card, board: board) else { return nil }
        pending = request; openRequest = request; deadline = now.addingTimeInterval(45); failure = nil
        originRevisions = [:]
        return request
    }
    public func receive(_ value: RemoteDetailResponse, board: RemoteBoard) {
        guard value.request == pending, value.request.matches(board) else { return }
        pending = nil
        if value.status == .current, value.details != nil { response = value; failure = nil }
        else {
            openRequest = nil
            failure = value.status
            if value.status == .changed { response = nil }
        }
    }
    public func update(board: RemoteBoard) {
        if let openRequest, !openRequest.matches(board) { self.openRequest = nil }
        if let response, !response.request.matches(board) { self.response = nil }
        if let pending, !pending.matches(board) { self.pending = nil; failure = .changed }
    }
    public func disconnect() { pending = nil; openRequest = nil; originRevisions = [:] }

    @discardableResult public func receiveOrigins(_ update: RemoteDetailOrigins, board: RemoteBoard) -> Bool {
        guard pending == nil, update.request == openRequest, update.request.matches(board),
              var response, response.request == update.request, response.status == .current,
              var details = response.details, let threads = details.threads,
              !update.changes.isEmpty, update.changes.count <= 100,
              update.changes.allSatisfy({ $0.revision > 0 }),
              Set(update.changes.map(\.identity)).count == update.changes.count else { return false }
        var edits: [(thread: Int, note: Int, change: RemoteDetailOriginChange)] = []
        for change in update.changes {
            let matchingThreads = threads.indices.filter { threads[$0].id == change.threadID }
            guard matchingThreads.count == 1, let thread = matchingThreads.first else { return false }
            let matchingNotes = threads[thread].notes.indices.filter { threads[thread].notes[$0].id == change.noteID }
            guard matchingNotes.count == 1, let note = matchingNotes.first,
                  threads[thread].notes[note].originIdentity(in: change.threadID) == change.identity else { return false }
            if change.revision > originRevisions[change.identity, default: 0] { edits.append((thread, note, change)) }
        }
        guard !edits.isEmpty else { return false }
        for edit in edits {
            details.threads?[edit.thread].notes[edit.note].origin = edit.change.origin
            originRevisions[edit.change.identity] = edit.change.revision
        }
        response.details = details
        self.response = response
        return true
    }
    public func isLoading(now: Date = Date()) -> Bool { pending != nil && now < deadline }
    public func hasTimedOut(now: Date = Date()) -> Bool { pending != nil && now >= deadline }
    public func details(for card: RemoteCard, board: RemoteBoard) -> RemoteMRDetails? {
        guard let response, card.id == response.request.cardID, response.request.matches(board), board.cards.contains(card) else { return nil }
        return response.details
    }
}
