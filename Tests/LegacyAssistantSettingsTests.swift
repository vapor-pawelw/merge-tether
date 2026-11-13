import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct LegacyAssistantSettingsTests {
    @Test func legacySettingsEnableTheTemplateWithoutOptingIntoDispatch() throws {
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        let fields = try encodedSettings(settings)
        #expect(fields["codexUseTemplate"] as? Bool == true)
        #expect(!settings.codexRelayEnabled)
    }

    @Test func explicitOptOutSurvivesRoundTripAndRecommendedReset() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"codexUseTemplate":false,"codexRelayEnabled":true}"#.utf8))
        #expect(try encodedSettings(settings)["codexUseTemplate"] as? Bool == false)
        settings.applyRecommended(for: .codex)
        #expect(try encodedSettings(settings)["codexUseTemplate"] as? Bool == false)
        #expect(settings.codexRelayEnabled)
    }

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

    private func encodedSettings(_ settings: AutomationSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
