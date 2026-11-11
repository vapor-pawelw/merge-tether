import Charts
import SwiftUI

struct AssistantUsageSettingsTab: View {
    @State private var snapshot: AssistantUsageSnapshot?
    @State private var period: AssistantUsagePeriod = .last30Days
    @State private var granularity: AssistantUsageGranularity = .day
    @State private var refreshID = UUID()
    @State private var boundaryRefreshID = UUID()
    @State private var loadFailed = false
    @State private var legacyTotal: AssistantUsageTotal?
    @State private var legacyLoadFailed = false
    @State private var summary = AssistantUsageSummary()
    @State private var chartData = AssistantUsageChartData()
    @State private var mergeRequestRanking: [AssistantUsageMergeRequestTotal] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(.AssistantUsage.assistantUsageDashboardTitle).font(.title2.weight(.semibold))
                    Spacer()
                    Picker(selection: $period) {
                        ForEach(AssistantUsagePeriod.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    } label: { Text(.AssistantUsage.assistantUsagePeriod) }
                        .fixedSize()
                }

                if loadFailed {
                    Label { Text(.AssistantUsage.assistantUsageUnavailable) } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                if let snapshot {
                    dashboard(summary, chartData: chartData)
                    trackingFooter(snapshot)
                } else if !loadFailed {
                    ProgressView().frame(maxWidth: .infinity)
                }

                if let legacyTotal {
                    VStack(alignment: .leading, spacing: 8) {
                        AssistantUsageTotalCard(title: .AssistantUsage.assistantUsageLegacyTitle,
                            detail: .AssistantUsage.assistantUsageLegacyHelp, total: legacyTotal)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([InstallationStorage.current.legacy.usageFile])
                        } label: { Text(.AssistantUsage.assistantUsageLegacySource) }
                    }
                } else if legacyLoadFailed {
                    Label { Text(.AssistantUsage.assistantUsageLegacyUnavailable) } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                estimateExplanation
            }
            .padding(20)
        }
        .task(id: refreshID) { await refresh() }
        .task(id: boundaryRefreshID) { await refreshAtBoundaries() }
        .onChange(of: period) { _, _ in rebuildSummary() }
        .onChange(of: granularity) { _, _ in rebuildChart() }
        .onReceive(NotificationCenter.default.publisher(for: AssistantUsageStore.didChange).receive(on: RunLoop.main)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshForClockChange() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange).receive(on: RunLoop.main)) { _ in refreshForClockChange() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main)) { _ in
            refreshForClockChange()
        }
    }

    private func dashboard(_ summary: AssistantUsageSummary, chartData: AssistantUsageChartData) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                AssistantUsageTotalCard(title: .AssistantUsage.assistantUsageOverall,
                    detail: .AssistantUsage.assistantUsageAppOnly, total: summary.overall)
                VStack(alignment: .leading, spacing: 6) {
                    Text(.AssistantUsage.assistantUsageAverageDaily).font(.headline)
                    if let average = summary.averageDailyUSD {
                        AssistantUsageAmount(value: average).font(.title3.weight(.semibold))
                    } else {
                        Text(.AssistantUsage.assistantUsageCostUnavailable).foregroundStyle(.secondary)
                    }
                    Text(.AssistantUsage.assistantUsageCoveredDays(summary.coveredDays))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(.AssistantUsage.assistantUsageAverageHelp).font(.caption).foregroundStyle(.secondary)
                    if summary.overall.unknownCostRuns > 0 {
                        Text(.AssistantUsage.assistantUsageAveragePartial(summary.overall.unknownCostRuns))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(alignment: .top, spacing: 12) {
                AssistantUsageTotalCard(title: .AssistantUsage.assistantUsageCodingAgent,
                    detail: .AssistantUsage.assistantUsageCodingAgentDetail, total: summary.codingAgent)
                AssistantUsageTotalCard(title: .AssistantUsage.assistantUsageVerification,
                    detail: .AssistantUsage.assistantUsageVerificationDetail, total: summary.verifier)
            }

            if !chartData.buckets.isEmpty {
                AssistantUsageProviderChart(data: chartData, granularity: $granularity)
            }
            AssistantUsageMergeRequestRanking(rows: mergeRequestRanking)
            if !summary.days.isEmpty {
                AssistantUsageDailyHistory(days: summary.days)
            }
        }
    }

    private func trackingFooter(_ snapshot: AssistantUsageSnapshot) -> some View {
        Group {
            if let date = snapshot.startedAt {
                Text(.AssistantUsage.assistantUsageTrackingSince(AssistantUsagePeriod.dateLabel(date)))
            } else {
                Text(.AssistantUsage.assistantUsageTrackingStarts)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var estimateExplanation: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(.AssistantUsage.assistantUsageEstimateHelp)
                Text(.AssistantUsage.assistantUsageScopeHelp)
                Text(.AssistantUsage.assistantUsageUnknownHelp)
                Link(destination: CodexUsagePricing.source) { Text(.AssistantUsage.assistantUsagePricingSource) }
            }
            .font(.caption).foregroundStyle(.secondary)
        } label: { Text(.AssistantUsage.assistantUsageEstimateExplanation) }
    }

    // Hover state belongs to the chart child. History scans happen only after
    // a new snapshot or a deliberate range/granularity change.
    private func rebuildSummary() {
        guard let snapshot else { return }
        let now = Date()
        let interval = period.interval(at: now)
        summary = snapshot.summary(interval: interval, now: now)
        chartData = snapshot.chartData(granularity: granularity, interval: interval, now: now)
        mergeRequestRanking = Array(snapshot.mergeRequestTotals(interval: interval, now: now)
            .filter { $0.total.hasKnownEstimate }.prefix(5))
    }

    private func rebuildChart() {
        guard let snapshot else { return }
        let now = Date()
        chartData = snapshot.chartData(granularity: granularity, interval: period.interval(at: now), now: now)
    }

    private func refreshForClockChange() {
        rebuildSummary()
        refreshID = UUID()
        boundaryRefreshID = UUID()
    }

    private func refreshAtBoundaries() async {
        while !Task.isCancelled {
            let next = AssistantUsageRefreshPolicy.nextBoundary(after: Date())
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            rebuildSummary()
        }
    }

    private func refresh() async {
        if legacyTotal == nil {
            do {
                let legacy = try await Task.detached { try AssistantUsageStore.legacySharedSnapshot() }.value
                guard !Task.isCancelled else { return }
                legacyTotal = legacy?.summary().overall
                legacyLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                legacyLoadFailed = true
            }
        }
        do {
            let current = try await AssistantUsageStore.shared.snapshot()
            guard !Task.isCancelled else { return }
            snapshot = current
            rebuildSummary()
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}

private struct AssistantUsageTotalCard: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let total: AssistantUsageTotal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            AssistantUsageTotalAmount(total: total).font(.title3.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text(.AssistantUsage.assistantUsageRuns(total.runs)).font(.caption).foregroundStyle(.secondary)
            if total.unknownCostRuns > 0 {
                Text(.AssistantUsage.assistantUsageUnknownRuns(total.unknownCostRuns))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if total.inputTokens > 0 || total.outputTokens > 0 {
                Text(.AssistantUsage.assistantUsageTokens(total.inputTokens, total.cachedInputTokens, total.outputTokens))
                    .font(.caption).foregroundStyle(.secondary)
                if total.tokensUnavailable == true {
                    Text(.AssistantUsage.assistantUsageTokensPartial).font(.caption).foregroundStyle(.secondary)
                }
            } else if total.tokensUnavailable == true {
                Text(.AssistantUsage.assistantUsageTokensUnavailable).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
    }
}

private struct AssistantUsageProviderChart: View {
    let data: AssistantUsageChartData
    @Binding var granularity: AssistantUsageGranularity
    private var codexLabel: String { String(localized: .AssistantUsage.assistantUsageCodexCLI) }
    private var claudeLabel: String { String(localized: .AssistantUsage.assistantUsageClaudeCLI) }
    private var xDomain: ClosedRange<Date> {
        (data.buckets.first?.start ?? Date())...(data.buckets.last?.end ?? Date())
    }
    private var chartCalendar: Calendar {
        var calendar = AssistantUsageCalendar.utc
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    private var calendarComponent: Calendar.Component {
        switch granularity {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(.AssistantUsage.assistantUsageChartTitle).font(.headline)
                Spacer()
                Picker(selection: $granularity) {
                    Text(.AssistantUsage.assistantUsageHours).tag(AssistantUsageGranularity.hour)
                    Text(.AssistantUsage.assistantUsageDays).tag(AssistantUsageGranularity.day)
                    Text(.AssistantUsage.assistantUsageWeeks).tag(AssistantUsageGranularity.week)
                    Text(.AssistantUsage.assistantUsageMonths).tag(AssistantUsageGranularity.month)
                } label: { Text(.AssistantUsage.assistantUsageGranularity) }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
            }
            chart.frame(height: 220)
            if data.isTruncated {
                Text(.AssistantUsage.assistantUsageChartTruncated(data.buckets.count, data.totalBucketCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(.AssistantUsage.assistantUsageChartHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data.buckets) { bucket in
                if bucket.overall.costUnavailable != true && bucket.codex.hasKnownEstimate {
                    BarMark(x: .value(String(localized: .AssistantUsage.assistantUsageTime), bucket.start,
                        unit: calendarComponent, calendar: chartCalendar),
                        y: .value(String(localized: .AssistantUsage.assistantUsageEstimatedUSD), bucket.codex.estimatedUSD), width: .ratio(0.85))
                    .foregroundStyle(by: .value(String(localized: .AssistantUsage.assistantUsageProvider), codexLabel))
                }
                if bucket.overall.costUnavailable != true && bucket.claude.hasKnownEstimate {
                    BarMark(x: .value(String(localized: .AssistantUsage.assistantUsageTime), bucket.start,
                        unit: calendarComponent, calendar: chartCalendar),
                        y: .value(String(localized: .AssistantUsage.assistantUsageEstimatedUSD), bucket.claude.estimatedUSD), width: .ratio(0.85))
                    .foregroundStyle(by: .value(String(localized: .AssistantUsage.assistantUsageProvider), claudeLabel))
                }
                if bucket.overall.unknownCostRuns > 0 || bucket.overall.costUnavailable == true {
                    RuleMark(x: .value(String(localized: .AssistantUsage.assistantUsageTime), midpoint(bucket)))
                        .foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                        .accessibilityLabel(Text(.AssistantUsage.assistantUsageUnknownDay))
                }
            }
        }
        .chartForegroundStyleScale(domain: [codexLabel, claudeLabel], range: [Color.blue, Color.teal])
        .chartYAxisLabel(String(localized: .AssistantUsage.assistantUsageEstimatedUSD))
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: AssistantUsagePeriod.shortDateLabel(date, includeTime: granularity == .hour))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            AssistantUsageChartHoverOverlay(proxy: proxy, buckets: data.buckets)
        }
        .environment(\.calendar, chartCalendar)
        .environment(\.timeZone, chartCalendar.timeZone)
    }

    private func midpoint(_ bucket: AssistantUsageChartBucket) -> Date {
        bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)
    }
}

/// Pointer movement invalidates only this overlay, keeping all chart marks stable.
private struct AssistantUsageChartHoverOverlay: View {
    let proxy: ChartProxy
    let buckets: [AssistantUsageChartBucket]
    @State private var selectedStart: Date?
    private var selectedBucket: AssistantUsageChartBucket? { buckets.first { $0.start == selectedStart } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { select(nil); return }
                            let frame = geometry[anchor]
                            guard frame.contains(location),
                                  let date = proxy.value(atX: location.x - frame.minX, as: Date.self) else {
                                select(nil)
                                return
                            }
                            select(buckets.first { $0.start <= date && date < $0.end }?.start)
                        case .ended:
                            select(nil)
                        }
                    }
                if let bucket = selectedBucket {
                    if let anchor = proxy.plotFrame,
                       let x = proxy.position(forX: bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)) {
                        let frame = geometry[anchor]
                        Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 1, height: frame.height)
                            .position(x: frame.minX + x, y: frame.midY).allowsHitTesting(false)
                    }
                    AssistantUsageBucketTooltip(bucket: bucket)
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 3).padding(8).allowsHitTesting(false)
                }
            }
        }
    }

    private func select(_ start: Date?) {
        if selectedStart != start { selectedStart = start }
    }
}

