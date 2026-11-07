import Foundation
import CryptoKit

public struct RemotePairing: Codable, Equatable, Sendable {
    public let origin: URL
    public let secret: String
    public let access: String

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = parts.fragment,
              let values = URLComponents(string: "?" + fragment)?.queryItems,
              values.first(where: { $0.name == "v" })?.value == "1",
              let secret = values.first(where: { $0.name == "secret" })?.value,
              let access = values.first(where: { $0.name == "access" })?.value else { throw RemoteProtocolError.invalid }
        let origin: URL
        if parts.scheme == "mergetether", parts.host == "pair",
           let raw = parts.queryItems?.first(where: { $0.name == "relay" })?.value, let parsed = URL(string: raw) {
            origin = parsed
        } else {
            guard parts.query == nil, var clean = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RemoteProtocolError.invalid }
            clean.fragment = nil
            guard let parsed = clean.url else { throw RemoteProtocolError.invalid }
            origin = parsed
        }
        try self.init(origin: origin, secret: secret, access: access)
    }

    public init(origin: URL, secret: String, access: String) throws {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              Self.validToken(access), Self.validToken(secret),
              let bytes = Data(remoteBase64: secret), bytes.count == 32, bytes.remoteBase64 == secret else { throw RemoteProtocolError.invalid }
        parts.path = ""
        guard let normalized = parts.url else { throw RemoteProtocolError.invalid }
        self.origin = normalized
        self.secret = secret
        self.access = access
    }

    public static func generate(origin: URL, access: String) throws -> Self {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).remoteBase64 }
        return try Self(origin: origin, secret: secret, access: access)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(origin: values.decode(URL.self, forKey: .origin),
                      secret: values.decode(String.self, forKey: .secret), access: values.decode(String.self, forKey: .access))
    }

    public var room: String { Data(SHA256.hash(data: Data("mt-probe-route-v1:\(secret)".utf8))).remoteBase64 }

    public var url: URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/"
        parts.fragment = "v=1&secret=\(secret)&access=\(access)"
        return parts.url!
    }

    public var deepLink: URL {
        var parts = URLComponents()
        parts.scheme = "mergetether"
        parts.host = "pair"
        parts.queryItems = [.init(name: "relay", value: origin.absoluteString)]
        parts.fragment = "v=1&secret=\(secret)&access=\(access)"
        return parts.url!
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
