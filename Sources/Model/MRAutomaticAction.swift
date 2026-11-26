import Foundation

enum MRAutomaticAction: String, CaseIterable, Codable, Hashable, Sendable {
    case commentPublication, merge, approval
}

enum AutomaticActionMode: String, CaseIterable, Hashable, Sendable {
    case off, on, prompt
}

struct AutomaticActionPrompt: Codable, Equatable, Sendable {
    var required = false
    var criteria = ""

    func mode(enabled: Bool) -> AutomaticActionMode {
        enabled ? (required ? .prompt : .on) : .off
    }
}

enum MRAutomationPreference: String, Codable, CaseIterable, Hashable, Sendable {
    case `default`, on, off
}
