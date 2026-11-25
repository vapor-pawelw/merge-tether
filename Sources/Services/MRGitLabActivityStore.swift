import Foundation
import Observation

/// Keeps the last successful page set for each resource, scoped to one account session and MR.
@MainActor @Observable
final class MRGitLabActivityStore {
    private struct Query: Equatable {
        let target: MRDiscussionTarget
        let revision: UInt64
    }

    struct Snapshot {
        var entries: [MRGitLabActivity] = []
        var hasError = false
        var isLoading = false
    }

    private var query: Query?
    private var generation = 0
    private var entries: [MRGitLabActivity.Resource: [MRGitLabActivity]] = [:]
    private var discussionEntries: [MRGitLabActivity] = []
    private var hasError = false
    private var isLoading = false

    func snapshot(target: MRDiscussionTarget, revision: UInt64) -> Snapshot {
        guard query == Query(target: target, revision: revision) else { return .init() }
        return .init(entries: discussionEntries + entries.values.flatMap { $0 }, hasError: hasError, isLoading: isLoading)
    }

    func refresh(target: MRDiscussionTarget, glab: GlabService, includesDiscussions: Bool = false) async {
        guard target.host == glab.resolvedHost, target.username == glab.currentUsername,
              target.projectID > 0, target.iid > 0,
              target.url.isGitLabMergeRequest(host: target.host, iid: target.iid), !Task.isCancelled else { return }
        let request = Query(target: target, revision: glab.accountRevision)
        if query != request {
            query = request
            entries = [:]
            discussionEntries = []
            hasError = false
        }
        generation += 1
        let current = generation
        isLoading = true
        defer { if generation == current { isLoading = false } }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == current && request.revision == glab.accountRevision
        }
        do {
            _ = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        } catch {
            guard isCurrent() else { return }
            if (error as? GlabError) == .notAuthenticated {
                entries = [:]
                discussionEntries = []
            }
            hasError = true
            return
        }
        guard isCurrent() else { return }
        async let resources = Self.readResources(for: target, glab: glab)
        async let notes = includesDiscussions ? fetchDiscussions(for: target, glab: glab) : []
        let (results, discussionResult) = await (resources, notes)
        guard isCurrent() else { return }
        hasError = discussionResult == nil || results.count != MRGitLabActivity.Resource.allCases.count
        if let discussionResult { discussionEntries = discussionResult }
        entries.merge(results, uniquingKeysWith: { _, current in current })
    }

    /// The caller owns the account and MR checks around this read.
    static func readResources(for target: MRDiscussionTarget, glab: GlabService, timeout: TimeInterval = 45) async
        -> [MRGitLabActivity.Resource: [MRGitLabActivity]] {
        async let states = fetch(.state, for: target, glab: glab, timeout: timeout)
        async let labels = fetch(.label, for: target, glab: glab, timeout: timeout)
        async let milestones = fetch(.milestone, for: target, glab: glab, timeout: timeout)
        let results: [(MRGitLabActivity.Resource, [MRGitLabActivity]?)] = await [
            (.state, states), (.label, labels), (.milestone, milestones)
        ]
        return Dictionary(uniqueKeysWithValues: results.compactMap { resource, events in
            events.map { (resource, $0) }
        })
    }

    private func fetchDiscussions(for target: MRDiscussionTarget, glab: GlabService) async -> [MRGitLabActivity]? {
        guard let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: target.projectID,
            iid: target.iid, host: target.host) else { return nil }
        return MRGitLabActivity.notes(in: discussions)
    }

    private static func fetch(_ resource: MRGitLabActivity.Resource, for target: MRDiscussionTarget,
                              glab: GlabService, timeout: TimeInterval) async -> [MRGitLabActivity]? {
        let endpoint = "/projects/\(target.projectID)/merge_requests/\(target.iid)/resource_\(resource.rawValue)_events?per_page=100"
        let records: [MRGitLabActivity.ResourceEvent]? = try? await glab.mergeRequestAPI(
            endpoint, host: target.host, arguments: ["--paginate"], timeout: timeout,
            decode: { try GlabPaginatedJSON.decode(MRGitLabActivity.ResourceEvent.self, from: $0) })
        return records?.compactMap { $0.activity(for: resource) }
    }
}
