import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AutoHandledEventBannerCenter {
    struct Event: Identifiable {
        let id: UUID
        let target: MRAutomationScope.Target
        let kind: MRTodoIntent.Kind
        let projectPath: String
        let expiresAt: Date
    }

    private(set) var events: [Event] = []

    private struct RecentIntent: Hashable {
        let target: MRAutomationScope.Target
        let id: UUID
    }

    private let recentIntentLimit: Int
    @ObservationIgnored private var receivedFingerprints: [RecentIntent: String] = [:]
    @ObservationIgnored private var recentIntents: [RecentIntent] = []

    init(recentIntentLimit: Int = 512) {
        self.recentIntentLimit = max(1, recentIntentLimit)
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
        events.removeAll { $0.expiresAt <= now }
        guard enabled else { return }
        events.append(.init(id: UUID(), target: intent.target, kind: intent.kind,
                            projectPath: intent.request.webURL.gitLabProjectPath,
                            expiresAt: now.addingTimeInterval(8)))
        if events.count > 3 { events.removeFirst(events.count - 3) }
    }

    private static func fingerprint(_ events: [Todo.FeedbackIdentity]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? events.map({ try encoder.encode($0).base64EncodedString() }) else { return nil }
        let canonical = Set(encoded).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func dismiss(_ id: UUID) { events.removeAll { $0.id == id } }

    func current(host: String?, username: String?, enabled: Bool, now: Date = Date()) -> Event? {
        guard enabled else { return nil }
        return events.first { $0.target.host == host && $0.target.username == username && $0.expiresAt > now }
    }
}
