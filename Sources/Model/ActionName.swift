import Foundation

enum ActionName: Hashable, Codable, Sendable {
    case assigned
    case mentioned
    case reviewRequested
    case approvalRequired
    case buildFailed
    case marked
    case unmergeable
    case directlyAddressed
    case mergeTrainRemoved
    case addedApprovers
    case reviewSubmitted
    case okrCheckinRequested
    case memberAccessRequested
    case unknown(String)

    var rawValue: String {
        switch self {
        case .assigned: "assigned"
        case .mentioned: "mentioned"
        case .reviewRequested: "review_requested"
        case .approvalRequired: "approval_required"
        case .buildFailed: "build_failed"
        case .marked: "marked"
        case .unmergeable: "unmergeable"
        case .directlyAddressed: "directly_addressed"
        case .mergeTrainRemoved: "merge_train_removed"
        case .addedApprovers: "added_approver"
        case .reviewSubmitted: "review_submitted"
        case .okrCheckinRequested: "okr_checkin_requested"
        case .memberAccessRequested: "member_access_requested"
        case .unknown(let raw): raw
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "assigned": self = .assigned
        case "mentioned": self = .mentioned
        case "review_requested": self = .reviewRequested
        case "approval_required": self = .approvalRequired
        case "build_failed": self = .buildFailed
        case "marked": self = .marked
        case "unmergeable": self = .unmergeable
        case "directly_addressed": self = .directlyAddressed
        case "merge_train_removed": self = .mergeTrainRemoved
        case "added_approver", "added_approvers": self = .addedApprovers
        case "review_submitted": self = .reviewSubmitted
        case "okr_checkin_requested": self = .okrCheckinRequested
        case "member_access_requested": self = .memberAccessRequested
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

    var takesAuthorSlot: Bool {
        switch self {
        case .buildFailed, .unmergeable, .mergeTrainRemoved: false
        default: true
        }
    }

    var localizationKey: String {
        switch self {
        case .assigned: "action.assigned.%@"
        case .mentioned: "action.mentioned.%@"
        case .reviewRequested: "action.review_requested.%@"
        case .approvalRequired: "action.approval_required.%@"
        case .buildFailed: "action.build_failed"
        case .marked: "action.marked.%@"
        case .unmergeable: "action.unmergeable"
        case .directlyAddressed: "action.directly_addressed.%@"
        case .mergeTrainRemoved: "action.merge_train_removed"
        case .addedApprovers: "action.added_approvers.%@"
        case .reviewSubmitted: "action.review_submitted.%@"
        case .okrCheckinRequested: "action.okr_checkin_requested.%@"
        case .memberAccessRequested: "action.member_access_requested.%@"
        case .unknown: "action.unknown.%@"
        }
    }

    var selfLocalizationKey: String {
        switch self {
        case .assigned: "action.assigned.you"
        case .mentioned: "action.mentioned.you"
        case .reviewRequested: "action.review_requested.you"
        case .approvalRequired: "action.approval_required.you"
        case .marked: "action.marked.you"
        case .directlyAddressed: "action.directly_addressed.you"
        case .addedApprovers: "action.added_approvers.you"
        case .reviewSubmitted: "action.review_submitted.you"
        case .okrCheckinRequested: "action.okr_checkin_requested.you"
        case .memberAccessRequested: "action.member_access_requested.you"
        default: localizationKey
        }
    }
}
