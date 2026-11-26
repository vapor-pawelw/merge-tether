import CryptoKit
import Foundation

struct CrashReportingDestination: Equatable, Sendable {
    let endpoint: URL
    let publicKey: String

    init?(_ dsn: String) {
        guard let parts = URLComponents(string: dsn), parts.scheme == "https",
              let host = parts.host, host.wholeMatch(of: /o[0-9]+\.ingest(\.(us|de))?\.sentry\.io/) != nil,
              parts.port == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let key = parts.percentEncodedUser, key.wholeMatch(of: /[a-fA-F0-9]{32}/) != nil,
              parts.percentEncodedPath.wholeMatch(of: /\/[1-9][0-9]{0,19}/) != nil,
              let endpoint = URL(string: "https://\(host)/api\(parts.path)/envelope/") else { return nil }
        self.endpoint = endpoint
        publicKey = key
    }

    var fingerprint: String {
        SHA256.hash(data: Data((endpoint.absoluteString + publicKey).utf8)).description
    }
}

struct CrashReportingAuthorization: Equatable, Codable, Sendable {
    let installationID: UUID
    let startsAt: Date

    func allowsReport(startingAt date: Date) -> Bool { date >= startsAt }
}

enum CrashReportingDecision: Equatable, Codable {
    case declined
    case allowed(CrashReportingAuthorization)

    var authorization: CrashReportingAuthorization? {
        if case let .allowed(authorization) = self { authorization } else { nil }
    }
}

struct CrashConsentStore {
    let defaults: UserDefaults

    private static let key = "crashReportingConsent"

    private struct Record: Codable {
        let destination: String
        let decision: CrashReportingDecision
        var sent: [String] = []
    }

    func decision(for destination: CrashReportingDestination) -> CrashReportingDecision? {
        guard let record, record.destination == destination.fingerprint else { return nil }
        return record.decision
    }

    func setEnabled(_ enabled: Bool, for destination: CrashReportingDestination, at date: Date) -> CrashReportingDecision {
        if let current = decision(for: destination), (current.authorization != nil) == enabled { return current }
        let decision: CrashReportingDecision = enabled ? .allowed(.init(installationID: UUID(), startsAt: date)) : .declined
        save(.init(destination: destination.fingerprint, decision: decision))
        return decision
    }

    func wasSent(_ id: String, under authorization: CrashReportingAuthorization) -> Bool {
        guard let record, record.decision.authorization == authorization else { return false }
        return record.sent.contains(id)
    }

    func markSent(_ id: String, under authorization: CrashReportingAuthorization) {
        guard var record, record.decision.authorization == authorization, !record.sent.contains(id) else { return }
        record.sent = Array((record.sent + [id]).suffix(100))
        save(record)
    }

    private var record: Record? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
