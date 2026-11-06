import Foundation
import Testing
@testable import GitLabTodos

struct MergeRequestBrowserSnapshotTests {
    private let host = "gitlab.example.org"

    private func request(_ iid: Int, username: String = "me", title: String = "Fix",
                         host: String = "gitlab.example.org", draft: Bool = false) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":\(iid),"author":{"id":3,"username":"\(username)","name":"Author"},
         "title":"\(title)","web_url":"https://\(host)/g/p/-/merge_requests/\(iid)",
         "state":"opened","draft":\(draft),"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "source_branch":"fix","target_branch":"main","detailed_merge_status":"mergeable",
         "has_conflicts":false,"labels":[],"blocking_discussions_resolved":true,"user":{"can_merge":true}}
        """.utf8))
    }

    private func item(_ request: GitLabMergeRequest) -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: request.projectID, iid: request.iid), title: request.title,
              url: request.webURL, mergeRequest: request)
    }

    private func status(_ request: GitLabMergeRequest, approved: Bool) throws -> AuthoredMergeRequestStatus {
        let approvals = try JSONDecoder().decode(GitLabMergeRequestApprovalState.self, from: Data("""
        {"rules":[{"approvals_required":1,"approved":\(approved)}]}
        """.utf8))
        return .init(request: request, approvals: approvals, discussionsResolved: true,
                     projectRequiresResolvedDiscussions: true, autoMergeEnabled: false)
    }

    @Test func ownRemainsCompleteWhileReviewedRespectsMixedScopeAndPauses() throws {
        var scope = MRAutomationScope()
        scope.mode = .selected
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        scope[target] = .active
        let items = try [item(request(1)), item(request(2, username: "alice")), item(request(3, username: "bob"))]
        var result = MergeRequestBrowserSnapshot(openItems: items, authored: [], host: host, username: "me", scope: scope)
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [2])
        scope[target.repository] = .active
        scope[target] = .paused
        result = .init(openItems: items, authored: [], host: host, username: "me", scope: scope)
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [3])
    }

    @MainActor @Test func removingReviewedMRPersistsLocallyAndExplicitReaddRestoresIt() throws {
        let suite = "ReviewedMRRemoval.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let items = try [item(request(1)), item(request(2, username: "alice")), item(request(3, username: "bob"))]
        settings.automation.scope[target] = .paused
        settings.save()
        var result = MergeRequestBrowserSnapshot(openItems: items, authored: [], host: host, username: "me",
            scope: SettingsManager(defaults: defaults).automation.scope)
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [3])
        settings.automation.scope[target] = .active
        settings.save()
        result = .init(openItems: items, authored: [], host: host, username: "me",
            scope: SettingsManager(defaults: defaults).automation.scope)
        #expect(Set(result.reviewed.map(\.id.iid)) == [2, 3])
    }

    @Test func ownUsesVerifiedApprovalsToPutReadyFirstAndDraftsLast() throws {
        let waiting = try request(1, title: "A waiting for approval")
        let ready = try request(2, title: "Z ready")
        let draft = try request(3, title: "A draft", draft: true)
        let statuses = try [status(waiting, approved: false), status(ready, approved: true), status(draft, approved: true)]
        let result = MergeRequestBrowserSnapshot(openItems: [item(waiting), item(ready), item(draft)],
            authored: statuses, host: host, username: "me", scope: .init())
        #expect(result.own.map(\.id.iid) == [2, 1, 3])
    }

    @Test func foreignHostStatusCannotOverwriteSameNumericMRInCurrentCatalog() throws {
        let current = try request(1, username: "alice", title: "Current")
        let oldHost = try request(1, title: "Old host", host: "old.example.org")
        let result = MergeRequestBrowserSnapshot(openItems: [item(current)], authored: [try status(oldHost, approved: true)],
            host: host, username: "me", scope: .init())
        #expect(result.own.isEmpty)
        #expect(result.reviewed.first?.mergeRequest?.title == "Current")
        #expect(result.reviewed.first?.mergeRequest?.webURL.host == host)
    }
    @Test func successfulOwnListingCannotBeResurrectedByAStaleReadyCache() throws {
        let old = try request(1)
        let cached = try status(old, approved: true)
        let result = MergeRequestBrowserSnapshot(openItems: [], authored: [cached], host: host, username: "me",
            scope: .init(), ownCatalogIsAuthoritative: true)
        #expect(result.own.isEmpty)
        let staleFallback = MergeRequestBrowserSnapshot(openItems: [], authored: [cached], host: host, username: "me",
            scope: .init(), ownCatalogIsAuthoritative: false)
        #expect(staleFallback.own.map(\.id.iid) == [1])
    }

    @Test func newDiscussionAtTheSameHeadCancelsCachedReadyStatus() throws {
        let request = try request(1)
        let ready = try status(request, approved: true)
        var current = item(request)
        #expect(current.canOfferMerge(using: ready))
        current.needsDiscussion = true
        #expect(!current.canOfferMerge(using: ready))
        current.needsDiscussion = false
        current.draftCount = 1
        #expect(!current.canOfferMerge(using: ready))
    }

}
