import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRCurrentRowProjectionTests {
    @Test(arguments: ["same", "sha", "source_branch", "target_branch", "source_project_id", "target_project_id",
                      "web_url", "author", "username", "title", "description", "draft", "state"])
    func catalogFactsDoNotRebindPrivateEvidence(_ change: String) throws {
        var data: [String: Any] = ["project_id": 1, "iid": 42, "author": ["id": 3, "username": "me", "name": "Me"],
            "title": "Checked", "description": "Body", "web_url": "https://gitlab.test/g/p/-/merge_requests/42",
            "state": "opened", "draft": false, "sha": "a", "source_branch": "feature", "target_branch": "main",
            "source_project_id": 1, "target_project_id": 1, "labels": []]
        func request() throws -> GitLabMergeRequest {
            try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: data))
        }
        let checked = try request()
        var evidence = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 42), title: checked.title,
            url: checked.webURL, draftCount: 1, requiresCommentReview: true, automaticDraftIDs: [7],
            observedDiscussionFingerprint: "conversation-a", canApprove: true, autoApproveReady: true,
            needsMerge: true, canConfirmReReview: true, mergeRequest: checked, isAuthored: true)
        evidence.drafts = [.init(id: 7, authorID: 3, note: "Private A", discussionID: nil, position: nil)]
        switch change {
        case "same": data["head_pipeline"] = ["id": 9, "status": "success"]
        case "author": data[change] = ["id": 4, "username": "other", "name": "Other"]
        case "username": data["author"] = ["id": 3, "username": "renamed", "name": "Me"]
        case "draft": data[change] = true
        case "source_project_id", "target_project_id": data[change] = 2
        case "web_url": data[change] = "https://gitlab.test/g/renamed/-/merge_requests/42"
        case "state": data[change] = "merged"
        default: data[change] = "new-value"
        }
        let current = try request()
        let catalog = MergeRequestAttentionMonitor.Item(id: evidence.id, title: current.title, url: current.webURL,
            approvalProgress: .init(completed: 1, required: 2), mergeRequest: current, isAuthored: true)
        let projection = MRCurrentRowProjection(evidence: evidence, catalog: catalog, username: "me")
        #expect(projection.evidenceMatchesCatalogContext == (change == "same"))
        #expect(projection.item.drafts == evidence.drafts)
        #expect(projection.item.observedDiscussionFingerprint == "conversation-a")
        #expect(projection.catalog.request?.draft == current.draft)
        #expect(projection.catalog.request?.state == current.state)
        #expect(projection.item.mergeRequest?.semanticContextFingerprint == checked.semanticContextFingerprint)
        #expect(projection.item.mergeRequest?.sha == "a")
        #expect(projection.item.mergeRequest?.draft == false)
        #expect(projection.item.canApprove == (change == "same"))
        #expect(projection.item.autoApproveReady == (change == "same"))
        #expect(projection.item.canConfirmReReview == (change == "same"))
        #expect(projection.item.needsMerge == (change == "same"))
        #expect(projection.item.automaticDraftIDs == (change == "same" ? [7] : []))
        #expect(projection.item.requiresDiscussionRecheck == (change != "same"))
        if change == "same" {
            #expect(projection.item.mergeRequest?.headPipeline?.id == 9)
            #expect(projection.item.approvalProgress == catalog.approvalProgress)
        }
    }
}
