import Foundation

enum MRAutomaticAction: String, CaseIterable, Codable, Hashable, Sendable {
    case commentPublication, merge, approval
}

enum MRAutomationPreference: CaseIterable, Hashable, Sendable {
    case `default`, on, off
}
