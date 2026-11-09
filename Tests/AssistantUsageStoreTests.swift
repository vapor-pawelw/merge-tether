import Foundation
import Testing
@testable import GitLabTodos

@Suite("Assistant usage persistence")
struct AssistantUsageStoreTests {
    @Test("Compacted MR costs retain display metadata and coding/verifier totals after restart")
    func compactedMergeRequestCostsPreserveMetadataAndTotals() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        let original = usageMR(title: "Original MR title")
        let updated = usageMR(title: "Updated MR title")
        let otherAccount = usageMR(username: "another", title: "Other account's MR")
        try await record(store, at: "2026-11-04T08:05:00Z", role: .codingAgent, cost: 1, mergeRequest: original)
        try await record(store, at: "2026-11-04T08:10:00Z", role: .codingAgent, cost: 2, mergeRequest: updated)
        try await record(store, at: "2026-11-04T08:15:00Z", role: .codingAgent, cost: 4, mergeRequest: otherAccount)
        try await record(store, at: "2026-11-04T08:20:00Z", role: .verifier, cost: 8, assistant: .codex, mergeRequest: updated)
        try await record(store, at: "2026-11-04T08:25:00Z", role: .codingAgent, cost: 16)

        let restarted = AssistantUsageStore(file: file, receiptLimit: 1)
        let snapshot = try await restarted.snapshot()
        let lifetime = snapshot.total(for: original)
        #expect(lifetime.estimatedUSD == 11 && lifetime.runs == 3 && lifetime.unknownCostRuns == 0)
        #expect(snapshot.total(for: otherAccount).estimatedUSD == 4)
        let ranking = snapshot.mergeRequestTotals(interval: nil, now: try instant("2026-11-04T12:00:00Z"))
        #expect(ranking.map(\.id) == [original.id, otherAccount.id])
        #expect(ranking.first?.mergeRequest.title == updated.title)
        #expect(ranking.first?.mergeRequest.url == updated.url)
        let chart = snapshot.chartData(granularity: .hour, now: try instant("2026-11-04T12:00:00Z"))
        #expect(chart.buckets.first?.overall.estimatedUSD == 31)
        #expect(snapshot.total(for: .codingAgent).estimatedUSD == 23 && snapshot.total(for: .verifier).estimatedUSD == 8)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((json["receipts"] as? [Any])?.count == 1)
        #expect((json["archived"] as? [Any])?.count == 3)
    }

    @Test("Hourly compaction never merges distinct MR account, host, project or IID identities")
    func compactedMergeRequestsKeepEveryIdentityAxis() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        let identities = [usageMR(), usageMR(host: "other.example.test"), usageMR(username: "another"),
            usageMR(projectID: 8), usageMR(iid: 12), usageMR(username: nil)]
        for (index, identity) in identities.enumerated() {
            try await record(store, at: "2026-11-04T08:05:00Z", role: .codingAgent,
                cost: Double(1 << index), mergeRequest: identity)
        }
        try await record(store, at: "2026-11-04T08:06:00Z", role: .codingAgent, cost: 64)
        let snapshot = try await AssistantUsageStore(file: file, receiptLimit: 1).snapshot()
        for (index, identity) in identities.enumerated() {
            let total = snapshot.total(for: identity)
            #expect(total.runs == 1 && total.estimatedUSD == Double(1 << index))
        }
        #expect(snapshot.mergeRequestTotals(interval: nil, now: try instant("2026-11-04T12:00:00Z")).count == 6)
        #expect(snapshot.total(for: .codingAgent).estimatedUSD == 127)
    }

    @Test("Legacy receipts and archives without MR metadata stay unattributed through later writes")
    func legacyUsageJSONDoesNotAssignOldCostsToNewMR() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let date = try instant("2026-11-04T08:00:00Z")
        let oldState: [String: Any] = [
            "version": 1, "startedAt": date.timeIntervalSinceReferenceDate,
            "receipts": [["id": UUID().uuidString, "date": date.timeIntervalSinceReferenceDate,
                "role": "codingAgent", "assistant": "claude", "finished": true, "complete": true,
                "measurement": ["estimatedUSD": 2, "pricingVersion": "claude-cli"]]],
            "archived": [["hour": date.timeIntervalSinceReferenceDate, "role": "codingAgent", "assistant": "claude",
                "pricingVersion": "claude-cli", "total": ["runs": 1, "estimatedUSD": 3, "unknownCostRuns": 0,
                    "inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0]]]
        ]
        try JSONSerialization.data(withJSONObject: oldState).write(to: file)
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        let legacy = try await store.snapshot()
        let target = usageMR()
        #expect(legacy.total(for: .codingAgent).estimatedUSD == 5)
        #expect(legacy.entries.allSatisfy { $0.mergeRequest == nil })
        #expect(legacy.total(for: target).runs == 0)
        #expect(legacy.mergeRequestTotals(interval: nil, now: try instant("2026-11-04T12:00:00Z")).isEmpty)
        try await record(store, at: "2026-11-04T08:05:00Z", role: .codingAgent, cost: 4, mergeRequest: target)
        let persisted = try await AssistantUsageStore(file: file, receiptLimit: 1).snapshot()
        #expect(persisted.total(for: .codingAgent).estimatedUSD == 9)
        #expect(persisted.total(for: target).estimatedUSD == 4 && persisted.total(for: target).runs == 1)
        #expect(persisted.mergeRequestTotals(interval: nil, now: try instant("2026-11-04T12:00:00Z")).map(\.id) == [target.id])
    }

    @Test("Idle dashboard refresh waits for the next UTC hour, including day and month boundaries")
    func dashboardRefreshBoundaries() throws {
        for (input, expected) in [
            ("2026-11-08T12:34:56Z", "2026-11-08T13:00:00Z"),
            ("2026-11-08T13:00:00Z", "2026-11-08T14:00:00Z"),
            ("2026-11-30T23:59:59Z", "2026-12-01T00:00:00Z"),
        ] {
            let date = try instant(input)
            let next = AssistantUsageRefreshPolicy.nextBoundary(after: date)
            #expect(next == (try instant(expected)))
            #expect(next > date)
        }
    }

    @Test("A cost receipt without token usage never makes aggregate token counts look complete")
    func missingTokenUsage() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        try await record(store, at: "2026-11-02T08:00:00Z", role: .codingAgent, cost: 1)
        let total = try await store.snapshot().total(for: .codingAgent)
        #expect(total.estimatedUSD == 1)
        #expect(total.tokensUnavailable == true)
    }

    @Test("Accounting ranges are half-open so an exact boundary is counted only in its next bucket")
    func halfOpenIntervals() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        try await record(store, at: "2026-11-02T08:00:00Z", role: .codingAgent, cost: 2)
        try await record(store, at: "2026-11-02T09:00:00Z", role: .codingAgent, cost: 3)
        let first = DateInterval(start: try instant("2026-11-02T08:00:00Z"), end: try instant("2026-11-02T09:00:00Z"))
        let second = DateInterval(start: try instant("2026-11-02T09:00:00Z"), end: try instant("2026-11-02T10:00:00Z"))
        let snapshot = try await store.snapshot()
        #expect(snapshot.total(for: .codingAgent, interval: first).estimatedUSD == 2)
        #expect(snapshot.total(for: .codingAgent, interval: second).estimatedUSD == 3)
    }

    @Test("Hourly archive preserves provider and role totals at UTC hour boundaries")
    func hourlyProviderHistory() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        try await record(store, at: "2026-11-02T08:05:00Z", role: .codingAgent, cost: 1, assistant: .codex)
        try await record(store, at: "2026-11-02T08:50:00Z", role: .codingAgent, cost: 2)
        try await record(store, at: "2026-11-02T09:00:00Z", role: .verifier, cost: 3)
        try await record(store, at: "2026-11-03T08:00:00Z", role: .verifier, cost: 4, assistant: .codex)
        let snapshot = try await store.snapshot()
        #expect(snapshot.total(for: .codingAgent, assistant: .codex).estimatedUSD == 1)
        #expect(snapshot.total(for: .codingAgent, assistant: .claude).estimatedUSD == 2)
        #expect(snapshot.total(for: .verifier, assistant: .codex).estimatedUSD == 4)
        let interval = DateInterval(start: try instant("2026-11-02T08:00:00Z"), end: try instant("2026-11-02T10:00:00Z"))
        let chart = snapshot.chartData(granularity: .hour, interval: interval, now: try instant("2026-11-03T12:00:00Z"))
        #expect(chart.totalBucketCount == 2 && !chart.isTruncated)
        #expect(chart.buckets.map(\.codex.estimatedUSD) == [1, 0])
        #expect(chart.buckets.map(\.claude.estimatedUSD) == [2, 3])
        #expect(chart.buckets.map(\.overall.estimatedUSD) == [3, 3])
        #expect(chart.buckets.map(\.start) == [try instant("2026-11-02T08:00:00Z"), try instant("2026-11-02T09:00:00Z")])
    }

    @Test("Provider chart rolls UTC hours into days, ISO weeks and months")
    func chartGranularities() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        try await record(store, at: "2026-11-01T23:59:00Z", role: .codingAgent, cost: 2, assistant: .codex)
        try await record(store, at: "2026-11-02T00:00:00Z", role: .verifier, cost: 3)
        let snapshot = try await store.snapshot()
        let now = try instant("2026-11-02T00:30:00Z")
        let daily = snapshot.chartData(granularity: .day, now: now)
        #expect(daily.buckets.map(\.overall.estimatedUSD) == [2, 3])
        let weekly = snapshot.chartData(granularity: .week, now: now)
        #expect(weekly.buckets.map(\.start) == [try instant("2026-10-26T00:00:00Z"), try instant("2026-11-02T00:00:00Z")])
        #expect(weekly.buckets.map(\.overall.estimatedUSD) == [2, 3])
        let monthly = snapshot.chartData(granularity: .month, now: now)
        #expect(monthly.buckets.count == 1 && monthly.buckets.first?.overall.estimatedUSD == 5)
        #expect(monthly.buckets.first?.start == (try instant("2026-11-01T00:00:00Z")))
    }

    @Test("Hourly chart windows large ranges without changing full-range daily summaries")
    func chartWindowAndUnknowns() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        try await record(store, at: "2026-11-02T08:05:00Z", role: .codingAgent, cost: 1, assistant: .codex)
        try await record(store, at: "2026-11-02T09:05:00Z", role: .verifier, cost: nil)
        let snapshot = try await store.snapshot()
        let now = try instant("2026-11-02T12:30:00Z")
        let full = snapshot.chartData(granularity: .hour, now: now)
        #expect(full.totalBucketCount == 5 && full.buckets.count == 5)
        #expect(full.buckets.map(\.overall.runs) == [1, 1, 0, 0, 0])
        #expect(full.buckets.dropFirst().first?.claude.unknownCostRuns == 1)
        let window = snapshot.chartData(granularity: .hour, now: now, limit: 2)
        #expect(window.isTruncated && window.totalBucketCount == 5 && window.buckets.count == 2)
        #expect(window.buckets.first?.start == (try instant("2026-11-02T11:00:00Z")))
        let summary = snapshot.summary(now: now)
        #expect(summary.overall.estimatedUSD == 1 && summary.overall.unknownCostRuns == 1 && summary.coveredDays == 1)
    }

    @Test("Daily summaries include zero-activity UTC days and average only days covered by tracking")
    func dailySummaryCoverage() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        try await record(store, at: "2026-11-02T12:00:00Z", role: .codingAgent, cost: 6)
        try await record(store, at: "2026-11-04T20:00:00Z", role: .verifier, cost: 3)
        let snapshot = try await store.snapshot()
        let now = try instant("2026-11-04T22:00:00Z")
        let summary = snapshot.summary(now: now)
        #expect(summary.overall.estimatedUSD == 9)
        #expect(summary.codingAgent.estimatedUSD == 6 && summary.verifier.estimatedUSD == 3)
        #expect(summary.coveredDays == 3 && summary.averageDailyUSD == 3)
        #expect(summary.days.map(\.overall.estimatedUSD) == [6, 0, 3])
        #expect(summary.days.map(\.date) == [try instant("2026-11-02T00:00:00Z"), try instant("2026-11-03T00:00:00Z"), try instant("2026-11-04T00:00:00Z")])

        let wholeRange = DateInterval(start: try instant("2026-11-01T00:00:00Z"), end: try instant("2026-11-05T00:00:00Z"))
        #expect(snapshot.summary(interval: wholeRange, now: now).coveredDays == 3)
        let lastTwoDays = DateInterval(start: try instant("2026-11-03T00:00:00Z"), end: try instant("2026-11-05T00:00:00Z"))
        let recent = snapshot.summary(interval: lastTwoDays, now: now)
        #expect(recent.overall.estimatedUSD == 3 && recent.coveredDays == 2 && recent.averageDailyUSD == 1.5)
        #expect(recent.days.map(\.overall.estimatedUSD) == [0, 3])
    }

    @Test("No tracking or an uncovered requested range has no invented average")
    func uncoveredAverage() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let now = try instant("2026-11-04T22:00:00Z")
        let empty = try await store.snapshot().summary(now: now)
        #expect(empty.coveredDays == 0 && empty.days.isEmpty && empty.averageDailyUSD == nil)
        try await record(store, at: "2026-11-04T20:00:00Z", role: .codingAgent, cost: 2)
        let snapshot = try await store.snapshot()
        let beforeTracking = DateInterval(start: try instant("2026-11-01T00:00:00Z"), end: try instant("2026-11-03T00:00:00Z"))
        let result = snapshot.summary(interval: beforeTracking, now: now)
        #expect(result.coveredDays == 0 && result.days.isEmpty && result.overall.runs == 0 && result.averageDailyUSD == nil)
        #expect(snapshot.summary(now: now).averageDailyUSD == 2)
    }

    @Test("Unknown daily usage stays unavailable; an explicitly reported zero can average to zero")
    func unknownDailyAverage() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        try await record(store, at: "2026-11-02T12:00:00Z", role: .verifier, cost: nil)
        let now = try instant("2026-11-04T22:00:00Z")
        let unknown = try await store.snapshot().summary(now: now)
        #expect(unknown.coveredDays == 3 && unknown.days.count == 3)
        #expect(unknown.overall.unknownCostRuns == 1 && unknown.averageDailyUSD == nil)
        #expect(unknown.days.first?.overall.unknownCostRuns == 1)
        try await record(store, at: "2026-11-03T12:00:00Z", role: .codingAgent, cost: 0)
        let reportedZero = try await store.snapshot().summary(now: now)
        #expect(reportedZero.overall.runs == 2 && reportedZero.overall.unknownCostRuns == 1)
        #expect(reportedZero.averageDailyUSD == 0)
    }

    @Test("Discarding an unstarted first process does not extend daily tracking coverage")
    func discardedLaunchCoverage() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let failed = UUID()
        try await store.begin(id: failed, role: .codingAgent, assistant: .claude, date: instant("2026-11-02T23:59:59Z"))
        try await record(store, at: "2026-11-03T00:00:01Z", role: .codingAgent, cost: 2)
        try await store.discard(id: failed)
        let snapshot = try await store.snapshot()
        #expect(snapshot.startedAt == (try instant("2026-11-03T00:00:01Z")))
        #expect(snapshot.summary(now: try instant("2026-11-03T12:00:00Z")).coveredDays == 1)
    }

    @Test("Compaction retains separate UTC days so daily history survives old receipt eviction")
    func archivedDailyHistory() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        let formatter = ISO8601DateFormatter()
        for day in 1...3 {
            let date = try #require(formatter.date(from: "2026-11-0\(day)T12:00:00Z"))
            let id = UUID()
            try await store.begin(id: id, role: .codingAgent, assistant: .claude, date: date)
            try await store.finish(id: id, measurement: .init(tokens: nil, estimatedUSD: Double(day), pricingVersion: "claude-cli"), complete: true)
        }
        let snapshot = try await store.snapshot()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        for day in 1...3 {
            let date = try #require(formatter.date(from: "2026-11-0\(day)T12:00:00Z"))
            let interval = try #require(calendar.dateInterval(of: .day, for: date))
            #expect(snapshot.total(for: .codingAgent, interval: interval).estimatedUSD == Double(day))
        }
    }

    @Test("Default usage storage is isolated whenever the test bundle is loaded")
    func defaultTestStoreIsolation() async {
        #expect(Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" })
        let file = await AssistantUsageStore.shared.file
        #expect(!file.path.contains("Library/Application Support/com.vaporpw.GitLabTodos/Assistant Usage"))
    }

    @Test("Compacted UTC hour totals sum consistently into UTC month ranges")
    func stableUTCMonth() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file, receiptLimit: 1)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z"))
        for _ in 0..<3 {
            let id = UUID()
            try await store.begin(id: id, role: .codingAgent, assistant: .claude, date: date)
            try await store.finish(id: id, measurement: .init(tokens: nil, estimatedUSD: 1, pricingVersion: "claude-cli"), complete: true)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let interval = try #require(calendar.dateInterval(of: .month, for: date))
        let snapshot = try await store.snapshot()
        #expect(snapshot.total(for: .codingAgent, interval: interval).estimatedUSD == 3)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let archived = try #require(json["archived"] as? [[String: Any]])
        let hour = try #require(archived.first?["hour"] as? Double)
        #expect(Date(timeIntervalSinceReferenceDate: hour) == date)
    }

    @Test("Overflowing token aggregates become unavailable without crashing accounting")
    func tokenAggregateOverflow() throws {
        var total = AssistantUsageTotal(runs: 1, estimatedUSD: 1, inputTokens: Int.max, cachedInputTokens: 0, outputTokens: 0)
        total.add(.init(runs: 1, estimatedUSD: 2, inputTokens: 1, cachedInputTokens: 0, outputTokens: 0))
        #expect(total.runs == 2 && total.estimatedUSD == 3)
        #expect(total.inputTokens == 0)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(total)) as? [String: Any])
        #expect(json["tokensUnavailable"] as? Bool == true)
    }

    @Test("Overflowing dollar aggregates become unavailable instead of infinity")
    func dollarAggregateOverflow() throws {
        var total = AssistantUsageTotal(runs: 1, estimatedUSD: Double.greatestFiniteMagnitude)
        total.add(.init(runs: 1, estimatedUSD: Double.greatestFiniteMagnitude))
        #expect(total.estimatedUSD.isFinite)
        #expect(total.unknownCostRuns == 2)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(total)) as? [String: Any])
        #expect(json["costUnavailable"] as? Bool == true)
    }

    @Test("Restarts retain separate role totals and unknown runs; repeated receipts count once")
    func persistenceAndDeduplication() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let date = Date(timeIntervalSince1970: 1_799_000_000)
        let worker = UUID(), verifier = UUID(), interrupted = UUID()
        try await store.begin(id: worker, role: .codingAgent, assistant: .claude, date: date)
        try await store.finish(id: worker, measurement: .init(tokens: .init(input: 100, cachedInput: 80, output: 20), estimatedUSD: 2, pricingVersion: "claude-cli"), complete: true)
        try await store.finish(id: worker, measurement: .init(tokens: nil, estimatedUSD: 99, pricingVersion: "claude-cli"), complete: true)
        try await store.begin(id: verifier, role: .verifier, assistant: .codex, date: date)
        try await store.finish(id: verifier, measurement: .init(tokens: .init(input: 20, cachedInput: 10, output: 5), estimatedUSD: 0.1, pricingVersion: "snapshot"), complete: true)
        try await store.begin(id: interrupted, role: .verifier, assistant: .codex, date: date)

        let restarted = AssistantUsageStore(file: file)
        let snapshot = try await restarted.snapshot()
        let coding = snapshot.total(for: .codingAgent)
        let verification = snapshot.total(for: .verifier)
        #expect(coding.runs == 1 && coding.estimatedUSD == 2 && coding.unknownCostRuns == 0)
        #expect(verification.runs == 2 && verification.estimatedUSD == 0.1 && verification.unknownCostRuns == 1)
        #expect(verification.inputTokens == 20 && verification.cachedInputTokens == 10)
        #expect(snapshot.startedAt == date)
        let stored = try String(contentsOf: file, encoding: .utf8)
        #expect(!stored.contains("prompt") && !stored.contains("stdout"))
    }

    @Test("Concurrent runs are not lost and month filtering preserves historical totals")
    func concurrentMonthlyTotals() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AssistantUsageStore(file: file)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let current = Date(timeIntervalSince1970: 1_799_000_000)
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for index in 0..<30 {
                tasks.addTask {
                    let id = UUID()
                    try await store.begin(id: id, role: .codingAgent, assistant: .claude, date: index < 10 ? old : current)
                    try await store.finish(id: id, measurement: .init(tokens: nil, estimatedUSD: 0.5, pricingVersion: "claude-cli"), complete: true)
                }
            }
            try await tasks.waitForAll()
        }
        let snapshot = try await store.snapshot()
        #expect(snapshot.total(for: .codingAgent).runs == 30)
        #expect(snapshot.total(for: .codingAgent).estimatedUSD == 15)
        let month = try #require(Calendar.current.dateInterval(of: .month, for: current))
        #expect(snapshot.total(for: .codingAgent, interval: month).estimatedUSD == 10)
    }

    @Test("Corrupt accounting is surfaced instead of silently replacing history")
    func corruptHistory() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: file)
        let store = AssistantUsageStore(file: file)
        await #expect(throws: (any Error).self) { try await store.snapshot() }
        await #expect(throws: (any Error).self) { try await store.begin(id: UUID(), role: .verifier, assistant: .codex, date: Date()) }
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
    }

    @Test("Compaction keeps lifetime and monthly totals, including interrupted runs")
    func compactedHistory() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_799_000_000)
        let firstStore = AssistantUsageStore(file: file, receiptLimit: 2)
        for _ in 0..<3 {
            try await firstStore.begin(id: UUID(), role: .verifier, assistant: .codex, date: date)
        }
        let restarted = AssistantUsageStore(file: file, receiptLimit: 2)
        for _ in 0..<3 {
            let id = UUID()
            try await restarted.begin(id: id, role: .codingAgent, assistant: .claude, date: date)
            try await restarted.finish(id: id, measurement: .init(tokens: nil, estimatedUSD: 1, pricingVersion: "claude-cli"), complete: true)
        }
        let snapshot = try await restarted.snapshot()
        #expect(snapshot.total(for: .codingAgent).estimatedUSD == 3)
        #expect(snapshot.total(for: .verifier).unknownCostRuns == 3)
        let month = try #require(Calendar.current.dateInterval(of: .month, for: date))
        #expect(snapshot.total(for: .verifier, interval: month).runs == 3)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((json["receipts"] as? [Any])?.count == 2)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "UsageTests-\(UUID())/usage.json")
    }

    private func instant(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func record(_ store: AssistantUsageStore, at date: String, role: AssistantUsageRole, cost: Double?,
                        assistant: AutomationAssistant = .claude, mergeRequest: AssistantUsageMergeRequest? = nil) async throws {
        let id = UUID()
        try await store.begin(id: id, role: role, assistant: assistant, date: instant(date), mergeRequest: mergeRequest)
        try await store.finish(id: id, measurement: .init(tokens: nil, estimatedUSD: cost, pricingVersion: cost == nil ? nil : "claude-cli"), complete: true)
    }

    private func usageMR(host: String = "gitlab.example.test", username: String? = "me", projectID: Int = 7,
                         iid: Int = 11, title: String = "Synthetic MR") -> AssistantUsageMergeRequest {
        .init(host: host, username: username, projectID: projectID, iid: iid,
            title: title, url: "https://\(host)/team/repo/-/merge_requests/\(iid)")
    }
}
