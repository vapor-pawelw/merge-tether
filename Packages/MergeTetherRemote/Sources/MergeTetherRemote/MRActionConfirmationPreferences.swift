import Foundation

public struct MRActionConfirmationPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func requiresConfirmation(for action: String) -> Bool {
        !defaults.bool(forKey: key(for: action))
    }

    public func accept(_ action: String, remember: Bool) {
        if remember { defaults.set(true, forKey: key(for: action)) }
    }

    private func key(for action: String) -> String { "skipMRActionConfirmation.\(action)" }
}
