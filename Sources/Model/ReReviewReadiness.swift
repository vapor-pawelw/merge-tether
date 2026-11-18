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

    var hasConcreteConcerns: Bool {
        switch self {
        case .blocked(let blockers), .uncertain(let blockers): !blockers.isEmpty
        default: false
        }
    }

    var canConfirm: Bool {
        switch self {
        case .manual, .unavailable, .failed: true
        case .uncertain(let blockers): blockers.isEmpty
        default: false
        }
    }

    var manualConfirmationDetails: [String] {
        let status = String(localized: message)
        guard case .uncertain(let blockers) = self else { return [status] }
        return [status] + blockers.map { $0.summary ?? $0.reason }
    }

    var message: LocalizedStringResource {
        switch self {
        case .checking: .Menu.menuReReviewChecking
        case .manual: .Menu.menuReReviewManual
        case .unavailable: .Menu.menuReReviewUnavailable
        case .failed: .Menu.menuReReviewFailed
        case .blocked: .Menu.menuReReviewBlocked
        case .uncertain(let blockers): blockers.isEmpty ? .Menu.menuReReviewFailed : .Menu.menuReReviewUncertain
        }
    }
}
