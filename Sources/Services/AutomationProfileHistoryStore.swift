import Foundation
import Observation

/// Optional UI history. Its failures never modify runtime permissions or the safety journal.
@MainActor @Observable
final class AutomationProfileHistoryStore {
    enum Failure { case read, write, synchronize }
    static let key = "lastCustomAutomationProfile"
    private let defaults: UserDefaults
    private(set) var lastGood: AutomationProfileSnapshot?
    private(set) var failure: Failure?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let raw = defaults.object(forKey: Self.key) else { return }
        guard let data = raw as? Data,
              let snapshot = try? JSONDecoder().decode(AutomationProfileSnapshot.self, from: data), snapshot.isValid else {
            failure = .read
            return
        }
        lastGood = snapshot
    }

    func available(for configuration: AutomationSettings) -> AutomationProfileSnapshot? {
        AutomationProfileSnapshot.custom(from: configuration) ?? lastGood
    }

    @discardableResult
    func save(_ snapshot: AutomationProfileSnapshot) -> Bool {
        guard snapshot.isValid, let encoded = try? JSONEncoder().encode(snapshot) else { failure = .write; return false }
        let previous = defaults.object(forKey: Self.key)
        defaults.set(encoded, forKey: Self.key)
        let written = defaults.data(forKey: Self.key) == encoded
        let synchronized = written && defaults.synchronize()
        guard written && synchronized else {
            if let previous { defaults.set(previous, forKey: Self.key) }
            else { defaults.removeObject(forKey: Self.key) }
            _ = defaults.synchronize()
            failure = written ? .synchronize : .write
            return false
        }
        lastGood = snapshot
        failure = nil
        return true
    }
}
