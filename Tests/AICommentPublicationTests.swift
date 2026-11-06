import Foundation
import Testing
@testable import GitLabTodos

struct AICommentPublicationTests {
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
        #expect(try !eligible(note + "," + ownReply))
        var resolving = draft
        resolving.resolveDiscussion = true
        #expect(try !eligible(note, draft: resolving))
        let general = try decoder.decode(GitLabDraftNote.self,
            from: Data(draftJSON.replacingOccurrences(of: "\"abc\"", with: "null").utf8))
        #expect(try !eligible(note, draft: general))
    }
    @Test func assessmentInstructionsUseDirectContentBoundEvidenceWithoutPluginTools() {
        let instructions = AICommentAssessmentStore.recordingInstructions(host: "gitlab.example.org", projectID: 1, iid: 2)
        #expect(instructions.contains("exact UTF-8 source body"))
        #expect(instructions.contains("atomically write"))
        #expect(instructions.contains("1-2-<noteID>.json"))
        #expect(!instructions.contains("record_ai_comment_assessment"))
        #expect(!instructions.contains("read_merge_request"))
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
