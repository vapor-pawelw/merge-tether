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

    private struct Entry: Codable, Sendable {
        var request: GitLabMergeRequest
        var observedAt: Date
        var acknowledgedTerminalState: String?
    }
    private var entries: [MRAutomationScope.Target: Entry] = [:]
    private var pendingTransitions: [Transition] = []

    init() {}

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
        entries[target]?.acknowledgedTerminalState = entry.request.state
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
            pendingTransitions.append(.init(id: UUID(), target: target, kind: kind, title: request.title,
                url: request.webURL, observedAt: now))
        }
        let acknowledgement = Self.isFinished(request)
            ? (autoRemoveFinished ? request.state : previous?.acknowledgedTerminalState) : nil
        entries[target] = .init(request: request, observedAt: now, acknowledgedTerminalState: acknowledgement)
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
