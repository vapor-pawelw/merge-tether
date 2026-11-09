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
        var acknowledgedTerminalState: String?
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
        if entries[receipt.target]?.request.state == receipt.kind.rawValue {
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
        if completions[target]?.kind.rawValue == entry.request.state { completions.removeValue(forKey: target) }
        entries[target]?.terminalReceiptRecorded = true
        suppressFinished(target)
    }

    mutating func restore(_ target: MRAutomationScope.Target) {
        entries[target]?.acknowledgedTerminalState = nil
    }

    mutating func record(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target,
                         now: Date = Date(), autoRemoveFinished: Bool = false) {
        guard let iid = target.iid, iid > 0, target.projectID > 0, !target.username.isEmpty,
              request.projectID == target.projectID, request.iid == iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
              ["opened", "closed", "merged"].contains(request.state) else { return }
        let previous = entries[target]
        guard previous.map({ now >= $0.observedAt }) ?? true else { return }
        var kind: Transition.Kind?
        if let old = previous?.request {
            if old.state != request.state, Self.isFinished(request) {
                kind = request.state == "merged" ? .merged : .closed
            } else if old.state == "opened", request.state == "opened",
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
        completions[target] = .init(id: id, target: target, kind: request.state == "merged" ? .merged : .closed,
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
        request.state == "merged" || request.state == "closed"
    }
}
