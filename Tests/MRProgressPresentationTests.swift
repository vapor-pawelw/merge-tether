import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRProgressPresentationTests {
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

    @Test func anIdleAuthoredMRAlwaysHasAStatusWithoutInventingWork() {
        let model = presentation("idle")
        #expect(model.status == "Monitoring MR")
        #expect(!model.working && !model.busy && model.humanAction == nil)
    }

    @Test(arguments: [false, true])
    func independentStoppedWorkDoesNotAcquireFakeReviewPreparationWhileProofIsChecked(_ aiChecking: Bool) {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.draftCount = 1
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
        #expect(model.status == (aiChecking ? "Assessing AI assistance" : "Checking replies"))
        if !aiChecking { #expect(model.humanAction?.kind == .blockedRun) }
    }

    @Test func actualMergeProgressRemainsVisibleAndBlocksActionsDuringQuietReads() {
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false,
            assistantReady: true, showsReadProgress: false, automaticMergeProgress: true)
        #expect(model.busy && model.working && model.actionsBlocked)
        #expect(model.status == "Merging MR" && model.actionLabel == nil)
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
        item.hasConflict = true
        item.failedPipeline = true
        item.needsMerge = true
        item.draftCount = 1
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Earlier work", prompt: "Check", createdAt: Date(), allowsPush: false,
            execution: .init(state: jobState), workflow: .review)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: !item.isAuthored, assistantReady: true,
            confirmationState: jobState == .running ? .publishing : nil,
            automaticPipelineProgress: jobState == .running)
        #expect(!model.busy && !model.working)
        #expect(model.actionsBlocked)
        #expect(model.humanAction == nil && model.actionLabel == nil && model.nextStep == nil)
        #expect(model.chips.isEmpty)
        #expect(model.status == (state == "merged" ? "Merged. Automation is off." : "Closed. Automation is off."))
    }

    @Test func waitingForReviewerDoesNotShowWork() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 3, discussionID: "thread", reviewerID: 4, reviewerUsername: "reviewer",
                state: .waitingAcceptance, reason: nil, waitingForReviewers: ["reviewer"])])
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true, showsReadProgress: false)
        #expect(!model.working && !model.busy && model.activity == nil)
        #expect(model.status == String(localized: .AuthorFeedback.authorFeedbackWaitingChip))
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func agentActivityUsesTheCurrentRunAndItsRecordedStageStart(_ state: AssistantJobExecution.State) throws {
        let model = presentation("followUp", state: state, showsReadProgress: false)
        let job = try #require(model.row.latestJob)
        let activity = try #require(model.activity)
        #expect(model.working && activity.jobID == job.id)
        #expect(activity.startedAt == (state == .running ? job.execution?.startedAt : job.createdAt))
    }

    private func presentation(_ stage: String, state: AssistantJobExecution.State? = nil,
                              showsReadProgress: Bool = true) -> MRCardPresentation {
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
            showsReadProgress: showsReadProgress)
    }

    @Test(arguments: ["replies", "feedback", "ai", "readiness"])
    func backgroundReadOnlyChecksShowWorkEvenDuringQuietPolling(_ stage: String) {
        let model = presentation(stage, showsReadProgress: false)
        #expect(model.working && model.status != nil)
        #expect(model.busy && model.actionsBlocked)
    }

    @Test func quietReviewingChecksExplainTheReadWithoutInventingAHumanAction() {
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: "Example",
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
        item.reviewingProgress = .checking
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: true, assistantReady: true, isRefreshingAttention: true, showsReadProgress: false)
        #expect(model.working && model.status == "Checking review" && model.nextStep == nil)
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
        ("replies", "Checking replies"), ("feedback", "Checking feedback"),
        ("ai", "Assessing AI assistance"), ("readiness", "Checking review readiness"),
        ("conflict", "Preparing conflict fix"), ("pipeline", "Handling pipeline")
    ])
    func showsTheCurrentCheckWithoutInventingAHumanTask(stage: String, expected: String) {
        let model = presentation(stage)
        #expect(model.working)
        #expect(model.status == expected)
        #expect(model.humanAction == nil && model.actionLabel == nil)
    }

    @Test(arguments: [
        ("review", "Running review"), ("followUp", "Handling feedback"),
        ("conflict", "Resolving conflicts"), ("conflictReceipt", "Resolving conflicts"), ("pipeline", "Handling pipeline"), ("unknown", "Running agent")
    ])
    func runningJobsIdentifyTheirTaskWithoutParsingAgentText(stage: String, expected: String) {
        #expect(presentation(stage, state: .running).status == expected + " · Codex CLI")
    }

    @Test(arguments: ["review", "followUp", "pipeline", "conflict", "unknown"])
    func queuedJobsDoNotClaimThatTheAgentHasStarted(stage: String) {
        #expect(presentation(stage, state: .queued).status == "Queued for agent · Codex CLI")
    }
}
