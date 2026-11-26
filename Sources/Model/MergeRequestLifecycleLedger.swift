import Foundation

/// Durable membership and observed lifecycle changes, independent of automation permission.
struct MergeRequestLifecycleLedger: Codable, Sendable {
    struct Transition: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case merged, closed, ready, draft }
        let id: UUID
        let target: MRAutomationScope.Target
        let kind: Kind
        let title: String
        let url: URL
        let observedAt: Date
    }

    struct CompletionReceipt: Codable, Identifiable, Sendable {
        let id: UUID
        let target: MRAutomationScope.Target
        let kind: Transition.Kind
        let title: String
        let url: URL
        let observedAt: Date
        let author: Todo.Author?
    }

    private struct Entry: Codable, Sendable {
        var request: GitLabMergeRequest
        var observedAt: Date
        var acknowledgedTerminalState: GitLabMergeRequestState?
        var terminalObservedAt: Date?
        var terminalReceiptRecorded: Bool?
    }
    private var entries: [MRAutomationScope.Target: Entry] = [:]
    private var pendingTransitions: [Transition] = []
    private var completions: [MRAutomationScope.Target: CompletionReceipt] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case entries, pendingTransitions, completions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([MRAutomationScope.Target: Entry].self, forKey: .entries) ?? [:]
        pendingTransitions = try values.decodeIfPresent([Transition].self, forKey: .pendingTransitions) ?? []
        completions = try values.decodeIfPresent([MRAutomationScope.Target: CompletionReceipt].self, forKey: .completions) ?? [:]
    }

    func unreadCompletions(host: String, username: String, showMerged: Bool, showClosed: Bool) -> [CompletionReceipt] {
        completions.values.filter {
            $0.target.host == host && $0.target.username == username
                && (($0.kind == .merged && showMerged) || ($0.kind == .closed && showClosed))
        }.sorted {
            $0.observedAt == $1.observedAt ? $0.id.uuidString < $1.id.uuidString : $0.observedAt > $1.observedAt
        }
    }

    @discardableResult
    mutating func acknowledgeCompletion(id: UUID, host: String, username: String) -> Bool {
        guard let receipt = completions.values.first(where: {
            $0.id == id && $0.target.host == host && $0.target.username == username
        }) else { return false }
        completions.removeValue(forKey: receipt.target)
        if entries[receipt.target]?.request.state.rawValue == receipt.kind.rawValue {
            entries[receipt.target]?.terminalReceiptRecorded = true
            suppressFinished(receipt.target)
        }
        return true
    }

    mutating func suppressFinished(_ target: MRAutomationScope.Target) {
        guard let entry = entries[target], Self.isFinished(entry.request) else { return }
        entries[target]?.acknowledgedTerminalState = entry.request.state
    }

    mutating func prepareFinishedRemoval(host: String? = nil, username: String? = nil) {
        for target in Set(entries.keys) where (host == nil || target.host == host)
            && (username == nil || target.username == username) && !isSuppressed(target) {
            guard let entry = entries[target], Self.isFinished(entry.request) else { continue }
            retainCompletion(entry.request, for: target, id: UUID(), observedAt: entry.terminalObservedAt ?? entry.observedAt,
                replacing: false)
            suppressFinished(target)
        }
    }

    func completionID(for target: MRAutomationScope.Target) -> UUID? { completions[target]?.id }

    func request(for target: MRAutomationScope.Target) -> GitLabMergeRequest? { entries[target]?.request }

    func targets(host: String, username: String) -> Set<MRAutomationScope.Target> {
        Set(entries.keys.filter { $0.host == host && $0.username == username })
    }

    func retainedRequests(host: String, username: String) -> [GitLabMergeRequest] {
        targets(host: host, username: username).filter { !isSuppressed($0) }
            .sorted { ($0.projectID, $0.iid ?? 0) < ($1.projectID, $1.iid ?? 0) }
            .compactMap { entries[$0]?.request }
    }

    func isSuppressed(_ target: MRAutomationScope.Target) -> Bool {
        guard let entry = entries[target], Self.isFinished(entry.request) else { return false }
        return entry.acknowledgedTerminalState == entry.request.state
    }

    mutating func acknowledgeFinished(_ target: MRAutomationScope.Target) {
        guard let entry = entries[target], Self.isFinished(entry.request) else { return }
        if completions[target]?.kind.rawValue == entry.request.state.rawValue { completions.removeValue(forKey: target) }
        entries[target]?.terminalReceiptRecorded = true
        suppressFinished(target)
    }

    mutating func restore(_ target: MRAutomationScope.Target) {
        entries[target]?.acknowledgedTerminalState = nil
    }

    func accepts(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target, observedAt: Date) -> Bool {
        guard let iid = target.iid, iid > 0, target.projectID > 0, !target.username.isEmpty,
              request.mergeRequestID == target.mergeRequestID,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
              [.opened, .closed, .merged].contains(request.state) else { return false }
        return entries[target].map { observedAt >= $0.observedAt } ?? true
    }

    func terminalObservedAt(for target: MRAutomationScope.Target, state: GitLabMergeRequestState) -> Date? {
        guard let entry = entries[target], entry.request.state == state, Self.isFinished(entry.request) else { return nil }
        return entry.terminalObservedAt ?? entry.observedAt
    }

    mutating func record(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target,
                         now: Date = Date(), autoRemoveFinished: Bool = false) {
        guard accepts(request, for: target, observedAt: now) else { return }
        let previous = entries[target]
        var kind: Transition.Kind?
        if let old = previous?.request {
            if old.state != request.state, Self.isFinished(request) {
                kind = request.state == .merged ? .merged : .closed
            } else if old.isOpen, request.isOpen,
                      let wasDraft = old.draft, let isDraft = request.draft, wasDraft != isDraft {
                kind = isDraft ? .draft : .ready
            }
        }
        if let kind {
            let id = UUID()
            pendingTransitions.append(.init(id: id, target: target, kind: kind, title: request.title,
                url: request.webURL, observedAt: now))
            if Self.isFinished(request) { retainCompletion(request, for: target, id: id, observedAt: now) }
        } else if autoRemoveFinished, Self.isFinished(request), let previous,
                  Self.isFinished(previous.request), !isSuppressed(target) {
            // Upgrading a retained terminal row must preserve when it was observed,
            // without inventing a fresh lifecycle banner or reviving suppressed history.
            retainCompletion(previous.request, for: target, id: UUID(),
                observedAt: previous.terminalObservedAt ?? previous.observedAt, replacing: false)
        }
        let acknowledgement = Self.isFinished(request)
            ? (autoRemoveFinished ? request.state : previous?.acknowledgedTerminalState) : nil
        let terminalTime = Self.isFinished(request)
            ? (previous?.request.state == request.state ? previous?.terminalObservedAt ?? previous?.observedAt ?? now : now) : nil
        entries[target] = .init(request: request, observedAt: now, acknowledgedTerminalState: acknowledgement,
            terminalObservedAt: terminalTime,
            terminalReceiptRecorded: Self.isFinished(request) ? entries[target]?.terminalReceiptRecorded : nil)
    }

    private mutating func retainCompletion(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target,
                                          id: UUID, observedAt: Date, replacing: Bool = true) {
        guard Self.isFinished(request), replacing || (completions[target] == nil && entries[target]?.terminalReceiptRecorded != true) else { return }
        completions[target] = .init(id: id, target: target, kind: request.state == .merged ? .merged : .closed,
            title: request.title, url: request.webURL, observedAt: observedAt, author: request.author)
        // Receipt acknowledgement survives restoring a finished row to the board.
        entries[target]?.terminalReceiptRecorded = true
    }

    mutating func takeTransitions(host: String, username: String) -> [Transition] {
        let matching = pendingTransitions.filter { $0.target.host == host && $0.target.username == username }
        pendingTransitions.removeAll { $0.target.host == host && $0.target.username == username }
        return matching
    }

    private static func isFinished(_ request: GitLabMergeRequest) -> Bool {
        request.state == .merged || request.state == .closed
    }
}

