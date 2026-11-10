import Foundation

/// Ephemeral join of a checked action envelope and separately observed catalog facts.
/// Context compatibility describes this join; it is never action authorization.
struct MRCurrentRowProjection {
    /// Display-only dependency values stay outside the attention record's stored catalog slice.
    struct Catalog {
        let facts: MRAttentionRecord.CatalogObservation
        let dependencies: MergeRequestDependencySummary?
        init(_ item: MergeRequestAttentionMonitor.Item) {
            facts = .init(item)
            dependencies = item.dependencies
        }
    }
    let item: MergeRequestAttentionMonitor.Item
    let catalog: Catalog
    let evidenceMatchesCatalogContext: Bool

    init(evidence: MergeRequestAttentionMonitor.Item, catalog: MergeRequestAttentionMonitor.Item,
         username: String?) {
        evidenceMatchesCatalogContext = evidence.id == catalog.id
            && evidence.url.gitLabTodoMergeRequestURL(host: catalog.url.host ?? "", iid: evidence.id.iid)
                == catalog.url.gitLabTodoMergeRequestURL(host: catalog.url.host ?? "", iid: catalog.id.iid)
            && MRAttentionRecord.sameContext(evidence.mergeRequest, catalog.mergeRequest)
        self.catalog = .init(catalog)
        var value = evidence
        if evidenceMatchesCatalogContext {
            value = MRAttentionRecord(evidence: evidence, catalog: catalog).catalogItem ?? evidence
            value.dependencies = catalog.dependencies ?? evidence.dependencies
        } else {
            // Retain A's private material without advertising its checked verdict as B's.
            value.canApprove = false
            value.autoApproveReady = false
            value.canConfirmReReview = false
            value.needsMerge = false
            value.automaticDraftIDs = []
            value.automaticPublicationPolicy = nil
            if value.draftCount > 0 || !value.drafts.isEmpty { value.requiresDiscussionRecheck = true }
        }
        if evidenceMatchesCatalogContext {
            value.isAuthored = catalog.isAuthored || catalog.mergeRequest?.author.username == username
        }
        item = value.presentingVerifiedAuthorFeedback()
    }
}
