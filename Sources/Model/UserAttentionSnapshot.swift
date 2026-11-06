import CryptoKit
import Foundation

/// The one semantic projection consumed by both the menu indicator and notifications.
struct UserAttentionSnapshot: Equatable, Sendable {
    enum Reason: String, Hashable, Sendable {
        case drafts, approval, discussion, pipeline, pipelineHandoff, conflict, merge
        case review, reviewConfirmation, failedWork, proposal, otherEvent
    }
    struct Action: Hashable, Sendable {
        let reason: Reason
        let token: String
        var automatic = false
    }
    struct Candidate: Sendable {
        let id: String
        let title: String
        var subtitle = ""
        let actions: [Action]
        var working = false
    }
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let reasons: Set<Reason>
        let actionTokens: Set<String>
        let signature: String
    }
    let items: [Item]
    var count: Int { items.count }
    var hasAttention: Bool { !items.isEmpty }
    static let empty = Self(candidates: [])

    init(candidates: [Candidate]) {
        let grouped = Dictionary(grouping: candidates.filter { !$0.working }, by: \.id)
        items = grouped.compactMap { id, group in
            let actions = Set(group.flatMap(\.actions).filter { !$0.automatic })
            guard !actions.isEmpty, let first = group.first else { return nil }
            let content = actions.map { $0.reason.rawValue + ":" + $0.token }.sorted().joined(separator: "\n")
            return Item(id: id, title: first.title, subtitle: first.subtitle,
                        reasons: Set(actions.map(\.reason)), actionTokens: Set(actions.map { $0.reason.rawValue + ":" + $0.token }),
                        signature: Self.digest(id + "\n" + content))
        }.sorted { $0.id < $1.id }
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Session-local baselines deliberately prevent restart/account-switch notification bursts.
struct UserAttentionNotificationLedger {
    private var account: String?
    private var seen: Set<String> = []

    mutating func update(_ snapshot: UserAttentionSnapshot, account: String?, fresh: Bool, allowed: Bool) -> [UserAttentionSnapshot.Item] {
        guard let account else { self.account = nil; seen = []; return [] }
        guard fresh else { return [] }
        let signatures = Set(snapshot.items.flatMap { item in item.actionTokens.map { item.id + "\n" + $0 } })
        guard self.account == account else {
            self.account = account; seen = signatures; return []
        }
        let new = snapshot.items.filter { item in item.actionTokens.contains { !seen.contains(item.id + "\n" + $0) } }
        if !allowed { seen.formUnion(signatures); return [] }
        return new
    }

    mutating func acknowledge(_ items: [UserAttentionSnapshot.Item], account: String?) {
        guard self.account == account else { return }
        seen.formUnion(items.flatMap { item in item.actionTokens.map { item.id + "\n" + $0 } })
    }
}
