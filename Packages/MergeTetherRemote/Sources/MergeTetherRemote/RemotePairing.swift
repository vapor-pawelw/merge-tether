import Foundation
import CryptoKit

public struct RemotePairing: Codable, Equatable, Sendable {
    public static let protocolVersion = 2
    public static let invitationLifetime: TimeInterval = 600
    public enum Role: String, Codable, Sendable { case host, phone }
    public let version: Int
    public let origin: URL
    public let secret: String
    public let access: String
    public let sessionID: UUID
    public let issuedAt: Date
    public let expiresAt: Date
    public let role: Role
    public let publicKey: String
    public let peerPublicKey: String?
    let privateKey: String

    public init(url: URL, now: Date = Date()) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = parts.fragment,
              let values = URLComponents(string: "?" + fragment)?.queryItems,
              values.count == 7, Set(values.map(\.name)).count == 7 else { throw RemoteProtocolError.invalid }
        let fields = Dictionary(uniqueKeysWithValues: values.compactMap { item in item.value.map { (item.name, $0) } })
        guard fields["v"] == String(Self.protocolVersion), let secret = fields["secret"], let access = fields["access"],
              let session = fields["session"].flatMap(UUID.init(uuidString:)), let hostKey = fields["hostKey"],
              let issued = fields["issued"].flatMap({ TimeInterval($0) }), let expires = fields["expires"].flatMap({ TimeInterval($0) }),
              issued.isFinite, expires.isFinite else { throw RemoteProtocolError.invalid }
        let origin: URL
        if parts.scheme == "mergetether", parts.host == "pair", parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil,
           parts.queryItems?.count == 1, parts.queryItems?.first?.name == "relay",
           let raw = parts.queryItems?.first?.value, let parsed = URL(string: raw) { origin = parsed }
        else {
            guard parts.query == nil, var clean = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RemoteProtocolError.invalid }
            clean.fragment = nil
            guard let parsed = clean.url else { throw RemoteProtocolError.invalid }
            origin = parsed
        }
        try self.init(origin: origin, secret: secret, access: access, sessionID: session,
                      issuedAt: Date(timeIntervalSince1970: issued), expiresAt: Date(timeIntervalSince1970: expires),
                      role: .phone, privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.remoteBase64,
                      peerPublicKey: hostKey)
        guard invitationIsValid(now: now) else { throw RemoteProtocolError.invalid }
    }

    private init(origin: URL, secret: String, access: String, sessionID: UUID, issuedAt: Date, expiresAt: Date,
                 role: Role, privateKey: String, peerPublicKey: String?) throws {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              Self.validToken(access), Self.validKey(secret), Self.validKey(privateKey),
              peerPublicKey.map(Self.validKey) ?? (role == .host),
              issuedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince(issuedAt) == Self.invitationLifetime,
              let privateBytes = Data(remoteBase64: privateKey) else { throw RemoteProtocolError.invalid }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes)
        parts.path = ""
        guard let normalized = parts.url else { throw RemoteProtocolError.invalid }
        version = Self.protocolVersion; self.origin = normalized; self.secret = secret; self.access = access
        self.sessionID = sessionID; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.role = role
        self.privateKey = privateKey; self.peerPublicKey = peerPublicKey; publicKey = key.publicKey.rawRepresentation.remoteBase64
    }

    public static func generate(origin: URL, access: String, now: Date = Date()) throws -> Self {
        let issued = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        return try Self(origin: origin, secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).remoteBase64 },
                        access: access, sessionID: UUID(), issuedAt: issued, expiresAt: issued.addingTimeInterval(invitationLifetime),
                        role: .host, privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.remoteBase64, peerPublicKey: nil)
    }
    public func invitationIsValid(now: Date = Date()) -> Bool { now >= issuedAt && now < expiresAt }
    func establishing(peer key: String, now: Date) throws -> Self {
        guard role == .host, peerPublicKey == key || (peerPublicKey == nil && invitationIsValid(now: now)) else { throw RemoteProtocolError.invalid }
        return try Self(origin: origin, secret: secret, access: access, sessionID: sessionID, issuedAt: issuedAt,
                        expiresAt: expiresAt, role: role, privateKey: privateKey, peerPublicKey: key)
    }
    private enum CodingKeys: String, CodingKey { case version, origin, secret, access, sessionID, issuedAt, expiresAt, role, privateKey, peerPublicKey }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.protocolVersion else { throw RemoteProtocolError.invalid }
        try self.init(origin: values.decode(URL.self, forKey: .origin), secret: values.decode(String.self, forKey: .secret),
                      access: values.decode(String.self, forKey: .access), sessionID: values.decode(UUID.self, forKey: .sessionID),
                      issuedAt: values.decode(Date.self, forKey: .issuedAt), expiresAt: values.decode(Date.self, forKey: .expiresAt),
                      role: values.decode(Role.self, forKey: .role), privateKey: values.decode(String.self, forKey: .privateKey),
                      peerPublicKey: values.decodeIfPresent(String.self, forKey: .peerPublicKey))
    }
    public var room: String { Data(SHA256.hash(data: Data("MergeTether remote route v2:\(sessionID.uuidString):\(secret)".utf8))).remoteBase64 }
    private var fragment: String {
        var parts = URLComponents()
        parts.queryItems = [.init(name: "v", value: String(version)), .init(name: "secret", value: secret), .init(name: "access", value: access),
                           .init(name: "session", value: sessionID.uuidString), .init(name: "hostKey", value: role == .host ? publicKey : peerPublicKey),
                           .init(name: "issued", value: String(Int64(issuedAt.timeIntervalSince1970))),
                           .init(name: "expires", value: String(Int64(expiresAt.timeIntervalSince1970)))]
        return parts.percentEncodedQuery!
    }
    public var url: URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/"; parts.percentEncodedFragment = fragment
        return parts.url!
    }
    public var deepLink: URL {
        var parts = URLComponents()
        parts.scheme = "mergetether"; parts.host = "pair"
        parts.queryItems = [.init(name: "relay", value: origin.absoluteString)]; parts.percentEncodedFragment = fragment
        return parts.url!
    }
    private static func validKey(_ value: String) -> Bool {
        validToken(value) && Data(remoteBase64: value).map { $0.count == 32 && $0.remoteBase64 == value } == true
    }
    private static func validToken(_ value: String) -> Bool {
        value.count == 43 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}

public enum RemoteProtocolError: Error { case invalid, ignored, oversized }

extension Data {
    var remoteBase64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(remoteBase64: String) {
        var encoded = remoteBase64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        self.init(base64Encoded: encoded)
    }
}
