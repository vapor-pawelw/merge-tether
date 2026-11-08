import Foundation

/// Account-scoped tracked rows; automation permission does not control board membership.
struct MergeRequestBrowserSnapshot {
    let own: [MergeRequestAttentionMonitor.Item]
    let reviewed: [MergeRequestAttentionMonitor.Item]

    init(openItems: [MergeRequestAttentionMonitor.Item], authored: [AuthoredMergeRequestStatus],
         host: String, username: String, scope: MRAutomationScope, ownCatalogIsAuthoritative: Bool = false,
         draftsLast: Bool = true) {
        var rows = Dictionary(uniqueKeysWithValues: openItems.map { ($0.id, $0) })
        let currentAuthored = authored.filter {
            $0.request.author.username == username && $0.request.state == "opened"
                && $0.request.webURL.isGitLabMergeRequest(host: host, iid: $0.request.iid)
        }
        for status in currentAuthored {
            let request = status.request
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
            if ownCatalogIsAuthoritative && rows[id] == nil { continue }
            if let currentHead = rows[id]?.mergeRequest?.sha, currentHead != request.sha { continue }
            var item = rows[id] ?? .init(id: id, title: request.title, url: request.webURL)
            if item.mergeRequest == nil { item.mergeRequest = request }
            item.isAuthored = true
            rows[id] = item
        }
        let items = MergeRequestAttentionMonitor.Item.ordered(rows.values.filter {
            ["opened", "merged", "closed"].contains($0.mergeRequest?.state ?? "")
                && $0.url.isGitLabMergeRequest(host: host, iid: $0.id.iid)
                && $0.mergeRequest?.webURL.isGitLabMergeRequest(host: host, iid: $0.id.iid) == true
        }, draftsLast: draftsLast)
        let matchingStatuses = currentAuthored.filter { status in
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: status.request.projectID, iid: status.request.iid)
            guard let item = rows[id], item.mergeRequest?.sha == status.request.sha else { return false }
            return !status.blockers.isEmpty || item.canOfferMerge(using: status)
        }
        let orderedStatuses = AuthoredMergeRequestStatus.orderedForMerge(matchingStatuses)
        let ranks = Dictionary(orderedStatuses.enumerated().map {
            (MergeRequestAttentionMonitor.Item.ID(projectID: $0.element.request.projectID, iid: $0.element.request.iid), $0.offset)
        }, uniquingKeysWith: min)
        own = items.filter { $0.mergeRequest?.author.username == username }.enumerated().sorted {
            let left = (draftsLast && $0.element.mergeRequest?.draft == true ? 1 : 0, ranks[$0.element.id] ?? Int.max, $0.offset)
            let right = (draftsLast && $1.element.mergeRequest?.draft == true ? 1 : 0, ranks[$1.element.id] ?? Int.max, $1.offset)
            return left < right
        }.map(\.element)
        reviewed = items.filter {
            $0.mergeRequest?.author.username != username
        }
    }
}