private struct AssistantUsageBucketTooltip: View {
    let bucket: AssistantUsageChartBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.AssistantUsage.assistantUsageBucketRange(AssistantUsagePeriod.dateTimeLabel(bucket.start),
                AssistantUsagePeriod.dateTimeLabel(bucket.end))).font(.caption.weight(.medium))
            amountRow(.AssistantUsage.assistantUsageOverall, total: bucket.overall)
            Divider()
            amountRow(.AssistantUsage.assistantUsageCodexCLI, total: bucket.codex)
            amountRow(.AssistantUsage.assistantUsageClaudeCLI, total: bucket.claude)
        }
        .frame(maxWidth: 310).textSelection(.enabled)
    }
    private func amountRow(_ label: LocalizedStringResource, total: AssistantUsageTotal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 12)
                AssistantUsageTotalAmount(total: total, noActivity: true, precise: true)
            }
            if total.unknownCostRuns > 0 {
                Text(.AssistantUsage.assistantUsageUnknownRuns(total.unknownCostRuns)).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private struct AssistantUsageDailyHistory: View {
    let days: [AssistantUsageDay]

    var body: some View {
        DisclosureGroup {
            LazyVStack(spacing: 10) {
                HStack {
                    Text(.AssistantUsage.assistantUsageDay).frame(width: 110, alignment: .leading)
                    Text(.AssistantUsage.assistantUsageCodingAgent).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(.AssistantUsage.assistantUsageVerification).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(.AssistantUsage.assistantUsageOverall).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(days.reversed(), id: \.date) { day in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: AssistantUsagePeriod.dateLabel(day.date)).frame(width: 110, alignment: .leading)
                            AssistantUsageTotalAmount(total: day.codingAgent, noActivity: true)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            AssistantUsageTotalAmount(total: day.verifier, noActivity: true)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            AssistantUsageTotalAmount(total: day.overall, noActivity: true)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.caption).monospacedDigit()
                        if day.overall.unknownCostRuns > 0 {
                            Text(.AssistantUsage.assistantUsageUnknownRuns(day.overall.unknownCostRuns))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }
            .padding(.top, 8).textSelection(.enabled)
        } label: { Text(.AssistantUsage.assistantUsageDailyHistory) }
    }
}

struct AssistantUsageTotalAmount: View {
    let total: AssistantUsageTotal
    var noActivity = false
    var precise = false

    var body: some View {
        Group {
            if total.runs == 0 {
                Text(noActivity ? .AssistantUsage.assistantUsageNoActivity : .AssistantUsage.assistantUsageNoRuns)
                    .foregroundStyle(.secondary)
            } else if !total.hasKnownEstimate {
                Text(.AssistantUsage.assistantUsageCostUnavailable).foregroundStyle(.secondary)
            } else {
                AssistantUsageAmount(value: total.estimatedUSD, precise: precise)
            }
        }
        .monospacedDigit()
    }
}

struct AssistantUsageAmount: View {
    let value: Double
    var precise = false
    private var threshold: Double { precise ? 0.00000001 : 0.0001 }
    var body: some View {
        if value > 0 && value < threshold {
            Text(.AssistantUsage.assistantUsageEstimateBelow(usd(threshold)))
        } else {
            Text(.AssistantUsage.assistantUsageEstimate(usd(value)))
        }
    }
    private func usd(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(precise ? 8 : 4)))
    }
}

