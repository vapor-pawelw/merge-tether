import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct IncomingReviewFilterTests {
    private let host = "gitlab.example.test"
    private let username = "me"

    private func target(_ iid: Int, username: String = "me") -> MRAutomationScope.Target {
        .init(host: host, username: username, projectID: 1, iid: iid)
    }

    private func todo(_ iid: Int, id: Int) throws -> Todo {
        try GlabService.decodeTodos(Data(#"[{"id":\#(id),"action_name":"review_requested","target_type":"MergeRequest","target_url":"https://gitlab.example.test/group/repo/-/merge_requests/\#(iid)","body":"Review","state":"pending","created_at":"2026-01-01T00:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"request-bot","name":"Request bot"},"target":{"id":10,"iid":\#(iid),"title":"Example","state":"opened","draft":false}}]"#.utf8))[0]
    }

    @Test func interruptedInboxCandidateSurvivesRestartAndIsReleasedToTheCorrectAccount() throws {
        let suite = "IncomingReviewFilter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let todo = try todo(2, id: 20)
        var ledger = settings.reviewAssignments
        ledger.observeInboxForFiltering([todo], host: host, username: username, enabled: true, excluding: [])
        #expect(ledger.incomingReviewFilter.suppresses(target(2)))
        #expect(settings.saveReviewAssignments(ledger))

        let restarted = SettingsManager(defaults: defaults)
        var recovered = restarted.reviewAssignments
        #expect(recovered.incomingReviewFilter.suppresses(target(2)))
        let released = recovered.incomingReviewFilter.releaseInterrupted()
        #expect(released)
        #expect(!recovered.incomingReviewFilter.suppresses(target(2)))
        #expect(recovered.incomingReviewFilter.notice(for: target(2)) == .interrupted)
        #expect(recovered.incomingReviewFilter.recoveredTodos(host: host, username: username).map(\.id) == [20])
        #expect(recovered.incomingReviewFilter.recoveredTodos(host: host, username: "someone-else").isEmpty)
    }

    @Test func oneBatchClassifiesBothSourcesAndAllowsMissingOrUncertainDecisionsThrough() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            let iid = try #require(Int(request.endpoint.split(separator: "/").last ?? ""))
            return InMemoryGitLab.output(self.requestJSON(iid))
        }
        let settings = try filteringSettings()
        let glab = gitlab.service(host: host, username: username)
        var batches: [[Int]] = []
        var autoHidden: [HiddenReview] = []
        let filter = IncomingReviewFilterCoordinator(settings: settings, glab: glab,
            dependencies: .init(probe: { _ in .ready(URL(fileURLWithPath: "/fake-verifier")) }),
            health: .init(persists: false), batchDelay: .zero, classify: { evidence, configuration, _, _, _ in
                #expect(configuration.model == settings.automation.codexVerificationModel.rawValue)
                #expect(configuration.criteria == "Review relevant changes")
                batches.append(evidence.map(\.iid).sorted())
                let values = evidence.compactMap { item -> [String: String]? in
                    switch item.iid {
                    case 2: ["id": item.id.uuidString, "decision": "accept", "reason": "Relevant"]
                    case 3: ["id": item.id.uuidString, "decision": "reject", "reason": "Outside scope"]
                    case 4: ["id": item.id.uuidString, "decision": "uncertain", "reason": "Missing context"]
                    default: nil
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: ["results": values])
                return try IncomingReviewFilterVerifier.decode(data, ids: Set(evidence.map(\.id)))
            })
        filter.onHidden = { autoHidden += $0 }
        defer { filter.stop() }

        var assignments = settings.reviewAssignments
        assignments.observe([], host: host, username: username, at: Date())
        filter.observeAssignments(assignments, host: host, username: username, excluding: [])
        filter.observeInbox(try [todo(2, id: 20), todo(4, id: 40), todo(5, id: 50)],
            host: host, username: username, excluding: [])
        let idFromInbox = settings.reviewAssignments.incomingReviewFilter.entries[target(2)]?.id
        assignments = settings.reviewAssignments
        assignments.observe(try [request(2), request(3)], host: host, username: username, at: Date())
        filter.observeAssignments(assignments, host: host, username: username, excluding: [])
        #expect(settings.reviewAssignments.incomingReviewFilter.entries[target(2)]?.id == idFromInbox)
        #expect([2, 3, 4, 5].allSatisfy { settings.reviewAssignments.incomingReviewFilter.suppresses(target($0)) })

        try await until { settings.ignoredMergeRequests.contains(target(3)) }
        let final = settings.reviewAssignments.incomingReviewFilter
        #expect(batches == [[2, 3, 4, 5]])
        #expect(final.entries[target(2)]?.outcome == .passed)
        #expect(settings.ignoredMergeRequests.contains(target(3)))
        #expect(settings.reviewAssignments.entries(host: host, username: username)?
            .first(where: { $0.request.iid == 3 })?.newSince == nil)
        #expect(autoHidden.map(\.target) == [target(3)])
        #expect(settings.filteredHiddenReviewDetails[target(3)]?.inboxNotification?.reason == "Outside scope")
        #expect(final.notice(for: target(4)) == .uncertain("Missing context"))
        #expect(final.notice(for: target(5)) == .uncertain(nil))
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        #expect(settings.restoreHiddenReviews([target(3)]))
        #expect(!settings.ignoredMergeRequests.contains(target(3)))
        #expect(settings.filteredHiddenReviewDetails.isEmpty)
    }

    @Test func aRejectedDecisionForStaleEvidenceAllowsTheUpdatedMergeRequestThrough() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        var head = "abc"
        gitlab.handler = { _ in InMemoryGitLab.output(self.requestJSON(2, head: head)) }
        let settings = try filteringSettings()
        let filter = IncomingReviewFilterCoordinator(settings: settings,
            glab: gitlab.service(host: host, username: username),
            dependencies: .init(probe: { _ in .ready(URL(fileURLWithPath: "/fake-verifier")) }),
            health: .init(persists: false), batchDelay: .zero, classify: { evidence, _, _, _, _ in
                let entry = try #require(evidence.first)
                head = "new-head"
                return [entry.id: .init(id: entry.id, decision: .reject, reason: "Outside scope")]
            })
        defer { filter.stop() }
        filter.observeInbox(try [todo(2, id: 20)], host: host, username: username, excluding: [])
        try await until { !settings.reviewAssignments.incomingReviewFilter.suppresses(target(2)) }
        #expect(settings.reviewAssignments.incomingReviewFilter.notice(for: target(2)) == .uncertain(nil))
    }

    @Test func missingAgentReleasesNewRequestsWhileAnAlreadyVisibleRequestStaysVisible() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let settings = try filteringSettings()
        let preferences = settings.incomingReviewFilterSettings
        #expect(settings.saveIncomingReviewFilterSettings(.init()))
        let filter = IncomingReviewFilterCoordinator(settings: settings,
            glab: gitlab.service(host: host, username: username),
            dependencies: .init(probe: { _ in .missingCLI }),
            health: .init(persists: false), batchDelay: .zero, classify: { _, _, _, _, _ in
                Issue.record("An unavailable verifier should not launch")
                return [:]
            })
        defer { filter.stop() }
        let existing = try todo(2, id: 20)
        filter.observeInbox([existing], host: host, username: username, excluding: [])
        #expect(settings.saveIncomingReviewFilterSettings(preferences))
        filter.observeInbox(try [existing, todo(3, id: 30)], host: host, username: username, excluding: [])
        #expect(!settings.reviewAssignments.incomingReviewFilter.suppresses(target(2)))
        try await until { !settings.reviewAssignments.incomingReviewFilter.suppresses(target(3)) }
        #expect(settings.reviewAssignments.incomingReviewFilter.notice(for: target(3)) == .unavailable)
        #expect(gitlab.requests.isEmpty)
    }

    @Test func agentAndManualHideShareOneRestorableStateAcrossRestart() throws {
        let suite = "IncomingReviewFilter.Hidden.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(Set([target(2)])), forKey: "ignoredMergeRequests")
        let settings = SettingsManager(defaults: defaults)
        let source = try request(3)
        let hidden = HiddenReview(target: target(3), title: source.title, url: source.webURL)
        #expect(settings.hideFilteredReviews([hidden]))
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.ignoredMergeRequests == [target(2), target(3)])
        #expect(reloaded.filteredHiddenReviewDetails[target(3)]?.url == source.webURL)
        #expect(reloaded.restoreHiddenReviews([target(3)]))
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.ignoredMergeRequests == [target(2)])
        #expect(restored.filteredHiddenReviewDetails.isEmpty)
    }

    @Test func legacyFilterPreferencesEnableInboxNoticesByDefault() throws {
        let preferences = try JSONDecoder().decode(IncomingReviewFilterSettings.self,
            from: Data(#"{"enabled":true,"criteria":"Review only migrations"}"#.utf8))
        #expect(preferences.showHiddenReviewsInInbox)
        #expect(preferences.activeCriteria == "Review only migrations")
    }

    @Test func phoneHiddenListSurvivesNoticeDismissalAndRejectsAnOlderHide() async throws {
        let suite = "IncomingReviewFilter.PhoneRestore.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let manual = try request(2)
        let filtered = try request(3)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(self.host) }
            if request.arguments.first == "auth" {
                return InMemoryGitLab.output(error: "Logged in to \(self.host) as \(self.username)")
            }
            return InMemoryGitLab.output("[]")
        }
        let glab = gitlab.service(host: host, username: username)
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        let original = TodoMonitorService(settings: settings, glab: glab)
        defer { original.stopTimer() }
        await original.bootstrap()
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: manual.title, url: manual.webURL)
        item.mergeRequest = manual
        let snapshot = MergeRequestBoardSnapshot(own: [], reviewed: [item], todos: [], attention: [], handoffs: [],
            host: host, username: username)
        let context = try #require(RemoteCardActionContext(card: RemoteBoardAdapter.card(item, account: "\(username)@\(host)"),
            board: snapshot, monitor: original))
        #expect(await context.execute(.remove) == .completed)
        #expect(!settings.intakeFilterHolds(target(2)))
        #expect(settings.hideFilteredReviews([.init(target: target(3), title: filtered.title, url: filtered.webURL)]))
        let notice = try #require(settings.filteredHiddenReviewDetails[target(3)]?.inboxNotification)
        #expect(original.acknowledgeHiddenReviewNotifications([notice.id]))

        let reloaded = SettingsManager(defaults: defaults)
        let monitor = TodoMonitorService(settings: reloaded, glab: glab)
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        let account = "\(username)@\(host)"
        func board() -> RemoteBoard {
            RemoteBoardAdapter.board(monitor: monitor, session: UUID(), account: account, includesReviewBoard: true)
        }
        let hidden = try #require(board().hiddenReviews)
        #expect(Set(hidden.map(\.mergeRequestIID)) == [2, 3])
        #expect(board().cards.allSatisfy { !$0.id.hasPrefix("completion:") })
        let card = try #require(hidden.first { $0.mergeRequestIID == 2 })
        let restore = try #require(card.actions.first)
        #expect(RemoteBoardAdapter.restoreHiddenReview(card, action: restore, monitor: monitor, account: "another@\(host)") == .changed)
        #expect(RemoteBoardAdapter.restoreHiddenReview(card, action: restore, monitor: monitor, account: account) == .completed)
        #expect(monitor.removeReviewedMergeRequest(item))
        #expect(RemoteBoardAdapter.restoreHiddenReview(card, action: restore, monitor: monitor, account: account) == .changed)
        let filteredCard = try #require(board().hiddenReviews?.first { $0.mergeRequestIID == 3 })
        let filteredRestore = try #require(filteredCard.actions.first)
        #expect(RemoteBoardAdapter.restoreHiddenReview(filteredCard, action: filteredRestore, monitor: monitor, account: account) == .completed)
        #expect(SettingsManager(defaults: defaults).ignoredMergeRequests == [target(2)])
    }

    @Test func inboxNoticeSurvivesRestartAndAcknowledgingItKeepsTheMergeRequestHidden() throws {
        let suite = "IncomingReviewFilter.Inbox.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let source = try request(2)
        let review = HiddenReview(target: target(2), title: source.title, url: source.webURL)
        #expect(settings.hideFilteredReviews([review]))
        let reloaded = SettingsManager(defaults: defaults)
        let notification = try #require(reloaded.filteredHiddenReviewDetails[target(2)]?.inboxNotification)
        #expect(!reloaded.acknowledgeHiddenReviewNotifications([notification.id], host: host, username: "someone-else"))
        #expect(reloaded.acknowledgeHiddenReviewNotifications([notification.id], host: host, username: username))
        let afterAcknowledgement = SettingsManager(defaults: defaults)
        #expect(afterAcknowledgement.ignoredMergeRequests.contains(target(2)))
        #expect(afterAcknowledgement.filteredHiddenReviewDetails[target(2)]?.inboxNotification == nil)
    }

    @Test func restorationExpiresAfterThreeDaysAcrossRestartWithoutLiftingTheHide() throws {
        let suite = "IncomingReviewFilter.Expiration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let manual = try request(2), filtered = try request(3)
        let now = Date()
        let expiration = now.addingTimeInterval(3 * 24 * 60 * 60)
        #expect(settings.hideReviewedMergeRequest(.init(target: target(2), title: manual.title, url: manual.webURL), now: now))
        #expect(settings.hideFilteredReviews([.init(target: target(3), title: filtered.title, url: filtered.webURL)], now: now))

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.canRestoreHiddenReview(target(2), now: expiration.addingTimeInterval(-1)))
        #expect(reloaded.canRestoreHiddenReview(target(3), now: expiration.addingTimeInterval(-1)))
        #expect(!reloaded.restoreHiddenReviews([target(2), target(3)], now: expiration))
        #expect(reloaded.ignoredMergeRequests == [target(2), target(3)])
        #expect(reloaded.intakeFilterHolds(target(3)))
    }

    @Test func oldHidesWithoutTimestampsGetOneRestoreWindowOnUpgrade() throws {
        let suite = "IncomingReviewFilter.LegacyExpiration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let later = now.addingTimeInterval(3 * 24 * 60 * 60)
        let manual = try request(2), filtered = try request(3)
        var legacy = HiddenMergeRequests()
        legacy.targets = [target(2), target(3), target(4)]
        legacy.details[target(2)] = .init(target: target(2), title: manual.title, url: manual.webURL, manuallyHidden: true)
        legacy.details[target(3)] = .init(target: target(3), title: filtered.title, url: filtered.webURL,
            inboxNotification: .init(id: UUID(), observedAt: now.addingTimeInterval(-4 * 24 * 60 * 60), reason: nil))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "ignoredMergeRequests")

        let upgraded = SettingsManager(defaults: defaults, now: now)
        #expect(upgraded.canRestoreHiddenReview(target(2), now: now))
        #expect(!upgraded.canRestoreHiddenReview(target(3), now: now))
        #expect(upgraded.canRestoreHiddenReview(target(4), now: now))

        let reopened = SettingsManager(defaults: defaults, now: later)
        #expect(!reopened.canRestoreHiddenReview(target(2), now: later))
        #expect(!reopened.canRestoreHiddenReview(target(4), now: later))
        #expect(reopened.ignoredMergeRequests == legacy.targets)
    }

    @Test func optingOutSkipsOnlyFutureInboxNoticesAndRestoringRemovesExistingNotice() throws {
        let settings = try filteringSettings()
        let first = try request(2), second = try request(3)
        #expect(settings.hideFilteredReviews([.init(target: target(2), title: first.title, url: first.webURL)]))
        var preferences = settings.incomingReviewFilterSettings
        preferences.showHiddenReviewsInInbox = false
        #expect(settings.saveIncomingReviewFilterSettings(preferences))
        #expect(settings.hideFilteredReviews([.init(target: target(3), title: second.title, url: second.webURL)]))
        #expect(settings.filteredHiddenReviewDetails[target(2)]?.inboxNotification != nil)
        #expect(settings.ignoredMergeRequests.contains(target(3)))
        #expect(settings.filteredHiddenReviewDetails[target(3)]?.inboxNotification == nil)
        #expect(settings.restoreHiddenReviews([target(2)]))
        #expect(settings.filteredHiddenReviewDetails[target(2)] == nil)
        #expect(!settings.ignoredMergeRequests.contains(target(2)))
    }

    @Test func duplicateOrMalformedVerdictsDoNotAuthorizeRejectingTheirTargets() throws {
        let duplicate = UUID(), valid = UUID(), unknown = UUID(), missing = UUID()
        let data = Data("""
        {"results":[
            {"id":"\(duplicate)","decision":"reject","reason":"Outside scope"},
            {"id":"\(duplicate)","decision":"invalid"},
            {"id":"\(valid)","decision":"accept","reason":"Relevant"},
            {"id":"\(unknown)","decision":"reject","reason":"Outside scope"}
        ]}
        """.utf8)
        let results = try IncomingReviewFilterVerifier.decode(data, ids: [duplicate, valid, missing])
        #expect(Set(results.keys) == [valid])
        #expect(results[valid]?.decision == .accept)
    }

    private func filteringSettings() throws -> SettingsManager {
        let defaults = try #require(UserDefaults(suiteName: "IncomingReviewFilterTests.\(UUID())"))
        let settings = SettingsManager(defaults: defaults)
        settings.automation.selectedAssistant = .codex
        #expect(settings.saveIncomingReviewFilterSettings(.init(enabled: true, criteria: "Review relevant changes")))
        return settings
    }

    private func request(_ iid: Int) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON(iid).utf8))
    }

    private func requestJSON(_ iid: Int, head: String = "abc") -> String {
        #"{"project_id":1,"iid":\#(iid),"author":{"id":7,"username":"alice","name":"Alice"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/\#(iid)","state":"opened","draft":false,"sha":"\#(head)","source_branch":"feature","target_branch":"main","labels":[]}"#
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The filter did not settle within one second")
    }
}
