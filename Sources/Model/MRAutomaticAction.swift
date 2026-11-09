import Foundation

/// Independent automatic actions. Absence from an opt-out set means inherit, never force on.
enum MRAutomaticAction: String, CaseIterable, Codable, Hashable, Sendable {
    case commentPublication, merge, approval
}
