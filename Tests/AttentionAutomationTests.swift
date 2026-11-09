import Foundation
import Testing
@testable import GitLabTodos

struct AttentionAutomationTests {
    @MainActor @Test(arguments: [AuthorFeedbackPolicy.State.ready, .disabled])
    func verifiedCommentsDoNotDismissAnIndependentGitLabChangeRequest(_ state: AuthorFeedbackPolicy.State) throws {
        var original = try item()
        let request = try #require(original.mergeRequest)
        original.needsChanges = true
        original.needsDiscussion = true
        original.observedDiscussionFingerprint = "current"
        original.feedback = [.init(id: 9, author: .init(id: 8, username: "alice", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Please cover retries")]
        original.authorFeedbackStatus = .init(head: "abc", fingerprint: "current",
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: [.init(id: 9, discussionID: "thread", reviewerID: 8, reviewerUsername: "alice",
                state: state, reason: "The change and reply are verified", waitingForReviewers: [], sourceNoteID: 9)],
            addressedNoteIDs: [9])
        let visible = original.presentingVerifiedAuthorFeedback()
        #expect(visible.needsChanges && visible.feedback.isEmpty && !visible.needsDiscussion)
        let row = MergeRequestBoardSnapshot.Row(item: visible, latestJob: nil, intents: [])
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.action == .reviewFeedback)
        #expect(action.explanation == "GitLab reports requested changes. Review the current feedback.")
        #expect(original.needsChanges && original.feedback.count == 1)
        original.feedback.append(.init(id: 10, author: .init(id: 8, username: "alice", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Another request"))
        #expect(original.presentingVerifiedAuthorFeedback().needsChanges)
    }

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

    @Test(arguments: ["verified", "head", "context", "legacy-context", "discussion", "reply", "follow-up", "draft", "pending-draft", "checking", "needs-work", "other-reviewer", "reviewers-unavailable", "reviewers-empty", "ignored", "uncovered"])
    func verifiedWaitingForReviewerDoesNotRequireHumanCodeWork(_ scenario: String) throws {
        var original = try item()
        let storedRequest = try #require(original.mergeRequest)
        let encoded = try JSONEncoder().encode(storedRequest)
        let json = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(json as? [String: Any])
        object["detailed_merge_status"] = "requested_changes"
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        let head = try #require(request.sha)
        original.mergeRequest = request
        original.needsChanges = true
        original.changeRequestReviewers = scenario == "reviewers-unavailable" ? nil
            : scenario == "reviewers-empty" ? [] : scenario == "other-reviewer" ? ["alice", "bob"] : ["alice"]
        original.reReviewRequested = true
        original.observedDiscussionFingerprint = "current-discussion"
        original.authorFeedbackStatus = .init(head: scenario == "head" ? "old-head" : head,
            fingerprint: scenario == "discussion" ? "old-discussion" : "current-discussion",
            semanticContextFingerprint: scenario == "legacy-context" ? nil
                : scenario == "context" ? "old-context" : request.semanticContextFingerprint,
            phase: scenario == "checking" ? .checking : .complete,
            findings: [.init(id: 9, discussionID: "thread", reviewerID: 8, reviewerUsername: "alice",
                state: .waitingAcceptance, reason: "The correction is verified; reviewer acceptance is pending",
                waitingForReviewers: ["alice"])],
            pendingDraftCount: scenario == "pending-draft" ? 1 : 0,
            followUpNoteIDs: scenario == "follow-up" ? [9] : [],
            replyNoteIDs: scenario == "reply" ? [9] : [], addressedNoteIDs: [9])
        if scenario == "draft" { original.draftCount = 1 }
        if scenario == "ignored" { original.authorFeedbackStatus?.ignoredNoteIDs = [99] }
        if scenario == "uncovered" {
            original.feedback = [.init(id: 40, author: .init(id: 9, username: "bob", name: nil),
                system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "A different request")]
        }
        if scenario == "needs-work" {
            original.authorFeedbackStatus?.findings.append(.init(id: 10, discussionID: "other-thread", reviewerID: 8,
                reviewerUsername: "alice", state: .needsChanges, reason: "Another correction remains",
                waitingForReviewers: ["alice"]))
        }
        var config = AutomationSettings()
        config.applyPreset(.full, for: .codex)
        let visible = original.presentingVerifiedAuthorFeedback().requiringUserAttention(automation: config,
            target: target, feedbackOwnedAutomatically: false)
        #expect(visible.needsChanges == (scenario != "verified"))
        #expect(visible.needsAttention == (scenario != "verified"))
        #expect(original.needsChanges)
        #expect(visible.mergeRequest?.detailedMergeStatus == "requested_changes")
        let serverStatus = AuthoredMergeRequestStatus(request: request, approvals: nil, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true)
        #expect(serverStatus.blockers.contains(.changesRequested))
        #expect(!serverStatus.mayAutoMerge && !visible.canOfferMerge(using: serverStatus))
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
