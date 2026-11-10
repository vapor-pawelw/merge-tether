import Foundation

/// One safety-evidence envelope, with separately observed catalog facts.
/// Catalog retention never grants membership in the action-candidate list.
struct MRAttentionRecord {
    struct CatalogObservation {
        let title: String
        let url: URL
        let lifecycleCompletionID: UUID?
        let request: GitLabMergeRequest?
        let isAuthored: Bool
        var approvalProgress: MergeRequestApprovalProgress?
        var reviewingActivity: ReviewingActivity?

        init(_ item: MergeRequestAttentionMonitor.Item) {
            title = item.title; url = item.url; lifecycleCompletionID = item.lifecycleCompletionID
            request = item.mergeRequest; isAuthored = item.isAuthored
            approvalProgress = item.approvalProgress; reviewingActivity = item.reviewingActivity
        }
    }
    var evidence: MergeRequestAttentionMonitor.Item
    var catalog: CatalogObservation?

    init(evidence: MergeRequestAttentionMonitor.Item, catalog: MergeRequestAttentionMonitor.Item?) {
        self.evidence = evidence
        self.catalog = catalog.map(CatalogObservation.init)
    }

    var catalogItem: MergeRequestAttentionMonitor.Item? {
        guard let catalog else { return nil }
        if Self.sameContext(evidence.mergeRequest, catalog.request) {
            var item = evidence
            item.title = catalog.title
            item.url = catalog.url
            item.lifecycleCompletionID = catalog.lifecycleCompletionID
            item.mergeRequest = catalog.request
            item.approvalProgress = catalog.approvalProgress
            item.reviewingActivity = catalog.reviewingActivity
            item.isAuthored = catalog.isAuthored
            return item
        }
        // A newer catalog request does not rebind old drafts, verdicts or discussion evidence.
        return .init(id: evidence.id, title: catalog.title, url: catalog.url,
            lifecycleCompletionID: catalog.lifecycleCompletionID, approvalProgress: catalog.approvalProgress,
            mergeRequest: catalog.request, isAuthored: catalog.isAuthored, reviewingActivity: catalog.reviewingActivity)
    }

    mutating func clearApprovalProgress() {
        evidence.approvalProgress = nil
        catalog?.approvalProgress = nil
    }

    mutating func replaceEvidence(_ item: MergeRequestAttentionMonitor.Item) {
        if let catalog, Self.sameContext(item.mergeRequest, catalog.request),
           item.reviewingActivity != evidence.reviewingActivity {
            self.catalog?.reviewingActivity = item.reviewingActivity
        }
        evidence = item
    }

    static func sameContext(_ left: GitLabMergeRequest?, _ right: GitLabMergeRequest?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return MergeRequestDependencySummary.Context(left) == MergeRequestDependencySummary.Context(right)
            && left.semanticContextFingerprint == right.semanticContextFingerprint
            && left.draft == right.draft && left.author.id == right.author.id
    }
}
