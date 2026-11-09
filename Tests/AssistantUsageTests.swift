import Foundation
import Testing
@testable import GitLabTodos

@Suite("Assistant usage")
struct AssistantUsageTests {
    @Test("MR ranking uses the chart's selected range and current UTC hour cutoff")
    func mergeRequestRankingMatchesChartRange() throws {
        let first = usageMR(iid: 1), second = usageMR(iid: 2), future = usageMR(iid: 3)
        let snapshot = AssistantUsageSnapshot(startedAt: try usageDate("2026-11-01T00:00:00Z"), entries: [
            try usageEntry(at: "2026-11-02T23:59:59Z", cost: 100, mergeRequest: first),
            try usageEntry(at: "2026-11-03T00:00:00Z", cost: 2, mergeRequest: first),
            try usageEntry(at: "2026-11-04T08:00:00Z", cost: 5, mergeRequest: second),
            try usageEntry(at: "2026-11-04T12:05:00Z", cost: 1, mergeRequest: first),
            try usageEntry(at: "2026-11-04T15:00:00Z", cost: 40, mergeRequest: future),
            try usageEntry(at: "2026-11-05T00:00:00Z", cost: 80, mergeRequest: second)
        ])
        let range = DateInterval(start: try usageDate("2026-11-03T00:00:00Z"), end: try usageDate("2026-11-05T00:00:00Z"))
        let now = try usageDate("2026-11-04T12:30:00Z")
        let chart = snapshot.chartData(granularity: .hour, interval: range, now: now)
        let ranking = snapshot.mergeRequestTotals(interval: range, now: now)
        #expect(chart.buckets.reduce(0) { $0 + $1.overall.estimatedUSD } == 8)
        #expect(ranking.map(\.id) == [second.id, first.id])
        #expect(ranking.map(\.total.estimatedUSD) == [5, 3])
        #expect(ranking.reduce(0) { $0 + $1.total.estimatedUSD } == chart.buckets.reduce(0) { $0 + $1.overall.estimatedUSD })
    }

    @Test("MR costs distinguish host, account, project and IID without adopting unattributed history")
    func mergeRequestIdentityIsolation() throws {
        let target = usageMR()
        let identities = [target,
            usageMR(host: "other.example.test"), usageMR(username: "another"),
            usageMR(projectID: 8), usageMR(iid: 12), usageMR(username: nil)]
        var entries: [AssistantUsageEntry] = []
        for (index, identity) in identities.enumerated() {
            entries.append(try usageEntry(at: "2026-11-04T08:00:00Z", cost: Double(1 << index), mergeRequest: identity))
        }
        entries.append(try usageEntry(at: "2026-11-04T08:00:00Z", cost: 64, mergeRequest: nil))
        let snapshot = AssistantUsageSnapshot(startedAt: try usageDate("2026-11-04T08:00:00Z"), entries: entries)
        let ranking = snapshot.mergeRequestTotals(interval: nil, now: try usageDate("2026-11-04T12:00:00Z"))
        #expect(ranking.count == identities.count)
        #expect(ranking.reduce(0) { $0 + $1.total.estimatedUSD } == 63)
        for (index, identity) in identities.enumerated() {
            #expect(snapshot.total(for: identity).estimatedUSD == Double(1 << index))
        }
        var renamedTarget = target
        renamedTarget.title = "Updated display title"
        renamedTarget.url = "https://gitlab.example.test/team/renamed/-/merge_requests/11"
        #expect(snapshot.total(for: renamedTarget).estimatedUSD == 1)
    }