/// The last successful reviewer listing, including unread assignments for each account.
struct ReviewAssignmentLedger: Codable, Sendable {
    private struct Account: Codable, Hashable, Sendable {
        let host: String
        let username: String
    }

    private struct ID: Codable, Hashable, Sendable {
        let projectID: Int
        let iid: Int
    }

    struct Entry: Codable, Sendable {
        let request: GitLabMergeRequest
        var newSince: Date?
    }

    private var listings: [Account: [ID: Entry]] = [:]
    private var baselinesEstablished: Set<Account>?
    private var savedIncomingReviewFilter: IncomingReviewFilterLedger?

    var incomingReviewFilter: IncomingReviewFilterLedger {
        get { savedIncomingReviewFilter ?? .init() }
        set { savedIncomingReviewFilter = newValue }
    }

    func assignmentTargets(host: String, username: String) -> Set<MRAutomationScope.Target> {
        Set((entries(host: host, username: username) ?? []).map {
            .mergeRequest(host: host, username: username, projectID: $0.request.projectID, iid: $0.request.iid)
        })
    }

    mutating func observeInboxForFiltering(_ todos: [Todo], host: String, username: String,
                                           enabled: Bool, excluding: Set<MRAutomationScope.Target>) {
        let assigned = assignmentTargets(host: host, username: username)
        incomingReviewFilter.observeInbox(todos, host: host, username: username, assigned: assigned,
            enabled: enabled, excluding: excluding)
    }

