import Foundation

/// Account-scoped tracked rows; automation permission does not control board membership.
struct MergeRequestBrowserSnapshot {
    let own: [MergeRequestAttentionMonitor.Item]
    let reviewed: [MergeRequestAttentionMonitor.Item]

    init(openItems: [MergeRequestAttentionMonitor.Item], authored: [AuthoredMergeRequestStatus],
         host: String, username: String, scope: MRAutomationScope, ownCatalogIsAuthoritative: Bool = false,
         draftsLast: Bool = true) {
        let items = MRBoardProjector.browserItems(openItems: openItems, authored: authored,
            host: host, username: username, ownCatalogIsAuthoritative: ownCatalogIsAuthoritative, draftsLast: draftsLast)
        own = items.own
        reviewed = items.reviewed
    }
}
