import Foundation
import Testing
@testable import MergeTether

struct AICommentPublicationTests {
    @Test func styleCriteriaRevisionIsNewerThanThePreviousHeuristic() {
        #expect(AICommentOriginAssessor.criteriaVersion > 5)
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func styleEvidenceRequiresTwoDistinctConfirmationsAndNoHumanMark(_ confirmations: Int, _ human: Bool) {
        let expected: AIReplyTrustLane = confirmations >= 2 && !human ? .trustedAuthor : .unconfirmed
        #expect(AIReplyTrustLane(override: nil, definite: false, styleSaysAI: true,
            trustsAuthor: confirmations >= 2 && !human) == expected)
        #expect(AIReplyTrustLane(override: nil, definite: false, styleSaysAI: false,
            trustsAuthor: true) == .humanOrUncertain)
        #expect(AIReplyTrustLane(override: .human, definite: false, styleSaysAI: true,
            trustsAuthor: true) == .humanOrUncertain)
        #expect(AIReplyTrustLane(override: .uncertain, definite: false, styleSaysAI: true,
            trustsAuthor: true) == .humanOrUncertain)
        #expect(AIReplyTrustLane(override: .ai, definite: false, styleSaysAI: false,
            trustsAuthor: false) == .definite)
        #expect(AIReplyTrustLane(override: nil, definite: true, styleSaysAI: false,
            trustsAuthor: false) == .definite)
    }

    @Test func newOptionMigratesOnAndPreservesExplicitChoices() throws {
        let decoder = JSONDecoder()
        #expect(AutomationSettings().publishAIRepliesWithoutConfirmation)
        #expect(try decoder.decode(AutomationSettings.self, from: Data("{}".utf8)).publishAIRepliesWithoutConfirmation)
        let off = try decoder.decode(AutomationSettings.self, from: Data(#"{"publishAIRepliesWithoutConfirmation":false}"#.utf8))
        #expect(!off.publishAIRepliesWithoutConfirmation)
        let roundTrip = try decoder.decode(AutomationSettings.self, from: JSONEncoder().encode(off))
        #expect(!roundTrip.publishAIRepliesWithoutConfirmation)
        let disabled = try decoder.decode(AutomationSettings.self, from: Data(#"{"packageDecision":"disabled"}"#.utf8))
        #expect(!disabled.publishAIRepliesWithoutConfirmation)
        var settings = AutomationSettings()
        settings.disableAssistantPackage()
        #expect(!settings.publishAIRepliesWithoutConfirmation)
        settings.applyRecommended(for: .codex)
        #expect(settings.publishAIRepliesWithoutConfirmation)
    }

    @Test func advancedAIRestrictionRequestsAssessmentsEvenForLegacyAllModeWithAIFlagOff() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(
            #"{"publishDraftsWithoutConfirmation":true,"publishAIRepliesWithoutConfirmation":false}"#.utf8))
        #expect(!settings.needsAIAssessment)
        settings.publicationRestrictions.requireAI = true
        #expect(settings.needsAIAssessment)
        settings.publicationRestrictions.requireAI = false
        settings.publicationMode = .aiReplies
        #expect(settings.needsAIAssessment)
    }

    @Test func repliesNeverResolveSomeoneElsesThreadOrInheritPermissionForHumanFollowUps() throws {
        let draftJSON = #"{"id":1,"author_id":3,"note":"Fixed","discussion_id":"abc","position":null}"#
        let note = #"{"id":40,"author":{"id":8},"system":false,"body":"AI finding"}"#
        let human = #"{"id":41,"author":{"id":9},"system":false,"body":"But what about this?"}"#
        let ownReply = #"{"id":42,"author":{"id":3},"system":false,"body":"Done"}"#
        let decoder = JSONDecoder()
        let draft = try decoder.decode(GitLabDraftNote.self, from: Data(draftJSON.utf8))
        func eligible(_ notes: String, draft: GitLabDraftNote = draft) throws -> Bool {
            let discussions = try decoder.decode([GitLabMergeRequestDiscussion].self,
                from: Data("[{\"id\":\"abc\",\"notes\":[\(notes)]}]".utf8))
            return AICommentAssessmentStore.eligible(draft, discussions: discussions, userID: 3, duoUserIDs: [8],
                host: "example.org", projectID: 1, iid: 2, in: URL(fileURLWithPath: "/nonexistent"))
        }
        #expect(try eligible(note))
        #expect(try !eligible(note + "," + human))
        #expect(try eligible(note + "," + ownReply))
        var resolving = draft
        resolving.resolveDiscussion = true
        #expect(try !eligible(note, draft: resolving))
        let general = try decoder.decode(GitLabDraftNote.self,
            from: Data(draftJSON.replacingOccurrences(of: "\"abc\"", with: "null").utf8))
        #expect(try !eligible(note, draft: general))
    }
    @Test func workerAssessmentInstructionsRequestAnExactSourceAndReusePriorResults() {
        let custom = "Look for the team review format."
        let instructions = AICommentAssessmentStore.workerInstructions(criteriaOverride: custom,
            existing: ["40:abcdef"])
        #expect(instructions.contains(custom))
        #expect(!instructions.contains(AICommentOriginAssessor.criteriaInstructions))
        #expect(instructions.contains("exact UTF-8 source body"))
        #expect(instructions.contains("sourceAssessments"))
        #expect(instructions.contains("40:abcdef"))
        #expect(!instructions.contains(".json"))
    }

    @MainActor @Test(arguments: ["same source", "likely human", "edited source", "unrelated source", "old draft"])
    func aWorkerAssessmentCountsOnlyForTheLiveSourceOfANewReply(_ scenario: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = MRAutomationScope.Target(host: "example.org", username: "me", projectID: 1, iid: 2)
        let original = #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"system":false,"body":"AI finding"}]}]"#
        let live = switch scenario {
        case "edited source": original.replacingOccurrences(of: "AI finding", with: "New text")
        case "unrelated source": original.replacingOccurrences(of: "abc", with: "different-discussion")
        default: original
        }
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(live.utf8))
        let note = try #require(discussions.first?.notes.first)
        let draft = GitLabDraftNote(id: 72, authorID: 3, note: "Fixed", discussionID: "abc", position: nil)
        let claims: [AssistantJobResult.SourceAssessment] = [
            .init(noteID: 40, bodySHA256: AICommentAssessmentStore.digest("AI finding"),
                classification: scenario == "likely human" ? .manualLikely : .aiAssisted,
                confidence: .high, evidence: "Specific cross-file reasoning."),
        ]
        let replyClaims: [AssistantJobResult.GeneratedDraft] = [
            .init(id: 72, bodySHA256: AICommentAssessmentStore.digest("Fixed")),
        ]
        _ = await AssistantJobJournal.loadKey()
        try AICommentAssessmentStore.persistWorkerAssessments(claims, draftClaims: replyClaims,
            baseline: scenario == "old draft" ? [draft] : [], current: [draft], discussions: discussions, userID: 3,
            target: target, assistant: .codex, model: "test", in: folder)
        #expect(AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: folder)
            == (scenario == "same source"))
        if scenario == "same source" || scenario == "likely human" {
            // A new coordinator after app restart must use the same saved result, even with another model.
            let reopened = AICommentOriginCoordinator(directory: folder, assess: { _, _, _, _, _, _ in
                Issue.record("The source was already evaluated by the reply worker")
                throw AICommentOriginAssessor.AssessmentError.failed
            }, fetchCurrent: { _ in [note] }, isCurrent: { _, _, _, _ in true })
            reopened.schedule(target: target, notes: [note], assistant: .claude, model: "other model")
            let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: 1, iid: 2)
            #expect(!reopened.isChecking(work: work))
            #expect(AICommentAssessmentStore.displayResult(for: note, host: target.host, projectID: 1, iid: 2,
                username: target.username, in: folder)?.classification == claims[0].classification.rawValue)
        }
    }

    @Test func slashCommandsEvenInsideCodeFencesAreNotAutomaticallyPublished() throws {
        let body = #"{"id":1,"author_id":3,"note":"Fixed.\n```\n/merge\n```","discussion_id":"abc"}"#
        let draft = try JSONDecoder().decode(GitLabDraftNote.self, from: Data(body.utf8))
        #expect(!AICommentAssessmentStore.safeForAutomaticPublication(draft))
        let indented = try JSONDecoder().decode(GitLabDraftNote.self,
            from: Data(body.replacingOccurrences(of: "/merge", with: "  /approve").utf8))
        #expect(!AICommentAssessmentStore.safeForAutomaticPublication(indented))
    }

}
