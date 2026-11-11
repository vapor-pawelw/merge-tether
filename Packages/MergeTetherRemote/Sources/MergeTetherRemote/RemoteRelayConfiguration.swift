import Foundation

public struct RemoteRelayConfiguration: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case missing, invalid, configured }
    public let status: Status
    public let origin: URL?

    public init(rawOrigin: String?) {
        guard let raw = rawOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            status = .missing; origin = nil; return
        }
        guard let normalized = Self.normalize(raw) else { status = .invalid; origin = nil; return }
        origin = normalized; status = .configured
    }

    public static func bundled(in bundle: Bundle = .main) -> Self {
        .init(rawOrigin: bundle.object(forInfoDictionaryKey: "MergeTetherRelayOrigin") as? String)
    }

    public func accepts(origin candidate: URL) -> Bool {
        guard let origin else { return false }
        return Self.normalize(candidate.absoluteString) == origin
    }

    private static func normalize(_ raw: String) -> URL? {
        guard !raw.contains("%"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.url != nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
        if parts.port == 443 { parts.port = nil }
        return parts.url
    }
}
