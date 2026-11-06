import Foundation

enum MRChatStatus: String, Codable, Sendable {
    case open, draft, closed, merged

    init?(request: GitLabMergeRequest) {
        switch request.state {
        case "merged": self = .merged
        case "closed": self = .closed
        case "opened":
            if request.draft == true || request.detailedMergeStatus == "draft_status" { self = .draft }
            else if request.draft == false { self = .open }
            else { return nil }
        default: return nil
        }
    }
}
