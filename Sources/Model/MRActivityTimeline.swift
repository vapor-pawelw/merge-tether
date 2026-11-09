import Foundation

/// Session-local identity for a displayed stage; separate runs never share a timer.
struct MRActivity: Equatable {
    let status: String
    var jobID: UUID? = nil
    var startedAt: Date? = nil

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        if seconds < 60 { return String(localized: .AutomationProgress.progressElapsedSeconds(seconds)) }
        if seconds < 3_600 {
            return String(localized: .AutomationProgress.progressElapsedMinutes(seconds / 60, seconds % 60))
        }
        return String(localized: .AutomationProgress.progressElapsedHours(seconds / 3_600, seconds % 3_600 / 60))
    }
}

/// Owned by the monitor, so card redraws and opening Details cannot restart a stage.
struct MRActivityTimeline: Equatable {
    private struct Entry: Equatable {
        let activity: MRActivity
        let startedAt: Date
    }
    private var entries: [MRAutomationScope.Target: Entry] = [:]

    mutating func update(_ activities: [MRAutomationScope.Target: MRActivity], now: Date = Date()) {
        entries = activities.reduce(into: [:]) { updated, pair in
            let (target, activity) = pair
            if let previous = entries[target], previous.activity == activity {
                updated[target] = previous
            } else {
                updated[target] = Entry(activity: activity, startedAt: activity.startedAt ?? now)
            }
        }
    }

    func startedAt(for target: MRAutomationScope.Target, activity: MRActivity) -> Date? {
        guard entries[target]?.activity == activity else { return nil }
        return entries[target]?.startedAt
    }
}
