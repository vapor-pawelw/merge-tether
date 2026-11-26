import AppKit
import Foundation
import Testing
@testable import MergeTether

struct MRActionEffectTests {
    private static let aiSymbols: Set<String> = ["sparkles", "sparkle.magnifyingglass"]

    @MainActor @Test(arguments: AutomationAssistant.allCases)
    func providerGlyphIsBundledAsASquareTemplate(_ assistant: AutomationAssistant) throws {
        let glyph = try #require(NSImage(named: .init(assistant.glyph.assetName)))
        #expect(glyph.isTemplate)
        #expect(glyph.size.width == glyph.size.height)
    }

    @Test(arguments: MRActionCTA.allCases)
    func aiIconsAreReservedForAIWork(_ cta: MRActionCTA) {
        let usesAI = cta.effect == .agent || cta.effect == .aiCheck
        #expect(Self.aiSymbols.contains(cta.symbol ?? "") == usesAI)
        #expect(cta.requiresCodingAssistant == usesAI)
    }

    @Test(arguments: MRActionCTA.allCases)
    func hoverStatesTheEffectKindFirstAndEveryFollowUp(_ cta: MRActionCTA) {
        let lines = cta.help.components(separatedBy: "\n")
        #expect(lines.first == String(localized: cta.effect.actionDescription))
        #expect(lines.count == 2 + cta.followUps.count)
        // A missing catalog entry would surface its raw key instead of a sentence.
        #expect(lines.allSatisfy { $0.contains(" ") })
    }

    @Test func agentAndCheckTooltipsDescribeDifferentActionsInBothLanguages() {
        for (language, expectedAgent, expectedCheck) in [
            ("en", "Starts an AI agent.", "Runs a read-only AI check."),
            ("pl", "Uruchamia agenta AI.", "Uruchamia kontrolę AI tylko do odczytu.")
        ] {
            var agent = MRActionEffect.agent.actionDescription
            var check = MRActionEffect.aiCheck.actionDescription
            agent.locale = Locale(identifier: language)
            check.locale = Locale(identifier: language)
            #expect(String(localized: agent) == expectedAgent)
            #expect(String(localized: check) == expectedCheck)
        }
    }

    @Test func deterministicActionsSaySoAndResumedAutomationShowsPlay() {
        #expect(MRActionCTA.approve.symbol == nil)
        #expect(MRActionCTA.merge.symbol == nil)
        #expect(MRActionCTA.merge.effect == .gitLabWithAICheck)
        #expect(MRActionCTA.markReady.symbol == "play.fill")
        #expect(MRActionCTA.finishCommentReview.symbol == "play.fill")
        #expect(MRActionCTA.publishComments.effect == .gitLab)
        #expect(MRActionCTA.refreshFromGitLab.followUps == [.runsAllowedAutomation])
    }

    @Test func chainedAIChecksDescribeWhatMayFollow() {
        #expect(MRActionCTA.verifyFeedback.effect == .aiCheck)
        #expect(MRActionCTA.verifyFeedback.followUps == [.mayStartAgent])
        #expect(MRActionCTA.verifyReReview.followUps == [.mayRequestReReview])
    }

    @Test func todoIntentsUseTheirAgentCallToAction() {
        #expect(MRActionCTA(intent: .review) == .runReview)
        #expect(MRActionCTA(intent: .followUp) == .handleFeedback)
        #expect(MRActionCTA(intent: .pipeline) == .diagnosePipeline)
        #expect(MRActionCTA(intent: .conflict) == .resolveConflicts)
        #expect(MRActionCTA(intent: .refresh) == nil)
    }
}
