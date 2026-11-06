import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRHumanActionTests {
    private func item() -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: 1, iid: 2), title: "Example MR",
              url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
    }
    private func row(_ item: MergeRequestAttentionMonitor.Item,
                     execution: AssistantJobExecution? = nil, expectedHead: String? = nil,
                     mayPush: Bool = false) -> MergeRequestBoardSnapshot.Row {
        let job = execution.map { execution in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Example run", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: mayPush,
                execution: execution, expectedHeadSHA: expectedHead)
        }
        return .init(item: item, latestJob: job, intents: [])
    }

    @Test func aRunAllowedToPushMayHaveChangedTheHeadBeforeStopping() throws {
        var item = item()
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"pushed","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.draftCount = 2
        let reason = "The fix reached the branch but its tests could not start."
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .blocked, blocker: reason),
            expectedHead: "before-push", mayPush: true), assistantReady: true))
        #expect(action.kind == .blockedRun && action.detail == reason)
    }

    @Test(arguments: [MRHumanAction.Action.reviewApproval, .reviewMerge, .reviewDecision, .reviewHandoff])
    func humanDecisionsDoNotRequireSettingUpAnAssistant(_ expected: MRHumanAction.Action) throws {
        var item = item()
        item.needsDiscussion = true
        switch expected {
        case .reviewApproval: item.canApprove = true
        case .reviewMerge: item.needsMerge = true
        case .reviewDecision: item.canConfirmReReview = true
        default: item.needsPipelineHandoff = true
        }
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.action == expected)
    }

    @Test func automaticApprovalWithoutAnAssistantExplainsTheMissingSetup() throws {
        var item = item()
        item.autoApproveReady = true
        item.humanActionRequired = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .setupAssistant)
        #expect(action.action == .setupAssistant)
    }

    @Test func aCheckWithoutDraftsDoesNotInventAPublicationTask() throws {
        var item = item()
        item.requiresDiscussionRecheck = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .reviewDecision)
        #expect(action.action == .reviewFeedback)
    }

    @Test func anOldRunCannotReplaceTheCurrentPublicationDecision() throws {
        var item = item()
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"current","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.draftCount = 2
        let execution = AssistantJobExecution(state: .blocked, summary: "A failure on the previous revision.")
        let action = try #require(MRHumanAction(row: row(item, execution: execution, expectedHead: "previous"), assistantReady: true))
        #expect(action.kind == .publication && action.action == .reviewDrafts)
        #expect(action.detail == nil)
        item.draftCount = 0
        let previous = try #require(MRHumanAction(row: row(item, execution: execution, expectedHead: "previous"), assistantReady: true))
        #expect(previous.kind == .interruptedRun && previous.action == .reviewRun)
        #expect(previous.detail == nil)
    }

    @Test func blockedRunTakesPriorityOverDraftsAndShowsTheActualReason() throws {
        var item = item()
        item.draftCount = 3
        let reason = "The source branch could not be pushed because push permission is off."
        let execution = AssistantJobExecution(state: .blocked, summary: "[MR](https://gitlab.example.test/mr/2)\n\nThree comments checked.\n\n\(reason)")
        let action = try #require(MRHumanAction(row: row(item, execution: execution), assistantReady: true))
        #expect(action.kind == .blockedRun)
        #expect(action.action == .reviewRun)
        #expect(action.detail == reason)
        #expect(String(localized: action.actionLabel) == "View run result")
    }

    @Test(arguments: [AssistantJobExecution.State.interrupted, .cancelled])
    func interruptedRunRequiresAReviewOfTheRun(_ state: AssistantJobExecution.State) throws {
        let action = try #require(MRHumanAction(row: row(item(), execution: .init(state: state)), assistantReady: true))
        #expect(action.kind == .interruptedRun)
        #expect(action.action == .reviewRun)
        #expect(action.detail == nil)
    }

    @Test func draftCountAloneProducesAConcretePublicationReason() throws {
        var item = item()
        item.draftCount = 3
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .publication)
        #expect(action.action == .reviewDrafts)
        #expect(String(localized: action.message) == "3 comments need your review before publication.")
        #expect(action.detail == nil)
    }

    @Test func oneDraftUsesSingularLanguage() throws {
        var item = item()
        item.draftCount = 1
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(String(localized: action.message) == "1 comment needs your review before publication.")
    }

    @Test func uncheckedDraftsExplainWhyPublicationNeedsReview() throws {
        var item = item()
        item.draftCount = 2
        item.requiresDiscussionRecheck = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .uncheckedDrafts)
        #expect(action.action == .reviewDrafts)
        #expect(String(localized: action.message) == "2 drafts are not covered by current checks. Review them before publishing.")
    }

    @Test func verificationFailureHasAConcreteRetryActionWithoutInventingADetail() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .failed)
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .verificationFailure)
        #expect(action.action == .verifyFeedback)
        #expect(action.detail == nil)
        #expect(String(localized: action.actionLabel) == "Verify again")
    }

    @Test func missingAssistantUsesSetupOnlyWhenNoPublicationDecisionIsPending() throws {
        var item = item()
        item.needsDiscussion = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .setupAssistant)
        #expect(action.action == .setupAssistant)
    }

    @Test func feedbackShowsTheVerifiersActualOutstandingExpectation() throws {
        var item = item()
        let reason = "The reviewer still expects a response explaining why retries are safe."
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: nil, reviewerID: 7, reviewerUsername: "alice", state: .needsChanges,
                reason: reason, waitingForReviewers: ["alice"])])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .feedback)
        #expect(action.detail == reason)
    }

    @Test func quietSharedHumanProjectionOverridesAutomaticFlags() {
        var item = item()
        item.needsDiscussion = true
        item.failedPipeline = true
        item.humanActionRequired = false
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func activeAutomationIsQuietEvenWithOldFailureFlags(_ state: AssistantJobExecution.State) {
        var item = item()
        item.needsDiscussion = true
        item.humanActionRequired = true
        #expect(MRHumanAction(row: row(item, execution: .init(state: state)), assistantReady: true) == nil)
    }

    @Test func readOnlyCheckingAndPublicationAreQuiet() {
        var item = item()
        item.draftCount = 2
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .checking)
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
        item.authorFeedbackStatus = nil
        #expect(MRHumanAction(row: row(item), assistantReady: true, confirmationState: .publishing) == nil)
        #expect(MRHumanAction(row: row(item), assistantReady: true, confirmationState: .approving) == nil)
    }
}
