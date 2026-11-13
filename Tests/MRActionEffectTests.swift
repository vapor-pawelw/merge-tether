import Foundation
import Testing
@testable import GitLabTodos

struct MRActionEffectTests {
    private static let aiSymbols: Set<String> = ["sparkles", "sparkle.magnifyingglass"]

    @Test(arguments: MRActionCTA.allCases)
    func aiIconsAreReservedForAIWork(_ cta: MRActionCTA) {
        let usesAI = cta.effect == .agent || cta.effect == .aiCheck
        #expect(Self.aiSymbols.contains(cta.symbol ?? "") == usesAI)
    }

    @Test(arguments: MRActionCTA.allCases)
    func hoverStatesTheEffectKindFirstAndEveryFollowUp(_ cta: MRActionCTA) {
        let lines = cta.help.components(separatedBy: "\n")
        #expect(lines.first == String(localized: cta.effect.kindDescription))
        #expect(lines.count == 2 + cta.followUps.count)
        // A missing catalog entry would surface its raw key instead of a sentence.
        #expect(lines.allSatisfy { $0.contains(" ") })
    }

    @Test func deterministicActionsSaySoAndResumedAutomationShowsTheBolt() {
        #expect(MRActionCTA.approve.symbol == nil)
        #expect(MRActionCTA.merge.symbol == nil)
        #expect(MRActionCTA.markReady.symbol == "bolt")
        #expect(MRActionCTA.finishCommentReview.symbol == "bolt")
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