    @Test("MR Details totals span all tracked time, providers and roles while preserving unknown runs")
    func mergeRequestLifetimeTotalIsIndependentOfDashboardRange() throws {
        let target = usageMR()
        let snapshot = AssistantUsageSnapshot(startedAt: try usageDate("2026-10-01T08:00:00Z"), entries: [
            try usageEntry(at: "2026-10-01T08:00:00Z", cost: 2, mergeRequest: target, role: .codingAgent, assistant: .claude),
            try usageEntry(at: "2026-10-02T09:00:00Z", cost: nil, mergeRequest: target, role: .verifier),
            try usageEntry(at: "2026-11-04T08:00:00Z", cost: 3, mergeRequest: target, role: .verifier),
            try usageEntry(at: "2026-11-04T09:00:00Z", cost: 99, mergeRequest: usageMR(iid: 12))
        ])
        let range = DateInterval(start: try usageDate("2026-11-04T00:00:00Z"), end: try usageDate("2026-11-05T00:00:00Z"))
        let filtered = snapshot.mergeRequestTotals(interval: range, now: try usageDate("2026-11-04T12:00:00Z"))
        #expect(filtered.first { $0.id == target.id }?.total.estimatedUSD == 3)
        let lifetime = snapshot.total(for: target)
        #expect(lifetime.runs == 3 && lifetime.estimatedUSD == 5 && lifetime.unknownCostRuns == 1)
    }

    @Test("MR ranking combines changed display metadata and leaves unknown-only costs explicitly unknown")
    func mergeRequestRankingGroupsByIdentityAndRetainsUnknownCostRuns() throws {
        let target = usageMR()
        var updated = target
        updated.title = "Updated MR title"
        let unknown = usageMR(iid: 12)
        let snapshot = AssistantUsageSnapshot(startedAt: try usageDate("2026-11-04T08:00:00Z"), entries: [
            try usageEntry(at: "2026-11-04T08:00:00Z", cost: 2, mergeRequest: target),
            try usageEntry(at: "2026-11-04T09:00:00Z", cost: 3, mergeRequest: updated, role: .verifier, assistant: .claude),
            try usageEntry(at: "2026-11-04T10:00:00Z", cost: nil, mergeRequest: updated),
            try usageEntry(at: "2026-11-04T10:00:00Z", cost: nil, mergeRequest: unknown)
        ])
        let ranking = snapshot.mergeRequestTotals(interval: nil, now: try usageDate("2026-11-04T12:00:00Z"))
        #expect(ranking.count == 2 && ranking.first?.id == target.id)
        let known = try #require(ranking.first)
        #expect(known.total.estimatedUSD == 5 && known.total.runs == 3 && known.total.unknownCostRuns == 1)
        #expect(known.mergeRequest.title == "Updated MR title")
        let unknownOnly = try #require(ranking.first { $0.id == unknown.id })
        #expect(unknownOnly.total.runs == 1 && unknownOnly.total.unknownCostRuns == 1)
        #expect(unknownOnly.total.estimatedUSD == 0)
    }

    @Test("Malformed nonempty Codex events leave the available subtotal explicitly incomplete")
    func malformedJSONEvent() {
        let data = Data("""
            {"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}
            {"type":"turn.completed","usage":
            {"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}
            """.utf8)
        let result = AssistantUsageParser.parse(data, assistant: .codex, model: "gpt-6-luna")
        #expect(result.estimatedUSD == 0.2)
        #expect(result.tokens?.input == 2_000_000)
        #expect(result.terminalComplete == false)
    }

    @Test("Codex completed turns count cached input once and use the published baseline")
    func codexUsage() throws {
        let data = Data("""
            {"type":"item.completed","item":{"text":"private prompt, not usage"}}
            {"type":"turn.completed","usage":{"input_tokens":1000000,"cached_input_tokens":800000,"output_tokens":100000,"reasoning_output_tokens":30000}}
            {"type":"turn.completed","usage":{"input_tokens":200000,"cached_input_tokens":100000,"output_tokens":20000}}
            """.utf8)
        let result = AssistantUsageParser.parse(data, assistant: .codex, model: "gpt-6.1-sol")
        #expect(result.tokens == .init(input: 1_200_000, cachedInput: 900_000, output: 120_000))
        #expect(abs(try #require(result.estimatedUSD) - 1.89) < 0.000001)
        #expect(result.pricingVersion == "openai-standard-short-2026-11-08")
    }

