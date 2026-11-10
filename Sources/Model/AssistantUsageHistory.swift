import Foundation

struct AssistantUsageTotal: Codable, Equatable, Sendable {
    var runs = 0
    var estimatedUSD = 0.0
    var unknownCostRuns = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    var tokensUnavailable: Bool?
    var costUnavailable: Bool?

    mutating func add(_ other: Self) {
        let runCount = runs.addingReportingOverflow(other.runs)
        let unknownCount = unknownCostRuns.addingReportingOverflow(other.unknownCostRuns)
        runs = runCount.overflow ? Int.max : runCount.partialValue
        unknownCostRuns = unknownCount.overflow ? Int.max : unknownCount.partialValue
        let dollars = estimatedUSD + other.estimatedUSD
        if costUnavailable == true || other.costUnavailable == true || !dollars.isFinite
            || dollars < 0 || runCount.overflow || unknownCount.overflow {
            costUnavailable = true
            estimatedUSD = 0
            unknownCostRuns = runs
        } else { estimatedUSD = dollars }
        let input = inputTokens.addingReportingOverflow(other.inputTokens)
        let cached = cachedInputTokens.addingReportingOverflow(other.cachedInputTokens)
        let output = outputTokens.addingReportingOverflow(other.outputTokens)
        if other.tokensUnavailable == true { tokensUnavailable = true }
        if input.overflow || cached.overflow || output.overflow
            || input.partialValue < 0 || cached.partialValue < 0 || output.partialValue < 0 {
            tokensUnavailable = true
            inputTokens = 0
            cachedInputTokens = 0
            outputTokens = 0
        } else {
            inputTokens = input.partialValue
            cachedInputTokens = cached.partialValue
            outputTokens = output.partialValue
        }
    }
}

struct AssistantUsageEntry: Sendable {
    let date: Date
    let role: AssistantUsageRole
    let assistant: AutomationAssistant
    let total: AssistantUsageTotal
    var mergeRequest: AssistantUsageMergeRequest? = nil
}

struct AssistantUsageMergeRequestTotal: Identifiable, Sendable {
    let mergeRequest: AssistantUsageMergeRequest
    var total: AssistantUsageTotal
    var id: String { mergeRequest.id }
}

struct AssistantUsageSnapshot: Sendable {
    var startedAt: Date?
    var entries: [AssistantUsageEntry] = []

    func total(for role: AssistantUsageRole, assistant: AutomationAssistant? = nil, interval: DateInterval? = nil) -> AssistantUsageTotal {
        var result = AssistantUsageTotal()
        for entry in entries where entry.role == role && (assistant == nil || entry.assistant == assistant)
            && Self.contains(entry.date, in: interval) {
            result.add(entry.total)
        }
        return result
    }

    func total(for mergeRequest: AssistantUsageMergeRequest, role: AssistantUsageRole? = nil) -> AssistantUsageTotal {
        var result = AssistantUsageTotal()
        for entry in entries where entry.mergeRequest?.id == mergeRequest.id && (role == nil || entry.role == role) {
            result.add(entry.total)
        }
        return result
    }

    func mergeRequestTotals(interval: DateInterval?, now: Date = Date()) -> [AssistantUsageMergeRequestTotal] {
        guard let range = accountingRange(interval: interval, now: now, through: .hour) else { return [] }
        var totals: [String: AssistantUsageMergeRequestTotal] = [:]
        for entry in entries where Self.contains(entry.date, in: range) {
            guard let mergeRequest = entry.mergeRequest else { continue }
            var value = totals[mergeRequest.id] ?? .init(mergeRequest: mergeRequest, total: .init())
            value.total.add(entry.total)
            if mergeRequest.title != nil || mergeRequest.url != nil { value = .init(mergeRequest: mergeRequest, total: value.total) }
            totals[mergeRequest.id] = value
        }
        return totals.values.sorted {
            if $0.total.estimatedUSD != $1.total.estimatedUSD { return $0.total.estimatedUSD > $1.total.estimatedUSD }
            return $0.id < $1.id
        }
    }

    func summary(interval: DateInterval? = nil, now: Date = Date()) -> AssistantUsageSummary {
        guard let range = accountingRange(interval: interval, now: now, through: .day) else { return .init() }
        let calendar = AssistantUsageCalendar.utc
        var byDay: [Date: AssistantUsageDay] = [:]
        for entry in entries where Self.contains(entry.date, in: range) {
            let date = calendar.startOfDay(for: entry.date)
            var day = byDay[date] ?? .init(date: date)
            if entry.role == .codingAgent { day.codingAgent.add(entry.total) }
            else { day.verifier.add(entry.total) }
            byDay[date] = day
        }
        var result = AssistantUsageSummary()
        var date = calendar.startOfDay(for: range.start)
        while date < range.end {
            let day = byDay[date] ?? .init(date: date)
            result.days.append(day)
            result.codingAgent.add(day.codingAgent)
            result.verifier.add(day.verifier)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        result.coveredDays = result.days.count
        return result
    }

    // User ranges use UTC hour/day boundaries. Old receipts retain hour precision.
    func accountingRange(interval: DateInterval?, now: Date, through component: Calendar.Component) -> DateInterval? {
        let calendar = AssistantUsageCalendar.utc
        guard let startedAt, let firstHour = calendar.dateInterval(of: .hour, for: startedAt),
              let current = calendar.dateInterval(of: component, for: now) else { return nil }
        let start = max(firstHour.start, interval?.start ?? firstHour.start)
        let end = min(current.end, interval?.end ?? current.end)
        guard start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    static func contains(_ date: Date, in interval: DateInterval?) -> Bool {
        guard let interval else { return true }
        return date >= interval.start && date < interval.end
    }
}

struct AssistantUsageDay: Identifiable, Sendable {
    let date: Date
    var codingAgent = AssistantUsageTotal()
    var verifier = AssistantUsageTotal()
    var id: Date { date }
    var overall: AssistantUsageTotal {
        var total = codingAgent
        total.add(verifier)
        return total
    }
}

struct AssistantUsageSummary: Sendable {
    var codingAgent = AssistantUsageTotal()
    var verifier = AssistantUsageTotal()
    var coveredDays = 0
    var days: [AssistantUsageDay] = []
    var overall: AssistantUsageTotal {
        var total = codingAgent
        total.add(verifier)
        return total
    }
    var averageDailyUSD: Double? {
        let total = overall
        guard coveredDays > 0, total.costUnavailable != true else { return nil }
        guard total.runs == 0 || total.estimatedUSD > 0 || total.unknownCostRuns < total.runs else { return nil }
        return total.estimatedUSD / Double(coveredDays)
    }
}

enum AssistantUsageCalendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    static func month(containing date: Date) -> DateInterval? { utc.dateInterval(of: .month, for: date) }
}

enum AssistantUsageRefreshPolicy {
    static func nextBoundary(after date: Date) -> Date {
        AssistantUsageCalendar.utc.dateInterval(of: .hour, for: date)?.end ?? date.addingTimeInterval(3_600)
    }
}
