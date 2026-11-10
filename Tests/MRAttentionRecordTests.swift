import Foundation
import Testing
@testable import GitLabTodos

struct MRAttentionRecordTests {
    @Test func compatibleCatalogObservationsKeepNewPipelineAndReviewActivityFacts() throws {
        let item = try evidence()
        let request = try #require(item.mergeRequest)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json["head_pipeline"] = ["id": 81, "status": "failed"]
        json["detailed_merge_status"] = "ci_must_pass"
        let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
        var catalog = item
        catalog.title = "Current catalog label"
        catalog.mergeRequest = current
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7},"body":"Review","system":false}]}]"#.utf8))
        catalog.reviewingActivity = .init(discussions: threads, reviewerID: 7, authorID: 9)
        var record = MRAttentionRecord(evidence: item, catalog: catalog)
        let visible = try #require(record.catalogItem)
        #expect(visible.mergeRequest?.headPipeline?.status == "failed")
        #expect(visible.mergeRequest?.detailedMergeStatus == "ci_must_pass")
        #expect(visible.title == "Current catalog label")
        #expect(visible.reviewingActivity?.publishedCommentCount == 1)
        #expect(visible.drafts == item.drafts && visible.commentReviewSnapshot == item.commentReviewSnapshot)
        var refreshed = item
        refreshed.reviewingActivity = .init(discussions: [], reviewerID: 7, authorID: 9)
        record.replaceEvidence(refreshed)
        #expect(record.catalogItem?.reviewingActivity?.publishedCommentCount == 0)
        #expect(record.catalogItem?.mergeRequest?.headPipeline?.status == "failed")
    }

    @Test func aCompatibleCatalogReadsTheCurrentDraftsFromTheSingleEvidenceEnvelope() throws {
        let item = try evidence()
        var record = MRAttentionRecord(evidence: item, catalog: item)
        #expect(record.catalogItem?.drafts == item.drafts)
        record.evidence.drafts.removeAll()
        record.evidence.draftCount = 0
        record.evidence.requiresCommentReview = true
        #expect(record.catalogItem?.drafts.isEmpty == true)
        #expect(record.catalogItem?.requiresCommentReview == true)
        #expect(record.catalogItem?.canFinishCommentReview == true)
    }

    @Test(arguments: ["sha", "source_project_id", "source_branch", "target_project_id", "target_branch", "web_url",
                      "state", "title", "description", "draft", "author"])
    func newerCatalogFactsDoNotRebindDraftsOrActionEvidence(_ field: String) throws {
        let item = try evidence()
        let request = try #require(item.mergeRequest)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let changes: [String: Any] = ["sha": String(repeating: "b", count: 40), "source_project_id": 77,
            "source_branch": "other-source", "target_project_id": 77, "target_branch": "release",
            "web_url": "https://gitlab.example.test/moved/repo/-/merge_requests/2", "state": "closed",
            "title": "Edited title", "description": "Edited requirements", "draft": true,
            "author": ["id": 8, "username": "other", "name": "Other"]]
        json[field] = changes[field]
        let newer = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
        let catalog = MergeRequestAttentionMonitor.Item(id: item.id, title: newer.title, url: newer.webURL,
            mergeRequest: newer, isAuthored: false)
        var record = MRAttentionRecord(evidence: item, catalog: catalog)
        record.evidence.requiresCommentReview = true
        let visible = try #require(record.catalogItem)
        #expect(visible.mergeRequest?.semanticContextFingerprint == newer.semanticContextFingerprint)
        #expect(visible.mergeRequest?.sha == newer.sha)
        #expect(visible.drafts.isEmpty && visible.draftCount == 0)
        #expect(!visible.canApprove && !visible.autoApproveReady && !visible.canConfirmReReview)
        #expect(visible.automaticDraftIDs.isEmpty && visible.commentReviewSnapshot == nil)
        #expect(visible.observedDiscussionFingerprint == nil && visible.feedback.isEmpty)
        #expect(record.evidence.drafts == item.drafts)
        #expect(record.evidence.commentReviewSnapshot == item.commentReviewSnapshot)
    }

    @Test func clearingApprovalCountsKeepsDraftsAndTheRetainedLink() throws {
        let item = try evidence()
        var record = MRAttentionRecord(evidence: item, catalog: item)
        record.clearApprovalProgress()
        #expect(record.catalogItem?.approvalProgress == nil)
        #expect(record.catalogItem?.url == item.url)
        #expect(record.evidence.drafts == item.drafts)
    }

    private func evidence() throws -> MergeRequestAttentionMonitor.Item {
        let request = try MRDependencyPresentationTests().request(2)
        let draft = GitLabDraftNote(id: 11, authorID: 7, note: "Pending reply", discussionID: nil, position: nil)
        return .init(id: .init(projectID: 34, iid: 2), title: request.title, url: request.webURL,
            draftCount: 1, commentReviewSnapshot: .init(request: request, discussions: []), drafts: [draft],
            automaticDraftIDs: [11], observedDiscussionFingerprint: ReviewVerdict.fingerprint([]),
            canApprove: true, autoApproveReady: true, canConfirmReReview: true, mergeRequest: request, isAuthored: true)
    }
}
