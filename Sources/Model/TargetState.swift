import Foundation

enum TargetState: Hashable, Sendable {
    case draft
    case open
    case merged
    case closed
    case reopened
    case none

    init(rawState: String?, isDraft: Bool) {
        if isDraft {
            self = .draft
            return
        }
        switch rawState?.lowercased() {
        case "opened", "open": self = .open
        case "merged": self = .merged
        case "closed": self = .closed
        case "reopened": self = .reopened
        case nil, "": self = .none
        default: self = .none
        }
    }
}