    @Test("Claude uses the envelope total rather than adding per-model costs twice")
    func claudeUsage() throws {
        let data = Data(#"{"type":"result","total_cost_usd":0.42,"usage":{"input_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":100,"output_tokens":30},"modelUsage":{"claude-opus-5-5":{"costUSD":0.30},"claude-haiku-5-5":{"costUSD":0.12}}}"#.utf8)
        let result = AssistantUsageParser.parse(data, assistant: .claude, model: nil)
        #expect(result.tokens == .init(input: 620, cachedInput: 500, output: 30))
        #expect(result.estimatedUSD == 0.42)
        #expect(result.pricingVersion == "claude-cli")
    }

    @Test("Unknown model usage stays available without fabricating dollars")
    func unknownModel() {
        let data = Data(#"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10}}"#.utf8)
        let result = AssistantUsageParser.parse(data, assistant: .codex, model: "future-model")
        #expect(result.tokens == .init(input: 100, cachedInput: 50, output: 10))
        #expect(result.estimatedUSD == nil)
    }

    @Test("Missing or invalid usage is unknown, while explicitly reported zero remains zero")
    func missingAndZeroUsage() {
        for text in ["", "not json", #"{"type":"result"}"#, #"{"total_cost_usd":-1}"#] {
            #expect(AssistantUsageParser.parse(Data(text.utf8), assistant: .claude, model: nil).estimatedUSD == nil)
        }
        #expect(AssistantUsageParser.parse(Data(#"{"total_cost_usd":0}"#.utf8), assistant: .claude, model: nil).estimatedUSD == 0)
        for usage in [#"{"input_tokens":-1,"cached_input_tokens":0,"output_tokens":3}"#,
                      #"{"input_tokens":10,"cached_input_tokens":20,"output_tokens":3}"#,
                      #"{"input_tokens":10,"output_tokens":3}"#] {
            let text = "{\"type\":\"turn.completed\",\"usage\":\(usage)}"
            #expect(AssistantUsageParser.parse(Data(text.utf8), assistant: .codex, model: "gpt-6-luna").estimatedUSD == nil)
        }
    }

    @Test("A malformed completed turn cannot silently turn a partial total into a full estimate")
    func malformedTurnAfterValidUsage() {
        let data = Data("""
            {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":20}}
            {"type":"turn.completed","usage":{"input_tokens":"invalid","cached_input_tokens":0,"output_tokens":1}}
            """.utf8)
        #expect(AssistantUsageParser.parse(data, assistant: .codex, model: "gpt-6.1-sol").estimatedUSD == nil)
    }

    @Test("Claude per-model estimates are used only when every model reports a valid cost")
    func claudeModelFallback() {
        let valid = Data(#"{"modelUsage":{"a":{"costUSD":0.2},"b":{"costUSD":0.3}}}"#.utf8)
        #expect(AssistantUsageParser.parse(valid, assistant: .claude, model: nil).estimatedUSD == 0.5)
        let missing = Data(#"{"modelUsage":{"a":{"costUSD":0.2},"b":{}}}"#.utf8)
        #expect(AssistantUsageParser.parse(missing, assistant: .claude, model: nil).estimatedUSD == nil)
    }

    private func usageMR(host: String = "gitlab.example.test", username: String? = "me", projectID: Int = 7, iid: Int = 11) -> AssistantUsageMergeRequest {
        .init(host: host, username: username, projectID: projectID, iid: iid,
            title: "Synthetic MR", url: "https://\(host)/team/repo/-/merge_requests/\(iid)")
    }

    private func usageDate(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func usageEntry(at date: String, cost: Double?, mergeRequest: AssistantUsageMergeRequest?,
                            role: AssistantUsageRole = .codingAgent, assistant: AutomationAssistant = .codex) throws -> AssistantUsageEntry {
        .init(date: try usageDate(date), role: role, assistant: assistant,
            total: .init(runs: 1, estimatedUSD: cost ?? 0, unknownCostRuns: cost == nil ? 1 : 0), mergeRequest: mergeRequest)
    }
}