    func entries(host: String, username: String) -> [Entry]? {
        listings[Account(host: host, username: username)].map { Array($0.values) }
    }

    func needsBaseline(host: String, username: String) -> Bool {
        baselinesEstablished?.contains(Account(host: host, username: username)) != true
    }

    mutating func observe(_ requests: [GitLabMergeRequest], host: String, username: String, at date: Date,
                          previouslyVisible: Set<MRAutomationScope.Target> = []) {
        let account = Account(host: host, username: username)
        let previous = listings[account]
        let establishingBaseline = needsBaseline(host: host, username: username)
        var next: [ID: Entry] = [:]
        for request in requests where request.isOpen && request.projectID > 0 && request.iid > 0
            && request.author.username != username && request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) {
            let id = ID(projectID: request.projectID, iid: request.iid)
            guard next[id] == nil else { continue }
            let newSince: Date?
            if establishingBaseline {
                let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: id.projectID, iid: id.iid)
                let newlyVisible = !previouslyVisible.isEmpty && !previouslyVisible.contains(target)
                newSince = previous?[id]?.newSince ?? (newlyVisible ? date : nil)
            } else if let old = previous?[id] {
                newSince = old.newSince
            } else {
                newSince = date
            }
            next[id] = .init(request: request, newSince: newSince)
        }
        listings[account] = next
        if establishingBaseline {
            if baselinesEstablished == nil { baselinesEstablished = [] }
            baselinesEstablished?.insert(account)
        }
    }

    @discardableResult
    mutating func markSeen(_ target: MRAutomationScope.Target) -> Bool {
        guard let iid = target.iid else { return false }
        let account = Account(host: target.host, username: target.username)
        let id = ID(projectID: target.projectID, iid: iid)
        guard listings[account]?[id]?.newSince != nil else { return false }
        listings[account]?[id]?.newSince = nil
        return true
    }
}

struct HiddenReview: Codable, Identifiable, Sendable {
    static let restorationInterval: TimeInterval = 3 * 24 * 60 * 60

    struct InboxNotification: Codable, Equatable, Sendable {
        let id: UUID
        let observedAt: Date
        let reason: String?
    }

    let target: MRAutomationScope.Target
    let title: String
    let url: URL
    var inboxNotification: InboxNotification? = nil
    var hideID: UUID? = nil
    var manuallyHidden: Bool? = nil
    var restoreUntil: Date? = nil
    var id: MRAutomationScope.Target { target }
}

struct HiddenMergeRequests: Codable {
    typealias Target = MRAutomationScope.Target
    var targets: Set<Target> = [] {
        didSet { details = details.filter { targets.contains($0.key) } }
    }
    var details: [Target: HiddenReview] = [:]
    var legacyRestoreUntil: Date?

    private enum CodingKeys: String, CodingKey { case targets, details, legacyRestoreUntil }

    init() {}

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(Set<Target>.self) {
            targets = legacy
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        targets = try values.decode(Set<Target>.self, forKey: .targets)
        details = try values.decode([Target: HiddenReview].self, forKey: .details)
        legacyRestoreUntil = try values.decodeIfPresent(Date.self, forKey: .legacyRestoreUntil)
        guard details.allSatisfy({ target, review in
            targets.contains(target) && target == review.target && target.projectID > 0
                && target.iid.map { review.url.isGitLabMergeRequest(host: target.host, iid: $0) } == true
        }) else {
            throw DecodingError.dataCorruptedError(forKey: .details, in: values, debugDescription: "Invalid hidden review identity")
        }
    }

    func encode(to encoder: Encoder) throws {
        if details.isEmpty, legacyRestoreUntil == nil {
            var values = encoder.singleValueContainer()
            try values.encode(targets)
            return
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(targets, forKey: .targets)
        try values.encode(details, forKey: .details)
        try values.encodeIfPresent(legacyRestoreUntil, forKey: .legacyRestoreUntil)
    }

    mutating func migrateRestorationDeadlines(now: Date) -> Bool {
        let deadline = now.addingTimeInterval(HiddenReview.restorationInterval)
        var changed = false
        for (target, review) in details where review.restoreUntil == nil {
            details[target]?.restoreUntil = review.inboxNotification?.observedAt
                .addingTimeInterval(HiddenReview.restorationInterval) ?? deadline
            changed = true
        }
        if legacyRestoreUntil == nil, targets.count > details.count {
            legacyRestoreUntil = deadline
            changed = true
        }
        return changed
    }
}
