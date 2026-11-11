import Foundation
import Security
import Testing
@testable import MergeTetherRemote

@Suite struct PairingStoreTests {
    @Test func pairingPersistsAndReplacementRevokesTheOldRoomLocally() throws {
        let memory = InMemorySecurity()
        let service = "MergeTetherRemoteTests.\(UUID())"
        let store = RemotePairingStore(service: service, security: memory.client)
        let first = try pairing()
        try store.save(first)
        #expect(try RemotePairingStore(service: service, security: memory.client).load() == first)
        let second = try RemotePairing.generate(origin: first.origin, access: first.access)
        try store.save(second)
        #expect(try store.load() == second)
        try store.remove()
        #expect(try store.load() == nil)
        try store.remove()
    }

    @Test func storageUsesOnlyItsOwnServiceAndTheDeviceOnlyAccessibilityPolicy() throws {
        let memory = InMemorySecurity()
        let mine = RemotePairingStore(service: "mine", security: memory.client)
        let other = RemotePairingStore(service: "other", security: memory.client)
        let first = try pairing(), second = try pairing()
        try mine.save(first)
        try other.save(second)
        try mine.remove()
        #expect(try mine.load() == nil)
        #expect(try other.load() == second)
        let queries = memory.recorded
        #expect(queries.allSatisfy { $0[kSecClass as String] as? String == kSecClassGenericPassword as String })
        #expect(queries.allSatisfy { $0[kSecAttrAccount as String] as? String == "pairing-v2" })
        let additions = queries.filter { $0[kSecValueData as String] != nil }
        #expect(additions.count == 2)
        #expect(additions.allSatisfy {
            $0[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        })
        let reads = queries.filter { $0[kSecReturnData as String] as? Bool == true }
        #expect(reads.count == 2)
        #expect(reads.allSatisfy { $0[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String })
    }

    @Test(arguments: ["read", "update", "add", "remove"])
    func keychainFailureIsReportedInsteadOfBeingTreatedAsMissingData(_ operation: String) throws {
        let memory = InMemorySecurity(failing: operation)
        let store = RemotePairingStore(service: "failure", security: memory.client)
        let value = try pairing()
        switch operation {
        case "read": #expect(throws: (any Error).self) { _ = try store.load() }
        case "remove": #expect(throws: (any Error).self) { try store.remove() }
        default: #expect(throws: (any Error).self) { try store.save(value) }
        }
        #expect(memory.itemCount == 0)
        if operation == "update" {
            #expect(!memory.recorded.contains { $0[kSecValueData as String] != nil })
        }
    }

    private func pairing() throws -> RemotePairing {
        try RemotePairing.generate(origin: URL(string: "https://example.org")!, access: String(repeating: "A", count: 43))
    }
}

final class InMemorySecurity: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var queries: [[String: Any]] = []
    var failing: String?
    init(failing: String? = nil) { self.failing = failing }
    var recorded: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return queries }
    var itemCount: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var client: RemotePairingStore.SecurityClient {
        .init(read: { [self] query in
            lock.lock(); defer { lock.unlock() }
            queries.append(query)
            if failing == "read" { return (errSecAuthFailed, nil) }
            let value = values[key(query)]
            return (value == nil ? errSecItemNotFound : errSecSuccess, value)
        }, update: { [self] query, attributes in
            lock.lock(); defer { lock.unlock() }
            queries.append(query)
            if failing == "update" { return errSecAuthFailed }
            guard values[key(query)] != nil else { return errSecItemNotFound }
            values[key(query)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { [self] query in
            lock.lock(); defer { lock.unlock() }
            queries.append(query)
            if failing == "add" { return errSecAuthFailed }
            guard values[key(query)] == nil else { return errSecDuplicateItem }
            values[key(query)] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }, remove: { [self] query in
            lock.lock(); defer { lock.unlock() }
            queries.append(query)
            if failing == "remove" { return errSecAuthFailed }
            return values.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        })
    }
    private func key(_ query: [String: Any]) -> String {
        (query[kSecAttrService as String] as? String ?? "") + "|" + (query[kSecAttrAccount as String] as? String ?? "")
    }
}
