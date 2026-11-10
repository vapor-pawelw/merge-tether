import Foundation
import Testing
@testable import GitLabTodos

struct MergeActionReadinessTests {
    @Test(arguments: [false, true])
    func manualMergeDoesNotDependOnTheAutomaticSetting(_ automatic: Bool) throws {
        let status = try status(automatic: automatic)
        #expect(status.mayMergeManually)
        #expect(status.mayAutoMerge == automatic)
    }

    @Test(arguments: ["draft", "approvals", "discussions", "drafts", "work", "dependencies", "target", "unknown", "permission", "conflict", "pipeline"])
    func manualMergeKeepsAllIndependentGuards(_ blocker: String) throws {
        #expect(try !status(blocker: blocker).mayMergeManually)
    }

    @Test func trainCanQueueWhileItsPipelineRunsButCannotSkipFailedCI() throws {
        #expect(try status(action: .enqueue, pipeline: "running").mayMergeManually)
        #expect(try !status(action: .enqueue, pipeline: "failed").mayMergeManually)
        #expect(try !status(action: .mergeNow, pipeline: "running").mayMergeManually)
    }

    @Test(arguments: [MergeSubmissionState.queued, .inTrain, .uncertain, .changed])
    func queuedOrUncertainRequestsNeverOfferAnotherSubmission(_ state: MergeSubmissionState) throws {
        let value = try status(state: state)
        #expect(!value.mayMergeManually && !value.mayAutoMerge)
    }

    @Test func unknownProjectCapabilitiesNeverOfferAWrite() throws {
        #expect(try !status(action: nil).mayMergeManually)
    }

    private func status(automatic: Bool = false, blocker: String = "", action: MergeSubmissionAction? = .mergeNow,
                        pipeline: String? = nil, state: MergeSubmissionState = .none) throws -> AuthoredMergeRequestStatus {
        var object: [String: Any] = ["project_id": 1, "iid": 2, "author": ["id": 3, "username": "me", "name": "Me"],
            "title": "Feature", "labels": [], "web_url": "https://gitlab.example.test/g/p/-/merge_requests/2",
            "state": "opened", "draft": blocker == "draft", "sha": String(repeating: "a", count: 40),
            "source_project_id": 1, "target_project_id": 1, "source_branch": "feature", "target_branch": "main",
            "detailed_merge_status": pipeline == "running" ? "ci_still_running" : "mergeable",
            "has_conflicts": blocker == "conflict", "user": ["can_merge": blocker != "permission"]]
        if let pipeline { object["head_pipeline"] = ["id": 4, "status": pipeline] }
        if blocker == "pipeline" { object["head_pipeline"] = ["id": 4, "status": "failed"] }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        let approvals = try JSONDecoder().decode(GitLabMergeRequestApprovalState.self,
            from: Data("{\"rules\":[{\"approvals_required\":2,\"approved\":\(blocker != "approvals")}]}".utf8))
        return .init(request: request, approvals: approvals, discussionsResolved: blocker != "discussions",
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: automatic,
            dependencyReadiness: blocker == "dependencies" ? .waitingForDependencies
                : blocker == "target" ? .reviewStackTarget : blocker == "unknown" ? .unavailable : .ready,
            pendingDraftCount: blocker == "drafts" ? 1 : 0, requiresCommentReview: blocker == "work",
            action: action, submissionState: state)
    }
}
