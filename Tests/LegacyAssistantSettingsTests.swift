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

    private func encodedSettings(_ settings: AutomationSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
