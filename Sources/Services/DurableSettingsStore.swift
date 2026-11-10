import Foundation
import Observation

/// Keeps unsupported/corrupt records intact. Missing fields remain the Codable model's
/// compatibility decision; a failed decode is never a migration to an empty journal.
@MainActor @Observable
final class DurableSettingsStore {
    enum Failure: String { case decode, encode, write, synchronize, journal }
    private static let failureKey = "settingsPersistenceFailures"
    private let defaults: UserDefaults
    private(set) var failures: [String: Failure] = [:]
    @ObservationIgnored private var corrupt: [String: NSObject] = [:]
    @ObservationIgnored private var backups: [String: String] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let saved = defaults.object(forKey: Self.failureKey) {
            if let keys = saved as? [String] {
                for key in keys { failures[key] = .write }
            } else {
                corrupt[Self.failureKey] = saved as? NSObject
                failures[Self.failureKey] = .decode
            }
        }
    }

    func load<Value: Decodable>(_ key: String, fallback: @autoclosure () -> Value) -> Value {
        guard let raw = defaults.object(forKey: key) else { return fallback() }
        do {
            guard let data = raw as? Data else { throw CocoaError(.coderReadCorrupt) }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            corrupt[key] = raw as? NSObject
            recordFailure(key, .decode)
            return fallback()
        }
    }

    /// Called by explicit save, never by view evaluation or initialization.
    func preserveCorruptValues() {
        for (key, raw) in corrupt {
            let base = key + ".corrupt"
            let backup = backups[key] ?? (defaults.object(forKey: base) == nil
                || (defaults.object(forKey: base) as? NSObject)?.isEqual(raw) == true
                ? base : base + "." + UUID().uuidString)
            backups[key] = backup
            if (defaults.object(forKey: backup) as? NSObject)?.isEqual(raw) != true {
                defaults.set(raw, forKey: backup)
            }
            if (defaults.object(forKey: backup) as? NSObject)?.isEqual(raw) != true {
                recordFailure(key, .write)
            }
        }
    }

    @discardableResult
    func save<Value: Encodable>(_ value: Value, forKey key: String) -> Bool {
        guard corrupt[key] == nil else { return false }
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { recordFailure(key, .encode); return false }
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { recordFailure(key, .write); return false }
        return true
    }

    @discardableResult
    func synchronize() -> Bool {
        guard defaults.synchronize() else {
            recordFailure("settingsPersistence", .synchronize)
            return false
        }
        return true
    }

    /// Write failures can leave a valid but obsolete journal. Retain a key-only hold
    /// across restart when preferences are writable; an unrelated save cannot clear it.
    func recordFailure(_ key: String, _ failure: Failure = .journal) {
        if failures[key] != failure {
            Log.monitor.error("Persistence failure: \(key, privacy: .public) [\(failure.rawValue, privacy: .public)]")
            failures[key] = failure
        }
        guard failure != .decode, corrupt[Self.failureKey] == nil else { return }
        let previous = defaults.stringArray(forKey: Self.failureKey) ?? []
        let keys = Set(previous).union(failures.filter { $0.value != .decode }.keys).sorted()
        defaults.set(keys, forKey: Self.failureKey)
        if defaults.stringArray(forKey: Self.failureKey) != keys || !defaults.synchronize() {
            failures["settingsPersistence"] = .synchronize
        }
    }
}
