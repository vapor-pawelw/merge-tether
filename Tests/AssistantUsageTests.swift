import Foundation
import Testing
@testable import GitLabTodos

@Suite("Assistant usage")
struct AssistantUsageTests {
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
}
