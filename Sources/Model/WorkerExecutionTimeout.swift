import Foundation

/// Task configuration, independent of profile permissions and verifier/request budgets.
struct WorkerExecutionTimeout: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Sendable {
        static let validMinutes = 1...1_440
        static let standard = Self(minutes: 30)
        let minutes: Int
        var seconds: TimeInterval { TimeInterval(minutes * 60) }

        init(minutes: Int) {
            self.minutes = Self.validMinutes.contains(minutes) ? minutes : 30
        }

        init(from decoder: Decoder) throws {
            let value = try? decoder.singleValueContainer().decode(Int.self)
            self.init(minutes: value ?? 30)
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            try value.encode(minutes)
        }
    }

    struct ProjectKey: Hashable {
        let host: String
        let projectID: Int

        init?(host: String, projectID: Int) {
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:[]")
            guard projectID > 0, !host.isEmpty,
                  host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }),
                  let parts = URLComponents(string: "https://\(host)"),
                  let name = parts.host, !name.isEmpty, parts.url != nil,
                  parts.user == nil, parts.password == nil, parts.path.isEmpty,
                  parts.query == nil, parts.fragment == nil,
                  parts.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
            self.host = host
            self.projectID = projectID
        }
    }

    struct ProjectOverride: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var host: String
        var projectID: Int
        var projectPath: String?
        var limit: Limit
        var key: ProjectKey? { ProjectKey(host: host, projectID: projectID) }

        init(host: String, projectID: Int, projectPath: String? = nil, limit: Limit) {
            id = UUID()
            self.host = host
            self.projectID = projectID
            self.projectPath = projectPath
            self.limit = limit
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            host = try values.decode(String.self, forKey: .host)
            projectID = try values.decode(Int.self, forKey: .projectID)
            projectPath = try values.decodeIfPresent(String.self, forKey: .projectPath)
            limit = (try? values.decode(Limit.self, forKey: .limit)) ?? .standard
        }

        private enum CodingKeys: String, CodingKey { case id, host, projectID, projectPath, limit }
    }

    var defaultLimit: Limit
    var projectOverrides: [ProjectOverride]

    init(defaultLimit: Limit = .standard, projectOverrides: [ProjectOverride] = []) {
        self.defaultLimit = defaultLimit
        self.projectOverrides = projectOverrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultLimit = (try? values.decode(Limit.self, forKey: .defaultLimit)) ?? .standard
        projectOverrides = try values.decodeIfPresent([ProjectOverride].self, forKey: .projectOverrides) ?? []
    }

    var hasInvalidOverrides: Bool {
        let keys = projectOverrides.compactMap(\.key)
        return keys.count != projectOverrides.count || Set(keys).count != keys.count
    }

    func limit(host: String, projectID: Int) -> Limit {
        guard let key = ProjectKey(host: host, projectID: projectID) else { return .standard }
        let matches = projectOverrides.filter { $0.key == key }
        guard matches.count <= 1 else { return .standard }
        return matches.first?.limit ?? defaultLimit
    }

    private enum CodingKeys: String, CodingKey { case defaultLimit, projectOverrides }
}
