import Foundation

enum AssistantUsageGranularity: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month
    var id: Self { self }
    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

struct AssistantUsageChartBucket: Identifiable, Sendable {
    let start: Date
    let end: Date
    var codex = AssistantUsageTotal()
    var claude = AssistantUsageTotal()
    var id: Date { start }
    var overall: AssistantUsageTotal {
        var total = codex
        total.add(claude)
        return total
    }
}

struct AssistantUsageChartData: Sendable {
    var buckets: [AssistantUsageChartBucket] = []
    var totalBucketCount = 0
    var isTruncated: Bool { buckets.count < totalBucketCount }
}

extension AssistantUsageSnapshot {
    /// Scan receipts once and construct only the visible window, even for years of hours.
    func chartData(granularity: AssistantUsageGranularity, interval: DateInterval? = nil,
                   now: Date = Date(), limit: Int = 1000) -> AssistantUsageChartData {
        let calendar = AssistantUsageCalendar.utc
        let component = granularity.component
        guard let range = accountingRange(interval: interval, now: now, through: .hour),
              let first = calendar.dateInterval(of: component, for: range.start),
              let last = calendar.dateInterval(of: component, for: range.end.addingTimeInterval(-0.001)),
              let count = calendar.dateComponents([component], from: first.start, to: last.end).value(for: component),
              count > 0 else { return .init() }
        let shown = min(max(1, limit), count)
        guard let windowStart = calendar.date(byAdding: component, value: -shown, to: last.end) else { return .init() }
        var byBucket: [Date: AssistantUsageChartBucket] = [:]
        for entry in entries where Self.contains(entry.date, in: range) && entry.date >= windowStart {
            guard let bounds = calendar.dateInterval(of: component, for: entry.date) else { continue }
            var bucket = byBucket[bounds.start] ?? .init(start: bounds.start, end: bounds.end)
            if entry.assistant == .codex { bucket.codex.add(entry.total) }
            else { bucket.claude.add(entry.total) }
            byBucket[bounds.start] = bucket
        }
        var result = AssistantUsageChartData(totalBucketCount: count)
        var date = windowStart
        for _ in 0..<shown {
            guard let bounds = calendar.dateInterval(of: component, for: date), bounds.end > date else { break }
            result.buckets.append(byBucket[date] ?? .init(start: date, end: bounds.end))
            date = bounds.end
        }
        return result
    }
}
