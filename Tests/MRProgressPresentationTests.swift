import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRProgressPresentationTests {
    private func presentation(_ stage: String, state: AssistantJobExecution.State? = nil) -> MRCardPresentation {
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
                execution: .init(state: state), workflow: stage == "review" ? .review : (stage == "followUp" ? .followUp : nil))
        }
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        return .init(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false,
            assistantReady: true, confirmationState: confirmation,
            automaticConflictProgress: state == nil && stage == "conflict",
            automaticPipelineProgress: state == nil && stage == "pipeline",
            conflictReceipts: stage == "conflictReceipt" ? [.init(host: "gitlab.example.test", userID: 3,
                projectID: 1, iid: 2, sourceSHA: "head", targetSHA: "target", allowsPush: false, jobID: job?.id)] : [])
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
