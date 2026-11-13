import Foundation
import Observation

/// Short-lived confirmation shown after the user switches automation globally or for one MR.
@MainActor
@Observable
final class AutomationToggleNoticeCenter {
    enum Kind: Equatable, Sendable {
        case global(active: Bool)
        case mergeRequest(iid: Int, projectPath: String?, active: Bool)
    }

    struct Notice: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: Kind
    }

    static let displayDuration: Duration = .seconds(4)

    /// Only the latest switch is relevant, so a new notice replaces the previous one.
    private(set) var current: Notice?

    func post(_ kind: Kind) { current = Notice(id: UUID(), kind: kind) }

    func dismiss(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}
