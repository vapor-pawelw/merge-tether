import Foundation
import Testing
@testable import GitLabTodos

struct MergeRequestBrowserSnapshotTests {
    private let host = "gitlab.example.org"

    private func request(_ iid: Int, username: String = "me", title: String = "Fix",
                         host: String = "gitlab.example.org", draft: Bool = false, state: String = "opened") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":\(iid),"author":{"id":3,"username":"\(username)","name":"Author"},
         "title":"\(title)","web_url":"https://\(host)/g/p/-/merge_requests/\(iid)",
         "state":"\(state)","draft":\(draft),"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
                     projectRequiresResolvedDiscussions: true, autoMergeEnabled: false, dependencyReadiness: .ready)
    }

    @Test(arguments: ["me", "reviewer"])
    func normalActivityOrderHasNoHiddenDraftPenalty(_ author: String) throws {
        let draft = try request(1, username: author, title: "A Draft", draft: true)
        let ready = try request(2, username: author, title: "Z Ready")
        let normal = MergeRequestBrowserSnapshot(openItems: [item(ready), item(draft)], authored: [],
            host: host, username: "me", scope: .init(), draftsLast: false)
        let manual = MergeRequestBrowserSnapshot(openItems: [item(ready), item(draft)], authored: [],
            host: host, username: "me", scope: .init())
        #expect((author == "me" ? normal.own : normal.reviewed).map(\.id.iid) == [1, 2])
        #expect((author == "me" ? manual.own : manual.reviewed).map(\.id.iid) == [2, 1])
    }

    @Test func automationPolicyChangesPreserveOwnAndReviewedMembershipAndOrder() throws {
        var scope = MRAutomationScope()
        scope.mode = .selected
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        scope[target] = .active
        let items = try [item(request(1)), item(request(2, username: "alice")), item(request(3, username: "bob"))]
        var result = MergeRequestBrowserSnapshot(openItems: items, authored: [], host: host, username: "me", scope: scope)
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [2, 3])
        scope[target.repository] = .active
        scope[target] = .paused
        result = .init(openItems: items, authored: [], host: host, username: "me", scope: scope)
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [2, 3])
    }

    @MainActor @Test func pausingReviewedMRSurvivesRestartWithoutRemovingIt() throws {
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
        #expect(result.reviewed.map(\.id.iid) == [2, 3])
        settings.automation.scope[target] = .active
        settings.save()
        result = .init(openItems: items, authored: [], host: host, username: "me",
            scope: SettingsManager(defaults: defaults).automation.scope)
        #expect(Set(result.reviewed.map(\.id.iid)) == [2, 3])
    }

    @Test(arguments: ["merged", "closed"])
    func finishedOwnAndReviewedRowsStayVisibleUntilTheirLifecycleIsAcknowledged(_ state: String) throws {
        let rows = try [item(request(1, state: state)), item(request(2, username: "alice", state: state))]
        let result = MergeRequestBrowserSnapshot(openItems: rows, authored: [], host: host, username: "me", scope: .init())
        #expect(result.own.map(\.id.iid) == [1])
        #expect(result.reviewed.map(\.id.iid) == [2])
    }

    @MainActor @Test(arguments: ["merged", "closed"])
    func lifecycleRetentionAndSeenTombstoneSurviveRestartWithoutIgnoringTheMR(_ state: String) throws {
        let suite = "MRLifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let settings = SettingsManager(defaults: defaults)
        settings.mrLifecycleLedger.record(try request(2, username: "alice"), for: target)
        #expect(settings.mrLifecycleLedger.takeTransitions(host: host, username: "me").isEmpty)
        settings.mrLifecycleLedger.record(try request(2, username: "alice", state: state), for: target)
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.mrLifecycleLedger.retainedRequests(host: host, username: "me").isEmpty)
        let receipt = try #require(reloaded.mrLifecycleLedger.unreadCompletions(host: host, username: "me",
            showMerged: true, showClosed: true).first)
        #expect(receipt.kind.rawValue == state)
        let events = reloaded.mrLifecycleLedger.takeTransitions(host: host, username: "me")
        #expect(events.count == 1 && events.first?.kind.rawValue == state)
        let seen = reloaded.mrLifecycleLedger.acknowledgeCompletion(id: receipt.id, host: host, username: "me")
        #expect(seen)
        reloaded.save()
        let acknowledged = SettingsManager(defaults: defaults)
        acknowledged.mrLifecycleLedger.record(try request(2, username: "alice", state: state), for: target)
        #expect(acknowledged.mrLifecycleLedger.isSuppressed(target))
        #expect(acknowledged.mrLifecycleLedger.retainedRequests(host: host, username: "me").isEmpty)
        #expect(acknowledged.mrLifecycleLedger.unreadCompletions(host: host, username: "me",
            showMerged: true, showClosed: true).isEmpty)
        #expect(acknowledged.mrLifecycleLedger.takeTransitions(host: host, username: "me").isEmpty)
        #expect(!acknowledged.ignoredMergeRequests.contains(target))
        acknowledged.mrLifecycleLedger.record(try request(2, username: "alice"), for: target)
        #expect(!acknowledged.mrLifecycleLedger.isSuppressed(target))
        #expect(acknowledged.mrLifecycleLedger.retainedRequests(host: host, username: "me").first?.state == "opened")
    }

    @Test func lifecycleRecordsOnlyVerifiedAccountTargetsAndEmitsRealDraftTransitionsOnce() throws {
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(9, username: "alice"), for: target)
        ledger.record(try request(2, username: "alice", host: "other.example.org"), for: target)
        #expect(ledger.targets(host: host, username: "me").isEmpty)
        ledger.record(try request(2, username: "alice"), for: target)
        #expect(ledger.takeTransitions(host: host, username: "me").isEmpty)
        ledger.record(try request(2, username: "alice", draft: true), for: target)
        ledger.record(try request(2, username: "alice", draft: true), for: target)
        let data = try JSONEncoder().encode(ledger)
        var restarted = try JSONDecoder().decode(MergeRequestLifecycleLedger.self, from: data)
        #expect(restarted.takeTransitions(host: host, username: "other").isEmpty)
        let events = restarted.takeTransitions(host: host, username: "me")
        #expect(events.count == 1 && events.first?.kind == .draft)
        #expect(restarted.takeTransitions(host: host, username: "me").isEmpty)
        restarted.record(try request(2, username: "alice"), for: target)
        #expect(restarted.takeTransitions(host: host, username: "me").map(\.kind) == [.ready])
        #expect(restarted.retainedRequests(host: "other.example.org", username: "me").isEmpty)
    }

    @Test func lateOlderObservationsCannotUndoDraftOrFinishedEvidence() throws {
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(2, username: "alice"), for: target, now: start)
        ledger.record(try request(2, username: "alice", draft: true), for: target, now: start.addingTimeInterval(2))
        ledger.record(try request(2, username: "alice"), for: target, now: start.addingTimeInterval(1))
        #expect(ledger.request(for: target)?.draft == true)
        #expect(ledger.takeTransitions(host: host, username: "me").map(\.kind) == [.draft])
        ledger.record(try request(2, username: "alice", state: "merged"), for: target, now: start.addingTimeInterval(4))
        ledger.acknowledgeFinished(target)
        ledger.record(try request(2, username: "alice"), for: target, now: start.addingTimeInterval(3))
        #expect(ledger.request(for: target)?.state == "merged")
        #expect(ledger.isSuppressed(target))
    }

    @Test func automaticArchiveEmitsTheVerifiedTransitionBeforeSuppressingItsRow() throws {
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        var ledger = MergeRequestLifecycleLedger()
        ledger.record(try request(2, username: "alice"), for: target)
        ledger.record(try request(2, username: "alice", state: "merged"), for: target, autoRemoveFinished: true)
        #expect(ledger.isSuppressed(target))
        #expect(ledger.retainedRequests(host: host, username: "me").isEmpty)
        #expect(ledger.takeTransitions(host: host, username: "me").map(\.kind) == [.merged])
        ledger.restore(target)
        #expect(!ledger.isSuppressed(target))
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
