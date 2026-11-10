import Foundation
import Testing
@testable import GitLabTodos

struct MRDependencyPresentationCacheTests {
    private let account = MRDependencyPresentationCache.Account(host: "gitlab.example.test", username: "author7", revision: 7)
    private let id = MRDependencyPresentationCache.ID(projectID: 34, iid: 2)

    @Test func compatibleLinksSurviveOrdinaryCatalogAndTextRefreshes() throws {
        let request = try MRDependencyPresentationTests().request(2)
        let summary = try summary(for: request)
        var cache = seeded(request, summary)
        let edited = try changed(request, fields: ["title": "New title", "description": "New description", "draft": true])
        cache.reconcileCatalog(requests: [edited], account: account)
        #expect(cache.summary(for: edited, account: account) == summary)
    }

    @Test(arguments: ["sha", "source_project_id", "source_branch", "target_project_id", "target_branch", "web_url", "state"])
    func contextChangesCannotReviveAnEarlierSummary(_ field: String) throws {
        let request = try MRDependencyPresentationTests().request(2)
        let summary = try summary(for: request)
        var cache = seeded(request, summary)
        #expect(cache.summary(for: request, account: account) == summary)
        let changes: [String: Any] = ["sha": String(repeating: "b", count: 40), "source_project_id": 99,
            "source_branch": "new-source", "target_project_id": 99, "target_branch": "release",
            "web_url": "https://gitlab.example.test/moved/repo/-/merge_requests/2", "state": "closed"]
        let edited = try changed(request, fields: [field: try #require(changes[field])])
        #expect(cache.summary(for: edited, account: account) == nil)
        cache.reconcileCatalog(requests: [edited], account: account)
        cache.reconcileCatalog(requests: [request], account: account)
        #expect(cache.summary(for: request, account: account) == nil)
    }

    @Test(arguments: ["host", "username", "revision"])
    func accountChangesRejectEarlierEvidenceAndLateResults(_ field: String) throws {
        let request = try MRDependencyPresentationTests().request(2)
        let summary = try summary(for: request)
        var cache = seeded(request, summary)
        let other = MRDependencyPresentationCache.Account(host: field == "host" ? "other.test" : account.host,
            username: field == "username" ? "other" : account.username, revision: field == "revision" ? 8 : account.revision)
        #expect(cache.summary(for: request, account: other) == nil)
        cache.reconcileCatalog(requests: [request], account: other)
        cache.acceptDependencies([id: summary], requestedContexts: [id: .init(request)],
            currentRequests: [request], account: account)
        #expect(cache.summary(for: request, account: other) == nil)
        cache.reconcileCatalog(requests: [request], account: account)
        #expect(cache.summary(for: request, account: account) == nil)
    }

    @Test func aLateDifferentContextCannotClearANewerCompatibleResult() throws {
        let original = try MRDependencyPresentationTests().request(2)
        let current = try changed(original, fields: ["target_branch": "release"])
        let newest = try summary(for: current, parentID: 5)
        var cache = seeded(current, newest)
        cache.acceptDependencies([id: try summary(for: original)], requestedContexts: [id: .init(original)],
            currentRequests: [current], account: account)
        #expect(cache.summary(for: current, account: account) == newest)
    }

    @Test func failuresReplaceSuccessfulDisplayWithExplicitlyUnverifiedLinks() throws {
        let request = try MRDependencyPresentationTests().request(2)
        let parent = try MRDependencyPresentationTests().request(1)
        var cache = seeded(request, try summary(for: request))
        let unavailable = MergeRequestDependencySummary(request: request, stack: nil,
            dependencies: .init(requests: [parent], hasHiddenDependency: true), unavailableSources: [.gitLab, .stack])
        cache.acceptDependencies([id: unavailable], requestedContexts: [id: .init(request)],
            currentRequests: [request], account: account)
        let displayed = try #require(cache.summary(for: request, account: account))
        #expect(displayed == unavailable)
        #expect(displayed.predecessors.map(\.iid) == [1])
        #expect(displayed.predecessors.first?.isCurrent == false)
    }

    @Test func removingARowPrunesItsMetadataButRetainingItThroughAPartialReadDoesNot() throws {
        let request = try MRDependencyPresentationTests().request(2)
        let summary = try summary(for: request)
        var cache = seeded(request, summary)
        cache.reconcileCatalog(requests: [request], account: account)
        #expect(cache.summary(for: request, account: account) == summary)
        cache.reconcileCatalog(requests: [], account: account)
        cache.reconcileCatalog(requests: [request], account: account)
        #expect(cache.summary(for: request, account: account) == nil)
    }

    private func seeded(_ request: GitLabMergeRequest, _ summary: MergeRequestDependencySummary) -> MRDependencyPresentationCache {
        var cache = MRDependencyPresentationCache()
        cache.reconcileCatalog(requests: [request], account: account)
        cache.acceptDependencies([id: summary], requestedContexts: [id: .init(request)],
            currentRequests: [request], account: account)
        return cache
    }
    private func summary(for request: GitLabMergeRequest, parentID: Int = 1) throws -> MergeRequestDependencySummary {
        .init(request: request, stack: .init(requests: [request], defaultBranch: "main"),
            dependencies: .init(requests: [try MRDependencyPresentationTests().request(parentID)], hasHiddenDependency: false))
    }
    private func changed(_ request: GitLabMergeRequest, fields: [String: Any]) throws -> GitLabMergeRequest {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json.merge(fields, uniquingKeysWith: { _, new in new })
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
