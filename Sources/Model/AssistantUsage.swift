import Foundation

enum AssistantUsageRole: String, Codable, CaseIterable, Sendable {
    case codingAgent, verifier
}

struct AssistantTokenUsage: Codable, Equatable, Sendable {
    let input: Int
    let cachedInput: Int
    let output: Int
}

struct AssistantUsageMeasurement: Codable, Equatable, Sendable {
    let tokens: AssistantTokenUsage?
    let estimatedUSD: Double?
    let pricingVersion: String?
    var terminalComplete: Bool?
}

enum AssistantUsageParser {
    static func parse(_ data: Data, assistant: AutomationAssistant, model: String?) -> AssistantUsageMeasurement {
        assistant == .codex ? codex(data, model: model) : claude(data)
    }

    private static func codex(_ data: Data, model: String?) -> AssistantUsageMeasurement {
        struct Header: Decodable { let type: String }
        struct Event: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int
                let cached_input_tokens: Int
                let output_tokens: Int
            }
            let type: String
            let usage: Usage?
        }
        var tokens = AssistantTokenUsage(input: 0, cachedInput: 0, output: 0)
        var found = false
        var completed = false
        var failed = false
        for line in data.split(separator: 10) {
            let bytes = Data(line)
            guard let header = try? JSONDecoder().decode(Header.self, from: bytes) else {
                failed = true
                completed = false
                continue
            }
            switch header.type {
            case "turn.started": completed = false
            case "turn.failed", "error": failed = true; completed = false
            case "turn.completed": completed = true
            default: continue
            }
            guard header.type == "turn.completed" else { continue }
            guard let event = try? JSONDecoder().decode(Event.self, from: bytes),
                  let usage = event.usage, usage.input_tokens >= 0, usage.cached_input_tokens >= 0,
                  usage.output_tokens >= 0, usage.cached_input_tokens <= usage.input_tokens,
                  let combined = tokens.adding(.init(input: usage.input_tokens,
                    cachedInput: usage.cached_input_tokens, output: usage.output_tokens)) else { return unknown }
            tokens = combined
            found = true
        }
        guard found else { return unknown }
        let price = CodexUsagePricing.estimate(tokens, model: model)
        return .init(tokens: tokens, estimatedUSD: price, pricingVersion: price == nil ? nil : CodexUsagePricing.version,
            terminalComplete: completed && !failed)
    }

    private static func claude(_ data: Data) -> AssistantUsageMeasurement {
        struct Envelope: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int
                let cache_read_input_tokens: Int?
                let cache_creation_input_tokens: Int?
                let output_tokens: Int
            }
            struct Model: Decodable { let costUSD: Double? }
            let total_cost_usd: Double?
            let usage: Usage?
            let modelUsage: [String: Model]?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return unknown }
        let tokens: AssistantTokenUsage?
        if let usage = envelope.usage, usage.input_tokens >= 0, usage.output_tokens >= 0,
           (usage.cache_read_input_tokens ?? 0) >= 0, (usage.cache_creation_input_tokens ?? 0) >= 0 {
            tokens = AssistantTokenUsage(input: usage.input_tokens, cachedInput: 0, output: usage.output_tokens)
                .adding(.init(input: usage.cache_read_input_tokens ?? 0,
                    cachedInput: usage.cache_read_input_tokens ?? 0, output: 0))?
                .adding(.init(input: usage.cache_creation_input_tokens ?? 0, cachedInput: 0, output: 0))
        } else { tokens = nil }
        var cost = envelope.total_cost_usd
        if cost == nil, let models = envelope.modelUsage, !models.isEmpty {
            let costs = models.values.compactMap(\.costUSD)
            if costs.count == models.count && costs.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                cost = costs.reduce(0, +)
            }
        }
        if cost?.isFinite != true || (cost ?? -1) < 0 { cost = nil }
        return .init(tokens: tokens, estimatedUSD: cost, pricingVersion: cost == nil ? nil : "claude-cli")
    }

    private static var unknown: AssistantUsageMeasurement {
        .init(tokens: nil, estimatedUSD: nil, pricingVersion: nil)
    }
}

extension AssistantTokenUsage {
    fileprivate func adding(_ other: Self) -> Self? {
        let input = input.addingReportingOverflow(other.input)
        let cached = cachedInput.addingReportingOverflow(other.cachedInput)
        let output = output.addingReportingOverflow(other.output)
        guard !input.overflow, !cached.overflow, !output.overflow else { return nil }
        return .init(input: input.partialValue, cachedInput: cached.partialValue, output: output.partialValue)
    }
}

/// A comparison baseline, never a subscription charge or a billing receipt.
/// Source: https://developers.openai.com/api/docs/pricing (verified 2026-11-08).
/// Aggregated CLI usage cannot reveal each request's context length, cache writes or tier.
enum CodexUsagePricing {
    static let version = "openai-standard-short-2026-11-08"
    static let source = URL(string: "https://developers.openai.com/api/docs/pricing")!

    static func estimate(_ tokens: AssistantTokenUsage, model: String?) -> Double? {
        let rates: (input: Double, cached: Double, output: Double)
        switch model {
        case "gpt-6-astra": rates = (10, 1, 50)
        case "gpt-6.1-sol": rates = (2, 0.1, 10)
        case "gpt-6.1-terra": rates = (1, 0.05, 5)
        case "gpt-6-luna": rates = (0.1, 0.01, 0.5)
        default: return nil
        }
        return (Double(tokens.input - tokens.cachedInput) * rates.input
            + Double(tokens.cachedInput) * rates.cached + Double(tokens.output) * rates.output) / 1_000_000
    }
}
