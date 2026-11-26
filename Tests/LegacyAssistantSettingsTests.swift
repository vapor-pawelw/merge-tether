import Foundation
import Testing
@testable import MergeTether

@MainActor
struct LegacyAssistantSettingsTests {
    @Test func freshAndOlderSettingsWithoutAModelUseGPT62SolHigh() throws {
        #expect(AutomationSettings().codexReviewModel.rawValue == "gpt-6.2-sol")
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        #expect(settings.codexReviewModel.rawValue == "gpt-6.2-sol")
        #expect(settings.codexReviewThinking.rawValue == "high")
        #expect(settings.codexVerificationModel == .luna)
    }

    @Test(arguments: ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-sol", "gpt-6-astra"])
    func availableReviewModelsRoundTripWithoutChangingSelection(_ modelID: String) throws {
        let model = try #require(CodexReviewModel.allCases.first { $0.rawValue == modelID })
        let data = Data("""
            {"codexReviewModel":"\(modelID)"}
            """.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(settings.codexReviewModel == model)
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func customReviewModelAndThinkingPersist() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
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

    @Test func everySupportedClaudeModelCanBeStoredForEitherRole() throws {
        for modelID in ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            let data = Data("""
                {"claudeCodingModel":"\(modelID)","claudeVerificationModel":"\(modelID)"}
                """.utf8)
            let settings = try JSONDecoder().decode(AutomationSettings.self, from: data)
            #expect(settings.claudeCodingModel.rawValue == modelID)
            #expect(settings.claudeVerificationModel.rawValue == modelID)
            #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test func modelRecommendationsMatchTheRoleAndProvider() {
        #expect(CodexReviewModel.recommendedForCoding == [.sol62, .astra62])
        #expect(CodexReviewModel.recommendedForVerification == [.luna, .terra, .sol62])
        #expect(ClaudeModel.recommendedForCoding == [.opus, .fable])
        #expect(ClaudeModel.recommendedForVerification == [.haiku, .sonnet, .opus])
    }

    @Test func filteringThePickerKeepsAnExistingSelectionAndShowingAllOffersTheFullCatalog() {
        let recommended = ClaudeModel.recommendedForVerification
        #expect(ClaudeModel.haiku.pickerOptions(recommended: recommended, showAll: false) == recommended)
        #expect(ClaudeModel.fable.pickerOptions(recommended: recommended, showAll: false) == recommended + [.fable])
        #expect(ClaudeModel.fable.pickerOptions(recommended: recommended, showAll: true) == ClaudeModel.allCases)
        #expect(CodexReviewModel.sol62.pickerOptions(recommended: CodexReviewModel.recommendedForCoding, showAll: true)
            == CodexReviewModel.allCases)
    }
}
