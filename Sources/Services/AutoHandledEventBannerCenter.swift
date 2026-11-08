import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AutoHandledEventBannerCenter {
    enum Kind: String {
        case review, followUp, pipeline, conflict, refresh
        case merged, closed, ready, draft

        init(_ intent: MRTodoIntent.Kind) {
            switch intent {
            case .review: self = .review
            case .followUp: self = .followUp
            case .pipeline: self = .pipeline
            case .conflict: self = .conflict
            case .refresh: self = .refresh
            }
        }
    }

    struct Event: Identifiable {
        let id: UUID
        let target: MRAutomationScope.Target
        let kind: Kind
        let projectPath: String
        var expiresAt: Date
    }

    private(set) var events: [Event] = []

    private struct RecentIntent: Hashable {
        let target: MRAutomationScope.Target
        let id: UUID
    }

    private let recentIntentLimit: Int
    @ObservationIgnored private var receivedFingerprints: [RecentIntent: String] = [:]
    @ObservationIgnored private var recentIntents: [RecentIntent] = []
    @ObservationIgnored private var receivedLifecycleIDs: Set<RecentIntent> = []
    @ObservationIgnored private var recentLifecycleIDs: [RecentIntent] = []

    init(recentIntentLimit: Int = 512) {
        self.recentIntentLimit = max(1, recentIntentLimit)
    }

    func receiveLifecycle(id: UUID, target: MRAutomationScope.Target, kind: Kind,
                          projectPath: String, enabled: Bool, now: Date = Date()) {
        guard kind == .merged || kind == .closed || kind == .ready || kind == .draft else { return }
        let key = RecentIntent(target: target, id: id)
        guard receivedLifecycleIDs.insert(key).inserted else { return }
        recentLifecycleIDs.append(key)
        if recentLifecycleIDs.count > recentIntentLimit {
            receivedLifecycleIDs.remove(recentLifecycleIDs.removeFirst())
        }
        // The durable lifecycle ledger owns observation and long-term replay
        // prevention, including when the finished MR has left the board.
        present(target: target, kind: kind, projectPath: projectPath, enabled: enabled, now: now)
    }

    func receive(_ intent: MRTodoIntent, enabled: Bool, now: Date = Date()) {
        guard let fingerprint = Self.fingerprint(intent.sourceEvents) else { return }
        let key = RecentIntent(target: intent.target, id: intent.id)
        guard receivedFingerprints[key] != fingerprint else { return }
        if receivedFingerprints[key] == nil { recentIntents.append(key) }
        receivedFingerprints[key] = fingerprint
        if recentIntents.count > recentIntentLimit {
            receivedFingerprints.removeValue(forKey: recentIntents.removeFirst())
        }
        // Durable routing receipts own long-term replay prevention. This is a
        // bounded presentation cache, retaining one hash per recent MR action.
        present(target: intent.target, kind: .init(intent.kind), projectPath: intent.request.webURL.gitLabProjectPath,
                enabled: enabled, now: now)
    }

    private func present(target: MRAutomationScope.Target, kind: Kind, projectPath: String, enabled: Bool, now: Date) {
        events.removeAll { $0.expiresAt <= now }
        guard enabled else { return }
        let previousExpiry = events.last { Self.sameAccount($0.target, target) }?.expiresAt ?? now
        events.append(.init(id: UUID(), target: target, kind: kind, projectPath: projectPath,
            expiresAt: max(now, previousExpiry).addingTimeInterval(8)))
        if events.count > 20 {
            // Preserve the currently displayed banner when trimming the queue.
            let oldestPending = events.indices.first { index in
                events[..<index].contains { Self.sameAccount($0.target, events[index].target) }
            } ?? events.startIndex
            let removedTarget = events.remove(at: oldestPending).target
            if let first = events.first(where: { Self.sameAccount($0.target, removedTarget) }) {
                schedule(target: removedTarget, firstExpiry: first.expiresAt)
            }
        }
    }

    private static func fingerprint(_ events: [Todo.FeedbackIdentity]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? events.map({ try encoder.encode($0).base64EncodedString() }) else { return nil }
        let canonical = Set(encoded).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func dismiss(_ id: UUID, now: Date = Date()) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let target = events[index].target
        let wasFirst = !events[..<index].contains { Self.sameAccount($0.target, target) }
        events.remove(at: index)
        guard let next = events.first(where: { Self.sameAccount($0.target, target) }) else { return }
        // Each newly displayed banner gets eight seconds, including after an
        // early dismissal or a delayed expiry callback when the app resumes.
        schedule(target: target, firstExpiry: wasFirst ? now.addingTimeInterval(8) : next.expiresAt)
    }

    private func schedule(target: MRAutomationScope.Target, firstExpiry: Date) {
        var expiry = firstExpiry
        for index in events.indices where Self.sameAccount(events[index].target, target) {
            events[index].expiresAt = expiry
            expiry = expiry.addingTimeInterval(8)
        }
    }

    private static func sameAccount(_ lhs: MRAutomationScope.Target, _ rhs: MRAutomationScope.Target) -> Bool {
        lhs.host == rhs.host && lhs.username == rhs.username
    }

    func current(host: String?, username: String?, enabled: Bool, now: Date = Date()) -> Event? {
        guard enabled else { return nil }
        return events.first { $0.target.host == host && $0.target.username == username && $0.expiresAt > now }
    }
}
