import Foundation

/// Presentation-only positions retained across permission changes, never action evidence.
struct BoardPolicyOrder {
    struct Entry {
        let target: MRAutomationScope.Target
        let rank: Int
        let request: GitLabMergeRequest
        let discussionFingerprint: String?
        let jobID: UUID?
        let pinned: Bool
    }
    private(set) var preserved: [MergeRequestAttentionMonitor.Item.ID: Int] = [:]
    private var latest: [MRAutomationScope.Target: Entry] = [:]

    mutating func observe(_ entries: [Entry]) {
        let current = Dictionary(entries.map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
        preserved = positions(for: entries)
        latest = current
    }

    mutating func policyChanged(from previous: AutomationSettings, to current: AutomationSettings,
                                grouping: MRBoardGrouping = .withoutAutomation) {
        for entry in latest.values where entry.request.state == "opened" {
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: entry.target.projectID, iid: entry.request.iid)
            let isDraft = entry.request.draft == true || entry.request.detailedMergeStatus == "draft_status"
            let oldGroup = MRBoardActivity(automation: previous, target: entry.target, isDraft: isDraft, grouping: grouping).group
            let newGroup = MRBoardActivity(automation: current, target: entry.target, isDraft: isDraft, grouping: grouping).group
            // The explicit activity-section move takes precedence over the old absolute-position latch.
            if oldGroup != newGroup { preserved.removeValue(forKey: id); continue }
            func enabled(_ configuration: AutomationSettings) -> Bool {
                configuration.hasEnabledAutomation && configuration.scope.permits(entry.request,
                    host: entry.target.host, username: entry.target.username)
            }
            if enabled(previous) != enabled(current) {
                preserved[id] = entry.rank
            }
        }
    }

    func positions(for entries: [Entry]) -> [MergeRequestAttentionMonitor.Item.ID: Int] {
        var result: [MergeRequestAttentionMonitor.Item.ID: Int] = [:]
        for entry in entries where entry.request.state == "opened" {
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: entry.target.projectID, iid: entry.request.iid)
            guard let rank = preserved[id], let old = latest[entry.target],
                  old.discussionFingerprint == entry.discussionFingerprint, old.jobID == entry.jobID,
                  old.pinned == entry.pinned, Self.content(old.request) == Self.content(entry.request) else { continue }
            result[id] = rank
        }
        return result
    }

    private static func content(_ request: GitLabMergeRequest) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(request)
    }
}
