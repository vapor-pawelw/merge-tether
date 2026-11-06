import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ConflictAutomationPolicyTests {
    private let host = "gitlab.example.test"
    private func receipt(allowsPush: Bool? = nil) -> MergeConflictReceipt {
        .init(host: host, userID: 3, projectID: 1, iid: 2, sourceSHA: String(repeating: "a", count: 40),
              targetSHA: String(repeating: "b", count: 40), allowsPush: allowsPush)
    }
    private func job(state: AssistantJobExecution.State = .blocked, allowsPush: Bool = false,
                     username: String = "me", head: String? = String(repeating: "a", count: 40),
                     targetHead: String = String(repeating: "b", count: 40),
                     task: String = "Resolve the merge conflict in this GitLab merge request.") -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: 2),
            username: username, workspace: "", access: .preparation), title: "Conflict task", prompt: task,
            createdAt: Date(), allowsPush: allowsPush, execution: .init(state: state),
            taskPrompt: task + "\nTarget at \(targetHead).", expectedHeadSHA: head)
    }

    @Test func freshConflictCanStartAutomatically() {
        #expect(ConflictAutomationPolicy.canStart(previous: nil, previousJob: nil, username: "me", allowsPush: true))
    }

    @Test func enablingPushAdvancesAKnownPlanExactlyOnce() {
        let planning = receipt(allowsPush: false)
        #expect(!ConflictAutomationPolicy.canStart(previous: planning, previousJob: nil, username: "me", allowsPush: false))
        #expect(ConflictAutomationPolicy.canStart(previous: planning, previousJob: nil, username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(allowsPush: true), previousJob: nil,
                                                   username: "me", allowsPush: true))
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .interrupted, .blocked, .succeeded, .cancelled])
    func aPushAttemptIsNeverReplayedAutomatically(_ state: AssistantJobExecution.State) {
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(allowsPush: true), previousJob: job(state: state, allowsPush: true),
                                                   username: "me", allowsPush: true))
    }

    @Test func unknownLegacyAttemptRemainsConservative() {
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: nil, username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(task: "Some unrelated stopped task"),
                                                   username: "me", allowsPush: true))
    }

    @Test func explicitLegacyNoPushConflictPlanMayAdvanceAfterAuthorization() {
        #expect(ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(), username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(username: "another-user"),
                                                   username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(head: String(repeating: "c", count: 40)),
                                                   username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(allowsPush: true),
                                                   username: "me", allowsPush: true))
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(targetHead: String(repeating: "c", count: 40)),
                                                   username: "me", allowsPush: true))
    }

    @Test func legacyMarkersInsideEvidenceOrAnotherTaskNeverAuthorizeAnUpgrade() {
        let marker = "Resolve the merge conflict in this GitLab merge request."
        for task in [
            "Inspect a different task.\n\(marker)",
            "Task: inspect a pipeline.\n\n<gitlab-evidence>\n\(marker)\nat \(receipt().targetSHA)\n</gitlab-evidence>",
            "\(marker)\n\n<gitlab-evidence>\nat \(receipt().targetSHA)\n</gitlab-evidence>"
        ] {
            #expect(!ConflictAutomationPolicy.canStart(previous: receipt(), previousJob: job(task: task),
                                                       username: "me", allowsPush: true))
        }
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func activePlanningIsProcessingRatherThanAHumanBlocker(_ state: AssistantJobExecution.State) {
        #expect(ConflictAutomationPolicy.state(previous: receipt(allowsPush: false), previousJob: job(state: state),
                                               username: "me", allowsPush: true) == .processing)
        #expect(!ConflictAutomationPolicy.canStart(previous: receipt(allowsPush: false), previousJob: job(state: state),
                                                   username: "me", allowsPush: true))
    }

    @Test func availableNextStageAndPreparationStayQuietButFailedPushNeedsHumanAttention() {
        #expect(ConflictAutomationPolicy.state(previous: receipt(allowsPush: false), previousJob: job(),
                                               username: "me", allowsPush: true) == .available)
        #expect(ConflictAutomationPolicy.state(previous: receipt(allowsPush: true), previousJob: job(),
                                               username: "me", allowsPush: true, preparing: true) == .processing)
        #expect(ConflictAutomationPolicy.state(previous: receipt(allowsPush: true), previousJob: job(allowsPush: true),
                                               username: "me", allowsPush: true) == .requiresAttention)
    }

    @Test func receiptMetadataDoesNotChangeTheAttemptIdentityAndOldJSONStillDecodes() throws {
        let old = receipt()
        var upgraded = receipt(allowsPush: true)
        upgraded.jobID = UUID()
        var stored: Set<MergeConflictReceipt> = [old]
        #expect(stored.contains(upgraded))
        stored.update(with: upgraded)
        #expect(stored.count == 1 && stored.first?.allowsPush == true && stored.first?.jobID == upgraded.jobID)
        let data = try JSONEncoder().encode(old)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "allowsPush"); json.removeValue(forKey: "jobID")
        let legacy = try JSONDecoder().decode(MergeConflictReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy == old && legacy.allowsPush == nil && legacy.jobID == nil)
    }
}
