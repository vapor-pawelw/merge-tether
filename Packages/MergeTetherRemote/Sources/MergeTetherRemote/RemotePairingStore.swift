import Foundation
import Security

public struct RemotePairingStore: Sendable {
    struct SecurityClient: Sendable {
        let read: @Sendable ([String: Any]) -> (OSStatus, Data?)
        let update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        let add: @Sendable ([String: Any]) -> OSStatus
        let remove: @Sendable ([String: Any]) -> OSStatus

        static let system = Self(read: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
           add: { SecItemAdd($0 as CFDictionary, nil) },
           remove: { SecItemDelete($0 as CFDictionary) })
    }

    private let service: String
    private let security: SecurityClient
    public init(service: String) { self.init(service: service, security: .system) }
    init(service: String, security: SecurityClient) { self.service = service; self.security = security }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: "pairing-v2"] }
    public func load() throws -> RemotePairing? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(RemotePairing.self, from: data)
    }
    public func save(_ pairing: RemotePairing) throws {
        let data = try JSONEncoder().encode(pairing)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = security.update(query, attributes)
        if status == errSecItemNotFound {
            let added = security.add(query.merging(attributes) { _, new in new })
            guard added == errSecSuccess else { throw StoreError(status: added) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }
    public func remove() throws {
        let status = security.remove(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }
    private struct StoreError: Error { let status: OSStatus }
}
