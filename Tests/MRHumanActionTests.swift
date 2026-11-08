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
                     mayPush: Bool = false, executable: Bool = true) -> MergeRequestBoardSnapshot.Row {
        let job = execution.map { execution in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Example run", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: mayPush,
                execution: execution, taskPrompt: executable ? "Review this MR" : nil,
                mergeRequestURL: executable ? item.url : nil, expectedHeadSHA: expectedHead)
        }
        return .init(item: item, latestJob: job, intents: [])
    }

    private func stoppedHistoryRow(state: AssistantJobExecution.State, manualDraft: Bool = false,
                                   completedMatchesJob: Bool = true, independentFailure: Bool = false) throws -> MergeRequestBoardSnapshot.Row {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.isAuthored = true
        item.draftCount = manualDraft ? 1 : 0
        item.humanActionRequired = manualDraft ? true : nil
        let base = row(item, execution: .init(state: state, error: "Historical failure"), expectedHead: "head")
        let job = try #require(base.latestJob)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        var intents = [MRTodoIntent(id: UUID(), target: target, kind: .pipeline, state: .completed,
            todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: "head",
            jobID: completedMatchesJob ? job.id : UUID(), updatedAt: Date())]
        if independentFailure {
            intents.append(.init(id: UUID(), target: target, kind: .conflict, state: .failed,
                todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: "head",
                error: "Conflict verification failed", updatedAt: Date()))
        }
        return .init(item: item, latestJob: job, intents: intents)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked], [false, true])
    func completedHistoricalJobCannotReviveAttentionOrReplaceManualDraftPublication(state: AssistantJobExecution.State,
                                                                                   manualDraft: Bool) throws {
        let row = try stoppedHistoryRow(state: state, manualDraft: manualDraft)
        #expect(!row.hasIndependentStoppedWork)
        #expect(row.needsAttention == manualDraft)
        let action = MRHumanAction(row: row, assistantReady: true)
        if manualDraft {
            #expect(action?.kind == .publication && action?.action == .reviewDrafts)
        } else {
            #expect(action == nil)
        }
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked])
    func unrelatedCompletedIntentDoesNotHideARealStoppedJob(state: AssistantJobExecution.State) throws {
        let row = try stoppedHistoryRow(state: state, manualDraft: true, completedMatchesJob: false)
        #expect(row.hasIndependentStoppedWork && row.needsAttention)
        #expect(MRHumanAction(row: row, assistantReady: true)?.action == .retryRun)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked])
    func completedHistoricalJobDoesNotReplaceAnIndependentFailedIntent(state: AssistantJobExecution.State) throws {
        let row = try stoppedHistoryRow(state: state, independentFailure: true)
        #expect(row.hasIndependentStoppedWork && row.needsAttention)
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.action == .retryIntent)
        #expect(action.detail == "Conflict verification failed")
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

    @Test(arguments: [AssistantJobExecution.State.blocked, .failed])
    func stoppedRunOffersRetryWithoutLosingTheActualReasonOrDraftPriority(_ state: AssistantJobExecution.State) throws {
        var item = item()
        item.draftCount = 3
        let reason = "The source branch could not be pushed because push permission is off."
        let execution = AssistantJobExecution(state: state, summary: "[MR](https://gitlab.example.test/mr/2)\n\nThree comments checked.\n\n\(reason)")
        let action = try #require(MRHumanAction(row: row(item, execution: execution), assistantReady: true))
        #expect(action.kind == .blockedRun)
        #expect(action.action == .retryRun)
        #expect(action.detail == reason)
        #expect(String(localized: action.actionLabel) == "Try again")
    }

    @Test(arguments: [AssistantJobExecution.State.interrupted, .cancelled])
    func interruptedOrCancelledRunOffersRetry(_ state: AssistantJobExecution.State) throws {
        let action = try #require(MRHumanAction(row: row(item(), execution: .init(state: state)), assistantReady: true))
        #expect(action.kind == .interruptedRun)
        #expect(action.action == .retryRun)
        #expect(action.detail == nil)
    }

    @Test func cancelledWorkDoesNotOverrideAnExplicitNeutralAttentionProjection() {
        var item = item()
        item.humanActionRequired = false
        #expect(MRHumanAction(row: row(item, execution: .init(state: .cancelled)), assistantReady: true) == nil)
    }

    @Test func aLegacyRunWithoutExecutableInstructionsKeepsItsResultAction() throws {
        let action = try #require(MRHumanAction(row: row(item(), execution: .init(state: .failed), executable: false),
                                              assistantReady: true))
        #expect(action.action == .reviewRun)
        #expect(String(localized: action.actionLabel) == "View run result")
    }

    @Test func aCompletedRunDoesNotReplaceTheCurrentPublicationDecisionWithRetry() throws {
        var item = item()
        item.draftCount = 1
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .succeeded)), assistantReady: true))
        #expect(action.kind == .publication && action.action == .reviewDrafts)
    }

    @Test func aSuccessfulWorkerStillShowsTheApplicationsExactCompletionFailure() throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        let reason = "The worker finished, but its result is not covered by current feedback evidence."
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .followUp, state: .failed, todoIDs: [], noteIDs: [42], sourceEvents: [], request: request,
            headSHA: "head", error: reason, updatedAt: Date())
        let base = row(item, execution: .init(state: .succeeded))
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: base.latestJob, intents: [intent])
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.action == .retryIntent)
        #expect(action.detail == reason)
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

    @Test(arguments: [false, true])
    func rawVerificationAndProcessDiagnosticsNeverBecomeTheCardHeadline(worker: Bool) throws {
        var item = item()
        let diagnostic = "Current account and headSHA match the snapshot. Technical evidence is missing."
        item.draftProofRecoveryFailure = worker ? nil : diagnostic
        item.draftCount = worker ? 0 : 1
        let row = row(item, execution: worker ? .init(state: .blocked, error: diagnostic) : nil)
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true)
        let action = try #require(model.humanAction)
        #expect(model.message == String(localized: action.message))
        #expect(!model.message.contains("headSHA"))
        #expect(action.detail == diagnostic)
    }

    @Test(arguments: ["The test described in this reply could not be confirmed. Check the reply before publishing.", "  ", String(repeating: "x", count: 201)])
    func onlyBoundedHumanSummariesBecomeHeadlines(summary: String) throws {
        var item = item()
        item.draftCount = 2
        item.draftProofRecoveryFailure = "Current account and commit match, but independent evidence is missing."
        item.draftProofRecoverySummary = summary
        let row = row(item)
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false, assistantReady: true)
        let action = try #require(model.humanAction)
        #expect(model.message == (AgentExplanation.summary(summary) ?? String(localized: action.message)))
        #expect(action.action == .retryDraftVerification)
        #expect(action.detail == item.draftProofRecoveryFailure)
    }

    @Test func failedDraftProofRecoveryOffersVerificationWithoutPublication() throws {
        var item = item()
        item.draftCount = 1
        let reason = "The remote file changed after this draft was prepared."
        item.draftProofRecoveryFailure = reason
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .verificationFailure)
        #expect(action.detail == reason)
        #expect(String(localized: action.actionLabel) == "Verify drafts again")
    }

    @Test func recoveringDraftProofDoesNotAskForManualPublication() {
        var item = item()
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
    }

    @Test func recoveringDraftProofKeepsAnIndependentBlockedRunAction() throws {
        var item = item()
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion", phase: .checking)
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .blocked, blocker: "Tests could not run.")), assistantReady: true))
        #expect(action.kind == .blockedRun)
    }

    @Test func recoveringDraftProofKeepsAnIndependentFailedIntentAction() throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion", phase: .checking)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .pipeline, state: .failed, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
            headSHA: "head", error: "Pipeline ownership could not be verified.", updatedAt: Date())
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [intent])
        let action = try #require(MRHumanAction(row: snapshot, assistantReady: true))
        #expect(action.kind == .intent && action.action == .retryIntent)
        #expect(action.detail == intent.error)
    }

    @Test(arguments: [false, true])
    func unboundFailedFollowUpWaitsNeutrallyOnlyForExplicitCurrentReconciliation(checkingReconciliation: Bool) throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.isAuthored = true
        item.draftCount = 4
        item.draftProofRecoveryChecking = true
        item.observedDiscussionFingerprint = "discussion"
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion",
            semanticContextFingerprint: request.semanticContextFingerprint, readOnlyReconciliation: checkingReconciliation,
            phase: .checking, pendingDraftCount: 4)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .followUp, state: .failed, todoIDs: [], noteIDs: [42], sourceEvents: [], request: request,
            headSHA: "old-head", error: "Earlier attempt", updatedAt: Date())
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [intent])
        #expect(snapshot.hasIndependentStoppedWork == !checkingReconciliation)
        #expect(snapshot.needsAttention == !checkingReconciliation)
        #expect((MRHumanAction(row: snapshot, assistantReady: true) == nil) == checkingReconciliation)
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
        #expect(String(localized: action.message) == "2 comments still need verification before automatic publication.")
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
