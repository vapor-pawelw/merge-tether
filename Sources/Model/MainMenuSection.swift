import Foundation

enum MainMenuSection: String, CaseIterable {
    case inbox, mergeRequests

    static func restored(from value: String?) -> Self {
        switch value {
        case "authored", "activity", "mergeRequests": .mergeRequests
        default: .inbox
        }
    }
}
