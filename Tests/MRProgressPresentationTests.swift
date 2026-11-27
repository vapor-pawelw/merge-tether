import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MRProgressPresentationTests {
    @Test(arguments: [false, true])
    func claimLeavesCommentReviewAvailableAsASecondaryAction(_ awaitsClaim: Bool) throws {
        let request = try mergeRequestWithAutoMerge(head: String(repeating: "a", count: 40))
        let item = MergeRequestAttentionMonitor.Item(id: request.mergeRequestID, title: request.title,
            url: request.webURL, requiresCommentReview: true,
            commentReviewSnapshot: .init(request: request, discussions: []), mergeRequest: request, isAuthored: true)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [],
            attentionPresentation: .init(evidence: item, humanActionRequired: true),
            assignmentClaimState: awaitsClaim ? .awaitingConfirmation : nil)
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true)

        #expect(model.humanAction?.kind == .commentReview)
        #expect(model.confirmationOffers.finishCommentReview)
        #expect(model.showsAdditionalCommentReview == awaitsClaim)
    }

    @Test(arguments: ["finished", "confirmation", "cli", "quietRead", "visibleRead", "idle"])
    func cardActivityChoosesOneState(_ scenario: String) throws {
        let original = presentation(scenario == "cli" ? "followUp" : "idle", state: scenario == "cli" ? .queued : nil)
        var item = original.row.item
        if scenario == "finished" {
            let request = try mergeRequestWithAutoMerge()
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            json["state"] = "merged"
            item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: original.row.latestJob, intents: original.row.intents)
        let model = MRCardPresentation(row: row, reviewingContext: original.reviewingContext, allowsRemoval: false,
            assistantReady: true, confirmationState: ["finished", "confirmation"].contains(scenario) ? .publishing : nil,
            isRefreshingAttention: scenario != "idle", showsReadProgress: scenario != "quietRead", cliHoldKind: .rateLimited)
        switch (scenario, model.cardActivity) {
        case ("finished", .finished), ("confirmation", .working), ("cli", .waitingOnCLI),
             ("quietRead", .readCheck), ("visibleRead", .readCheck), ("idle", .idle): break
        default: Issue.record("Unexpected activity for \(scenario): \(model.cardActivity)")
        }
        #expect(model.working == ["confirmation", "visibleRead"].contains(scenario))
        #expect(model.actionsBlocked == (scenario != "idle"))
    }

    @Test func aHeldQueueHasAFactualPausedStatusWithoutASpinner() {
        let queued = presentation("followUp", state: .queued)
        let model = MRCardPresentation(row: queued.row, reviewingContext: queued.reviewingContext,
            allowsRemoval: false, assistantReady: true, cliHoldKind: .rateLimited)
        #expect(!model.working && model.actionsBlocked)
        #expect(model.status == "Paused: CLI usage limit")
    }

    @Test func quietGlobalPollingKeepsTheIdleStatusStable() {
        let idle = presentation("idle")
        let model = MRCardPresentation(row: idle.row, reviewingContext: idle.reviewingContext,
            allowsRemoval: false, assistantReady: true, isRefreshingAttention: true, showsReadProgress: false)
        #expect(!model.working && model.status == "Monitoring MR")
        #expect(model.activity == nil)
    }

    @Test func repeatedBackgroundRefreshesKeepReviewingCardsIdle() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.reviewingProgress = .current
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let idle = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: true, assistantReady: true, showsReadProgress: false)
        for refreshing in [true, false, true, false] {
            let polled = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
                allowsRemoval: true, assistantReady: true, isRefreshingAttention: refreshing, showsReadProgress: false)
            #expect(!polled.working && polled.activity == nil)
            #expect(polled.status == idle.status)
        }
    }

    @Test(arguments: [true, false])
    func pendingCommentReviewShowsTheStepOrderWithCommentReviewCurrent(_ authored: Bool) {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!, isAuthored: authored)
        let idle = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        #expect(MRCardPresentation(row: idle, reviewingContext: ReviewingContext(row: idle), allowsRemoval: !authored,
            assistantReady: true).stepChain == nil)
        item.drafts = attentionFixtureDrafts(1)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: !authored,
            assistantReady: true)
        let chain = model.stepChain
        #expect(chain?.current == 0)
        #expect(chain?.steps.map { String(localized: $0) } == (authored
            ? ["Comment review", "Re-review readiness", "Merge checks"]
            : ["Comment review", "Review verdict and discussion checks", "Approval"]))
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: model)
        #expect(phone.presentation?.steps == chain?.steps.map { String(localized: $0) })
        #expect(phone.presentation?.currentStep == 0)
        #expect(phone.presentation?.nextStep == model.nextStep)
    }

    @Test func anIdleAuthoredMRAlwaysHasAStatusWithoutInventingWork() {
        let model = presentation("idle")
        #expect(model.status == "Monitoring MR")
        #expect(!model.working && !model.busy && model.humanAction == nil)
    }

    @Test(arguments: [false, true])
    func independentStoppedWorkDoesNotAcquireFakeReviewPreparationWhileProofIsChecked(_ aiChecking: Bool) {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.drafts = attentionFixtureDrafts(1)
        item.draftProofRecoveryChecking = true
        item.aiOriginChecking = aiChecking
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Stopped work", prompt: "Fix", createdAt: Date(), allowsPush: false,
            execution: .init(state: .blocked, blocker: "The assigned tests could not run"),
            taskPrompt: "Fix", mergeRequestURL: item.url)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let context = ReviewingContext(row: row, workflowState: .queued)
        #expect(context.nextStep == .automaticReview && row.hasIndependentStoppedWork && row.needsAttention)
        let model = MRCardPresentation(row: row, reviewingContext: context, allowsRemoval: true,
            assistantReady: true, showsReadProgress: false)
        #expect(model.busy == aiChecking)
        #expect(model.working)
        #expect(model.status == (aiChecking ? "Assessing AI assistance · Codex" : "Checking replies · Codex"))
        if !aiChecking { #expect(model.humanAction?.kind == .blockedRun) }
    }

    @Test func actualMergeProgressRemainsVisibleAndBlocksActionsDuringQuietReads() throws {
        let request = try mergeRequestWithAutoMerge()
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, mergeRequest: request)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false,
            assistantReady: true, showsReadProgress: false, automaticMergeProgress: true)
        #expect(model.busy && model.working && model.actionsBlocked)
        #expect(model.status == "Merging MR" && model.actionLabel == nil)
        #expect(model.mergeStage == .merging && model.mergeActivity == model.activity)
    }

    @Test func aGitLabAutoMergeScheduleShowsAQueuedStatusWithoutASpinner() throws {
        let request = try mergeRequestWithAutoMerge()
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: request.projectID, iid: request.iid),
            title: request.title, url: request.webURL, mergeRequest: request, isAuthored: true)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, showsReadProgress: false)
        #expect(model.status == "Queued for auto-merge")
        #expect(model.mergeStage == .queued)
        #expect(!model.working && model.activity == nil && model.humanAction == nil)
    }

    @Test(arguments: [true, false])
    func confirmedTrainMembershipAppliesOnlyToTheMatchingRequest(_ sameContext: Bool) throws {
        let request = try mergeRequestWithAutoMerge()
        let observed = try mergeRequestWithAutoMerge(sourceBranch: sameContext ? "feature" : "previous")
        let status = AuthoredMergeRequestStatus(request: observed, approvals: nil, discussionsResolved: nil,
            projectRequiresResolvedDiscussions: nil, autoMergeEnabled: false, submissionState: .inTrain)
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, mergeStatus: status)
        #expect(model.mergeStage == (sameContext ? .inTrain : .queued))
        #expect(model.status == (sameContext ? "In merge train" : "Queued for auto-merge"))
        #expect(!model.working && model.humanAction == nil)
    }

    @Test(arguments: [MergeSubmissionState.uncertain, .changed])
    func anUnconfirmedSubmissionDoesNotShowAQueueBanner(_ state: MergeSubmissionState) throws {
        let request = try mergeRequestWithAutoMerge()
        let status = AuthoredMergeRequestStatus(request: request, approvals: nil, discussionsResolved: nil,
            projectRequiresResolvedDiscussions: nil, autoMergeEnabled: false, submissionState: state)
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, mergeStatus: status)
        #expect(model.mergeStage == nil)
        #expect(model.confirmedSubmission == state)
    }

    private func mergeRequestWithAutoMerge(sourceBranch: String = "feature", head: String? = nil) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
            {"project_id":1,"iid":2,"author":{"id":7,"username":"author","name":"Author"},
            "title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2",
            "state":"opened","draft":false,"source_branch":"\(sourceBranch)","target_branch":"main","labels":[],
            "merge_when_pipeline_succeeds":true,"sha":\(head.map { "\"\($0)\"" } ?? "null")}
            """.utf8))
    }

    @Test(arguments: ["merged", "closed"], [AssistantJobExecution.State.running, .blocked])
    func finishedMRPresentationIgnoresStaleAttentionAndWorkerProgress(_ state: String, _ jobState: AssistantJobExecution.State) throws {
        let url = try #require(URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2"))
        let object: [String: Any] = ["project_id": 1, "iid": 2,
            "author": ["id": 7, "username": "author", "name": "Author"],
            "title": "Example", "web_url": url.absoluteString, "state": state, "draft": false,
            "source_branch": "feature", "target_branch": "main", "labels": []]
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example", url: url)
        item.mergeRequest = request
        item.isAuthored = state == "merged"
        item.catalogIssues.insert(.conflict)
        item.catalogIssues.insert(.failedPipeline)
        item.manualMergeAvailable = true
        item.drafts = attentionFixtureDrafts(1)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Earlier work", prompt: "Check", createdAt: Date(), allowsPush: false,
            execution: .init(state: jobState), workflow: .review)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: !item.isAuthored, assistantReady: true,
            confirmationState: jobState == .running ? .publishing : nil,
            automaticPipelineProgress: jobState == .running, automaticMergeProgress: true)
        #expect(!model.busy && !model.working)
        #expect(model.mergeStage == nil)
        #expect(model.actionsBlocked)
        #expect(model.humanAction == nil && model.actionLabel == nil && model.nextStep == nil)
        #expect(model.chips.isEmpty)
        #expect(model.status == (state == "merged" ? "Merged. Automation is off." : "Closed. Automation is off."))
    }

    @Test func waitingForReviewerDoesNotShowWork() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: request.webURL, mergeRequest: request, isAuthored: true)
        item.observedDiscussionFingerprint = "text"
        item.authorFeedbackStatus = .init(head: request.sha!, fingerprint: "text",
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: [.init(id: 3, discussionID: "thread", reviewerID: 4, reviewerUsername: "reviewer",
                state: .waitingAcceptance, reason: nil, waitingForReviewers: ["reviewer"])])
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, showsReadProgress: false)
        #expect(!model.working && !model.busy && model.activity == nil)
        #expect(model.status == "Awaiting confirmation from @reviewer")
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func agentActivityUsesTheCurrentRunAndItsRecordedStageStart(_ state: AssistantJobExecution.State) throws {
        let model = presentation("followUp", state: state, showsReadProgress: false)
        let job = try #require(model.row.latestJob)
        let activity = try #require(model.activity)
        #expect(model.working && activity.jobID == job.id)
        #expect(activity.startedAt == (state == .running ? job.execution?.startedAt : job.createdAt))
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running, .succeeded])
    func cardShowsTheReviewReasonForAnActiveRun(_ state: AssistantJobExecution.State) throws {
        let request = try mergeRequestWithAutoMerge(head: String(repeating: "a", count: 40))
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: request.projectID, iid: request.iid),
            title: request.title, url: request.webURL, mergeRequest: request)
        let host = "gitlab.example.test"
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: request.projectID, iid: request.iid), username: "me", workspace: "",
            access: .gitLabRead), title: "Review", prompt: "", createdAt: .now, allowsPush: false,
            execution: .init(state: state), mergeRequestURL: request.webURL, workflow: .review,
            manual: false, expectedHeadSHA: request.sha)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let card = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: true, assistantReady: true)
        let update = MergeWorkflowActivityEntry(id: "review-update", event: .init(kind: .reviewUpdate,
            mergeRequest: request, identity: "review-update", context: "Source changed",
            reviewUpdateReasons: [.headChanged]), createdAt: job.createdAt, host: host,
            user: .init(id: 3, username: "me"), state: .running, assistantJobID: job.id)

        #expect(card.reviewLaunchReason(workflows: [update], intents: [])
            == (state.isActive ? "Source commit (HEAD) changed" : nil))
        #expect(card.reviewLaunchReason(workflows: [], intents: []) == nil)
    }

    private func presentation(_ stage: String, state: AssistantJobExecution.State? = nil,
                              showsReadProgress: Bool = true, assistant: AutomationAssistant = .codex) -> MRCardPresentation {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        var confirmation: MergeRequestAttentionMonitor.ConfirmationState?
        switch stage {
        case "publishing": confirmation = .publishing
        case "approving": confirmation = .approving
        case "replies": item.draftProofRecoveryChecking = true
        case "feedback": item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .checking)
        case "ai": item.aiOriginChecking = true
        case "readiness": item.reReviewReadiness = .checking
        default: break
        }
        let job = state.map { state in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me",
                workspace: "", access: .gitLabRead), title: "Example", prompt: "", createdAt: Date(),
                allowsPush: stage == "conflict",
                pipelineReservation: stage == "pipeline" ? .init(host: "gitlab.example.test", projectID: 1, mergeRequestIID: 2, pipelineID: 3) : nil,
                execution: .init(state: state, startedAt: state == .running ? Date(timeIntervalSince1970: 1_000) : nil), workflow: stage == "review" ? .review : (stage == "followUp" ? .followUp : nil))
        }
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        return .init(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false,
            assistantReady: true, confirmationState: confirmation,
            automaticConflictProgress: state == nil && stage == "conflict",
            automaticPipelineProgress: state == nil && stage == "pipeline",
            conflictReceipts: stage == "conflictReceipt" ? [.init(host: "gitlab.example.test", userID: 3,
                projectID: 1, iid: 2, sourceSHA: "head", targetSHA: "target", allowsPush: false, jobID: job?.id)] : [],
            showsReadProgress: showsReadProgress, assistant: assistant)
    }

    @Test(arguments: ["replies", "feedback", "ai", "readiness"])
    func backgroundReadOnlyChecksShowWorkEvenDuringQuietPolling(_ stage: String) {
        let model = presentation(stage, showsReadProgress: false)
        #expect(model.working && model.status != nil)
        #expect(model.busy && model.actionsBlocked)
    }

    @Test(arguments: ["replies", "feedback", "ai", "readiness"], [AutomationAssistant.codex, .claude])
    func semanticChecksNameTheAgentOnMacAndPhone(_ stage: String, _ assistant: AutomationAssistant) {
        let model = presentation(stage, showsReadProgress: false, assistant: assistant)
        #expect(model.status?.hasSuffix(" · " + String(localized: assistant.displayName)) == true)
        #expect(model.activityEffect == .aiCheck)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(model.row.item, account: "me@host"), model: model)
        #expect(phone.presentation?.status == model.status)
        #expect(phone.presentation?.statusSymbol == MRActionCTA.verifyFeedback.symbol)
    }

    @Test(arguments: ["publishing", "approving", "idle", "pipeline"])
    func deterministicWorkDoesNotClaimToUseAnAgent(_ stage: String) {
        let model = presentation(stage, assistant: .claude)
        #expect(model.activityEffect == nil)
        #expect(model.status?.contains("CLI") == false)
    }

    @Test func activeJobsKeepTheirRecordedProviderWhenSettingsChange() {
        let original = presentation("review", state: .running)
        let model = MRCardPresentation(row: original.row, reviewingContext: original.reviewingContext,
            allowsRemoval: false, assistantReady: true, assistant: .claude)
        #expect(model.status == "Running review · Codex")
        #expect(model.activityEffect == MRActionCTA.runReview.effect)
    }

    @Test func quietReviewingChecksExplainTheReadWithoutInventingAHumanAction() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.reviewingProgress = .checking
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: true, assistantReady: true, isRefreshingAttention: true, showsReadProgress: false)
        #expect(model.working && model.status == "Checking review" && model.nextStep == nil)
        #expect(model.activityEffect == nil)
        #expect(model.actionsBlocked && model.actionLabel == nil)
    }

    @Test(arguments: ["publishing", "approving", "conflict", "pipeline"])
    func realActionsKeepTheirProgressDuringQuietBackgroundReads(_ stage: String) {
        let model = presentation(stage, showsReadProgress: false)
        #expect(model.working && model.status != nil)
        #expect(model.actionsBlocked)
    }

    @Test(arguments: [
        ("publishing", "Publishing comments"), ("approving", "Approving MR"),
        ("replies", "Checking replies"), ("feedback", "Checking whether reviewer comments are addressed"),
        ("ai", "Assessing AI assistance"), ("readiness", "Checking review readiness"),
        ("conflict", "Preparing conflict fix"), ("pipeline", "Handling pipeline")
    ])
    func showsTheCurrentCheckWithoutInventingAHumanTask(stage: String, expected: String) {
        let model = presentation(stage)
        #expect(model.working)
        let usesAgent = !["publishing", "approving", "pipeline"].contains(stage)
        #expect(model.status == expected + (usesAgent ? " · Codex" : ""))
        #expect(model.humanAction == nil && model.actionLabel == nil)
    }

    @Test(arguments: [
        ("review", "Running review"), ("followUp", "Handling feedback"),
        ("conflict", "Resolving conflicts"), ("conflictReceipt", "Resolving conflicts"), ("pipeline", "Handling pipeline"), ("unknown", "Running agent")
    ])
    func runningJobsIdentifyTheirTaskWithoutParsingAgentText(stage: String, expected: String) {
        let model = presentation(stage, state: .running)
        #expect(model.status == expected + " · Codex")
        #expect(model.activityEffect == .agent)
    }

    @Test(arguments: ["review", "followUp", "pipeline", "conflict", "unknown"])
    func queuedJobsDoNotClaimThatTheAgentHasStarted(stage: String) {
        let model = presentation(stage, state: .queued)
        #expect(model.status == "Queued for agent · Codex")
        #expect(model.activityEffect == .agent)
    }
}
