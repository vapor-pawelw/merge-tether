import Foundation

public struct RemoteCardAutomation: Codable, Equatable, Sendable {
    public enum Preference: String, CaseIterable, Codable, Sendable { case `default`, on, off }

    public struct Rule: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case commentPublication, merge, approval }
        public let id: Kind
        public let preference: Preference
        public let editable: Bool

        public init(id: Kind, preference: Preference, editable: Bool) {
            self.id = id; self.preference = preference; self.editable = editable
        }
    }

    public let active: Bool
    public let source: String
    public let globallySuspended: Bool
    public let preference: Preference
    public let customized: Bool
    public let rules: [Rule]
    public let repositoryEnabled: Bool
    public let repositoryInherits: Bool

    public init(active: Bool, source: String, globallySuspended: Bool, preference: Preference,
                customized: Bool, rules: [Rule], repositoryEnabled: Bool, repositoryInherits: Bool) {
        self.active = active; self.source = source; self.globallySuspended = globallySuspended
        self.preference = preference; self.customized = customized; self.rules = rules
        self.repositoryEnabled = repositoryEnabled; self.repositoryInherits = repositoryInherits
    }
}

public enum RemoteCardAssistant: String, Codable, Sendable, Identifiable {
    case codexApp, claudeDesktop, t3Code, codexCLI, claudeCLI
    public var id: String { rawValue }
    public var requiresMessage: Bool { self == .codexCLI || self == .claudeCLI }
}

public enum RemoteCardChange: Codable, Equatable, Sendable {
    public static let actionID = "editCard"
    public static let maximumAssistantMessageBytes = 2_000
    private static let maximumArgumentBytes = 16_384

    case pin(Bool)
    case automation(RemoteCardAutomation.Preference)
    case rule(RemoteCardAutomation.Rule.Kind, RemoteCardAutomation.Preference)
    case repository(RemoteCardAutomation.Preference)
    case refresh
    case remove
    case acknowledge
    case openAssistant(RemoteCardAssistant, message: String?)

    public var argument: String? {
        guard isValid, let bytes = try? JSONEncoder().encode(self), bytes.count <= Self.maximumArgumentBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    public init?(argument: String?) {
        guard let argument, argument.utf8.count <= Self.maximumArgumentBytes,
              let change = try? JSONDecoder().decode(Self.self, from: Data(argument.utf8)), change.isValid else { return nil }
        self = change
    }

    private var isValid: Bool {
        guard case .openAssistant(let destination, let message) = self else { return true }
        guard destination.requiresMessage else { return message == nil }
        guard let message, message.utf8.count <= Self.maximumAssistantMessageBytes else { return false }
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
