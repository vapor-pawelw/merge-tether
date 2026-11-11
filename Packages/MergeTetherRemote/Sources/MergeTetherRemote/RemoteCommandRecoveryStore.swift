import Foundation
import Security

public struct RemoteCommandRecovery: Codable, Equatable, Sendable {
    public let version: Int
    public let pairingSession: UUID
    public let command: RemoteCommand
    public init(pairingSession: UUID, command: RemoteCommand) {
        version = RemotePairing.protocolVersion; self.pairingSession = pairingSession; self.command = command
    }
    private enum CodingKeys: String, CodingKey { case version, pairingSession, command }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == RemotePairing.protocolVersion else { throw RemoteProtocolError.invalid }
        self.init(pairingSession: try values.decode(UUID.self, forKey: .pairingSession), command: try values.decode(RemoteCommand.self, forKey: .command))
    }
}

public struct RemoteCommandRecoveryStore: Sendable {
    private let service: String
    private let security: RemotePairingStore.SecurityClient
    public init(service: String) { self.init(service: service, security: .system) }
    init(service: String, security: RemotePairingStore.SecurityClient) { self.service = service; self.security = security }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "phone-command-v2"]
    }
    public func load() throws -> RemoteCommandRecovery? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= RemoteCipher.maximumFrameBytes else { throw RemoteProtocolError.invalid }
        return try JSONDecoder().decode(RemoteCommandRecovery.self, from: data)
    }
    public func save(_ recovery: RemoteCommandRecovery) throws {
        let data = try JSONEncoder().encode(recovery)
        guard data.count <= RemoteCipher.maximumFrameBytes else { throw RemoteProtocolError.oversized }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = security.update(query, attributes)
        if status == errSecItemNotFound {
            guard security.add(query.merging(attributes) { _, new in new }) == errSecSuccess else { throw RemoteProtocolError.invalid }
        } else if status != errSecSuccess { throw RemoteProtocolError.invalid }
    }
    public func remove() throws {
        let status = security.remove(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteProtocolError.invalid }
    }
}
