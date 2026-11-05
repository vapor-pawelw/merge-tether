import Foundation
import Testing
@testable import GitLabTodos

struct AttentionAutomationTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 1, iid: 2)

    private func item() throws -> MergeRequestAttentionMonitor.Item {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"id":2,"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Fix","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"abc","source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main","labels":[]}"#.utf8))
        return .init(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL,
                     mergeRequest: request, isAuthored: true)
    }

    @Test func conflictVisibilityFollowsScopeAndSettingWithoutLosingTheReason() throws {
        var original = try item()
        original.hasConflict = true
        var config = AutomationSettings()
        config.scope.mode = .selected
        config.conflictTasksEnabled = true
        #expect(original.requiringUserAttention(automation: config, target: target).hasConflict)
        config.scope[target] = .active
        #expect(!original.requiringUserAttention(automation: config, target: target).needsAttention)
        #expect(original.hasConflict)
        config.conflictTasksEnabled = false
        #expect(original.requiringUserAttention(automation: config, target: target).hasConflict)
        config.conflictTasksEnabled = true
        config.scope[target] = .paused
        #expect(original.requiringUserAttention(automation: config, target: target).hasConflict)
    }

    @Test func mixedReasonsKeepDraftsAndFailedAutomationVisible() throws {
        var original = try item()
        original.hasConflict = true
        original.draftCount = 2
        original.reReviewUnconfirmed = true
        var config = AutomationSettings()
        config.conflictTasksEnabled = true
        let visible = original.requiringUserAttention(automation: config, target: target)
        #expect(visible.needsAttention && visible.draftCount == 2 && visible.reReviewUnconfirmed)
        #expect(!visible.hasConflict)
        #expect(original.requiringUserAttention(automation: config, target: target, conflictTaskFailed: true).hasConflict)
        original.isAuthored = false
        #expect(original.requiringUserAttention(automation: config, target: target).hasConflict)
    }

    @Test func automaticFeedbackHidesOnlyCoveredDiscussionReasons() throws {
        var original = try item()
        original.needsDiscussion = true
        original.needsChanges = true
        original.feedback = [.init(id: 9, author: .init(id: 8, username: "alice", name: "Alice"),
                                   system: false, resolvable: true, resolved: false, resolvedBy: nil)]
        var config = AutomationSettings()
        config.workflowRules[.newDiscussion].mode = .assistant
        let visible = original.requiringUserAttention(automation: config, target: target)
        #expect(!visible.needsDiscussion && visible.feedback.isEmpty)
        #expect(visible.needsChanges)
        #expect(!original.requiringUserAttention(automation: config, target: target, feedbackOwnedAutomatically: true).needsChanges)
        config.workflowRules[.newDiscussion].mode = .notify
        #expect(original.requiringUserAttention(automation: config, target: target).needsDiscussion)
        config.workflowRules[.newDiscussion].mode = .assistant
        config.workflowRules[.newDiscussion].projects = "g/other"
        #expect(original.requiringUserAttention(automation: config, target: target).needsDiscussion)
        config.workflowRules[.newDiscussion].projects = ""
        #expect(original.requiringUserAttention(automation: config, target: target, failedTriggers: [.newDiscussion]).needsDiscussion)
    }

    @Test func pipelineAutomationPreservesOwnershipConfirmationAndFailures() throws {
        var original = try item()
        original.failedPipeline = true
        var config = AutomationSettings()
        config.workflowRules[.pipelineFailure].mode = .assistant
        #expect(original.requiringUserAttention(automation: config, target: target).failedPipeline)
        #expect(!original.requiringUserAttention(automation: config, target: target, pipelineOwnedAutomatically: true).needsAttention)
        original.needsPipelineHandoff = true
        #expect(original.requiringUserAttention(automation: config, target: target).failedPipeline)
        original.needsPipelineHandoff = false
        #expect(original.requiringUserAttention(automation: config, target: target, failedTriggers: [.pipelineFailure]).failedPipeline)
        config.workflowRules[.pipelineFailure].mode = .off
        #expect(original.requiringUserAttention(automation: config, target: target).failedPipeline)
    }
}
