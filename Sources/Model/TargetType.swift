import Foundation

enum TargetType: Hashable, Codable, Sendable {
    case mergeRequest
    case issue
    case epic
    case designManagementDesign
    case alert
    case wikiPage
    case commit
    case snippet
    case workItem
    case unknown(String)

    var rawValue: String {
        switch self {
        case .mergeRequest: "MergeRequest"
        case .issue: "Issue"
        case .epic: "Epic"
        case .designManagementDesign: "DesignManagement::Design"
        case .alert: "AlertManagement::Alert"
        case .wikiPage: "WikiPage::Meta"
        case .commit: "Commit"
        case .snippet: "Snippet"
        case .workItem: "WorkItem"
        case .unknown(let raw): raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "MergeRequest": self = .mergeRequest
        case "Issue": self = .issue
        case "Epic": self = .epic
        case "DesignManagement::Design": self = .designManagementDesign
        case "AlertManagement::Alert": self = .alert
        case "WikiPage::Meta": self = .wikiPage
        case "Commit": self = .commit
        case "Snippet": self = .snippet
        case "WorkItem": self = .workItem
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = .init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Prefix used in the badge pill (e.g. "!1369" for MRs, "#42" for issues).
    var identifierPrefix: String {
        switch self {
        case .mergeRequest: "!"
        case .issue: "#"
        case .epic: "&"
        case .workItem: "#"
        default: ""
        }
    }
}