private struct AssistantUsageMergeRequestRanking: View {
    let rows: [AssistantUsageMergeRequestTotal]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.AssistantUsage.assistantUsageMRRankingTitle).font(.headline)
            Text(.AssistantUsage.assistantUsageMRRankingHelp)
                .font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(.AssistantUsage.assistantUsageMRRankingEmpty)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "\(index + 1).")
                            .foregroundStyle(.secondary).monospacedDigit().frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            if let urlString = row.mergeRequest.url, let url = URL(string: urlString) {
                                Link(destination: url) {
                                    Text(verbatim: "!\(row.mergeRequest.iid) · \(row.mergeRequest.title ?? row.mergeRequest.id)")
                                        .lineLimit(1)
                                }
                            } else {
                                Text(verbatim: "!\(row.mergeRequest.iid) · \(row.mergeRequest.title ?? row.mergeRequest.id)")
                                    .lineLimit(1)
                            }
                            if row.total.unknownCostRuns > 0 {
                                Text(.AssistantUsage.assistantUsageMRUnknownRuns(row.total.unknownCostRuns))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        AssistantUsageTotalAmount(total: row.total, precise: true)
                    }
                    .font(.subheadline)
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension AssistantUsageTotal {
    var hasKnownEstimate: Bool {
        costUnavailable != true && runs > 0 && (estimatedUSD > 0 || unknownCostRuns < runs)
    }
}

