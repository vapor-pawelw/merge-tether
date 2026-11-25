import Foundation
import Testing
@testable import MergeTether

@Suite struct AutomaticApprovalGateTests {
    private let head = "0123456789012345678901234567890123456789"
    private let base = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"

    private func request(_ changes: [String: Any?] = [:]) throws -> GitLabMergeRequest {
        var json: [String: Any] = [
            "project_id": 1, "iid": 2, "author": ["id": 9, "username": "alice", "name": "Alice"], "title": "Fix",
            "web_url": "https://gitlab.example.org/g/p/-/merge_requests/2", "state": "opened", "draft": false,
            "sha": head, "source_project_id": 1, "source_branch": "fix", "target_project_id": 1, "target_branch": "main",
            "labels": [], "head_pipeline": ["id": 5, "status": "success", "sha": head],
            "diff_refs": ["base_sha": base, "head_sha": head, "start_sha": base], "changes_count": "3"]
        for (key, value) in changes { json[key] = value }
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aVerdictForTheCurrentDiffTargetIsPermitted() throws {
        let current = try request()
        let reviewed = try #require(ReviewTargetBinding(current))
        #expect(reviewed.targetBranch == "main" && reviewed.baseSHA == base && reviewed.targetProjectID == 1)
        #expect(AutomaticApprovalGate.refusal(for: current, head: head, reviewed: reviewed) == nil)
    }

    @Test func listReadsWithoutDiffRefsCannotBindAReview() throws {
        #expect(ReviewTargetBinding(try request(["diff_refs": nil])) == nil)
        #expect(ReviewTargetBinding(try request(["diff_refs": ["base_sha": base, "head_sha": String(repeating: "f", count: 40)]])) == nil)
        #expect(ReviewTargetBinding(try request(["diff_refs": ["head_sha": head]])) == nil)
        #expect(ReviewTargetBinding(try request(["target_project_id": nil])) == nil)
    }

    @Test(arguments: [
        ("retargeted", AutomaticApprovalGate.Refusal.targetChanged), ("otherProject", .targetChanged),
    ])
    func changedOrUnprovenContextIsRefused(_ change: String, _ refusal: AutomaticApprovalGate.Refusal) throws {
        let reviewed = try #require(ReviewTargetBinding(try request()))
        let changed: [String: Any?] = switch change {
        case "retargeted": ["target_branch": "feature-base"]
        default: ["target_project_id": 7]
        }
        #expect(AutomaticApprovalGate.refusal(for: try request(changed), head: head, reviewed: reviewed) == refusal)
    }

    @Test func missingEvidenceAndLegacyReviewsAreRefused() throws {
        let current = try request()
        let reviewed = try #require(ReviewTargetBinding(current))
        #expect(AutomaticApprovalGate.refusal(for: current, head: head, reviewed: nil) == .reviewTargetUnbound)
        #expect(AutomaticApprovalGate.refusal(for: try request(["diff_refs": ["base_sha": String(repeating: "c", count: 40), "head_sha": head]]),
            head: head, reviewed: reviewed) == .targetChanged)
        #expect(AutomaticApprovalGate.refusal(for: current, head: String(repeating: "f", count: 40), reviewed: reviewed) == .targetChanged)
    }
}
