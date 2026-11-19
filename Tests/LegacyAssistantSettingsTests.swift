import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct LegacyAssistantSettingsTests {
    @Test func olderSettingsUseSolHighAndReviewSelectionPersists() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        #expect(settings.codexReviewModel.rawValue == "gpt-6.1-sol")
        #expect(settings.codexReviewThinking.rawValue == "high")
        settings.codexReviewModel = .luna
        settings.codexReviewThinking = .low
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func olderSettingsUseClaudeOpusHighAndCodingSelectionPersists() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        #expect(settings.claudeCodingModel.rawValue == "claude-opus-5-5")
        #expect(settings.claudeCodingThinking.rawValue == "high")
        settings.claudeCodingModel = .sonnet
        settings.claudeCodingThinking = .low
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.assistant = .claude
        #expect(settings.codingPolicy == "claude|claude-sonnet-5-5|low")
        #expect(settings.codingThinking(for: .claude) == .low && settings.codingThinking(for: .codex) == .high)
    }
}