private enum AssistantUsagePeriod: CaseIterable, Identifiable {
    case today, last7Days, last30Days, thisMonth, allTracked
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .today: .AssistantUsage.assistantUsageToday
        case .last7Days: .AssistantUsage.assistantUsageLast7Days
        case .last30Days: .AssistantUsage.assistantUsageLast30Days
        case .thisMonth: .AssistantUsage.assistantUsageThisMonth
        case .allTracked: .AssistantUsage.assistantUsageAllTracked
        }
    }
    func interval(at now: Date) -> DateInterval? {
        let calendar = AssistantUsageCalendar.utc
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        switch self {
        case .today: return DateInterval(start: start, end: end)
        case .last7Days: return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: start)!, end: end)
        case .last30Days: return DateInterval(start: calendar.date(byAdding: .day, value: -29, to: start)!, end: end)
        case .thisMonth: return AssistantUsageCalendar.month(containing: now)
        case .allTracked: return nil
        }
    }
    static func dateLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
            calendar: AssistantUsageCalendar.utc, timeZone: AssistantUsageCalendar.utc.timeZone))
    }
    static func dateTimeLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
            calendar: AssistantUsageCalendar.utc, timeZone: AssistantUsageCalendar.utc.timeZone))
    }
    static func shortDateLabel(_ date: Date, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = AssistantUsageCalendar.utc
        formatter.timeZone = AssistantUsageCalendar.utc.timeZone
        formatter.setLocalizedDateFormatFromTemplate(includeTime ? "MMMdHHmm" : "MMMd")
        return formatter.string(from: date)
    }
}
