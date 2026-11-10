import Foundation

/// Optional display metadata only; merge actions still fetch their own fresh evidence.
struct MRDependencyPresentationCache {
    typealias ID = MergeRequestAttentionMonitor.Item.ID
    typealias Context = MergeRequestDependencySummary.Context

    struct Account: Equatable {
        let host: String
        let username: String
        let revision: UInt64
    }
    private struct Entry {
        let context: Context
        let summary: MergeRequestDependencySummary
    }
    private var account: Account?
    private var entries: [ID: Entry] = [:]

    mutating func reconcileCatalog(requests: [GitLabMergeRequest], account: Account) {
        if self.account != account {
            self.account = account
            entries = [:]
        }
        let current = Self.contexts(for: requests)
        // Forget incompatible contexts, rather than keeping history that a round trip could revive.
        entries = entries.filter { current[$0.key] == $0.value.context }
    }

    func summary(for request: GitLabMergeRequest, account: Account) -> MergeRequestDependencySummary? {
        let id = ID(projectID: request.projectID, iid: request.iid)
        guard self.account == account, let entry = entries[id], entry.context == Context(request) else { return nil }
        return entry.summary
    }

    mutating func acceptDependencies(_ summaries: [ID: MergeRequestDependencySummary],
                                    requestedContexts: [ID: Context], currentRequests: [GitLabMergeRequest],
                                    account: Account) {
        guard self.account == account else { return }
        reconcileCatalog(requests: currentRequests, account: account)
        let current = Self.contexts(for: currentRequests)
        for (id, context) in requestedContexts where current[id] == context {
            entries[id] = summaries[id].map { Entry(context: context, summary: $0) }
        }
    }

    private static func contexts(for requests: [GitLabMergeRequest]) -> [ID: Context] {
        Dictionary(requests.map { (ID(projectID: $0.projectID, iid: $0.iid), Context($0)) },
                   uniquingKeysWith: { first, _ in first })
    }
}
