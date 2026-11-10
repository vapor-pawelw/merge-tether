import Foundation

enum ReReviewReadiness: Equatable, Sendable {
    case checking, manual, unavailable, failed
    case blocked([Blocker])
    case uncertain([Blocker])

    struct Blocker: Equatable, Sendable {
        let noteID: Int
        let reason: String
        var summary: String? = nil
        var isUncertain = false
        var isPrivateCodeQuestion = false
    }

    var isUncertain: Bool {
        if case .uncertain = self { return true }
        return false
    }

    var canConfirm: Bool {
        switch self {
        case .manual, .unavailable, .failed, .uncertain: true
        default: false
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .checking: .Menu.menuReReviewChecking
        case .manual: .Menu.menuReReviewManual
        case .unavailable: .Menu.menuReReviewUnavailable
        case .failed: .Menu.menuReReviewFailed
        case .blocked: .Menu.menuReReviewBlocked
        case .uncertain: .Menu.menuReReviewFailed
        }
    }
}
