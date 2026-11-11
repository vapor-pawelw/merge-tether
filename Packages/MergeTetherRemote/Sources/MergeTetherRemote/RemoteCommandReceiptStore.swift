import Foundation
import Security

public struct RemoteCommandReceiptStore: Sendable {
    struct Receipt: Codable, Sendable {
        var command: RemoteCommand
        var result: RemoteCommandResult
    }
    struct Snapshot: Codable, Sendable {
        var version = RemotePairing.protocolVersion
        var pairingSession: UUID
        var receipts: [Receipt] = []
    }
    static let maximumReceipts = 512
    private static let maximumStorageBytes = 1_048_576
    private let service: String
    private let security: RemotePairingStore.SecurityClient
    public init(service: String) { self.init(service: service, security: .system) }
    init(service: String, security: RemotePairingStore.SecurityClient) { self.service = service; self.security = security }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "command-receipts-v2"]
    }
    func load() throws -> Snapshot? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = security.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= Self.maximumStorageBytes else { throw RemoteProtocolError.invalid }
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        try validate(snapshot)
        for index in snapshot.receipts.indices where snapshot.receipts[index].result.status == .running {
            snapshot.receipts[index].result.status = .uncertain
        }
        return snapshot
    }
    func save(_ snapshot: Snapshot) throws {
        try validate(snapshot)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumStorageBytes else { throw RemoteProtocolError.oversized }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = security.update(query, attributes)
        if status == errSecItemNotFound {
            guard security.add(query.merging(attributes) { _, new in new }) == errSecSuccess else { throw RemoteProtocolError.invalid }
        } else if status != errSecSuccess { throw RemoteProtocolError.invalid }
    }
    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == RemotePairing.protocolVersion, snapshot.receipts.count <= Self.maximumReceipts,
              Set(snapshot.receipts.map { $0.command.id }).count == snapshot.receipts.count,
              snapshot.receipts.allSatisfy({ $0.command.id == $0.result.id })
        else { throw RemoteProtocolError.invalid }
    }
}
