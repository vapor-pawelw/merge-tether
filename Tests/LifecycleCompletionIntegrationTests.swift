import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor
@Suite("Lifecycle completion integration")
struct LifecycleCompletionIntegrationTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func obsoletePreferencesCannotHideCompletionsOrKeepFinishedMRsOnTheBoard() throws {
        try fixture(legacyPreferences: true) { monitor, settings in
            // given
            try close(settings)
            // when
            let receipt = try #require(monitor.lifecycleCompletions.first)
            // then
            #expect(monitor.ownMergeRequestItems.isEmpty)
            let seen = monitor.acknowledgeLifecycleCompletion(id: receipt.id)
            #expect(seen && monitor.lifecycleCompletions.isEmpty)
            settings.mrLifecycleLedger.record(try request(), for: target, now: start.addingTimeInterval(2))
            #expect(monitor.ownMergeRequestItems.map(\.id.iid) == [11])
        }
    }

    @Test func automaticCleanupKeepsUnreadReceiptEvenAfterMRIsRemovedFromManagement() throws {
        try fixture { monitor, settings in
            try close(settings)
            let event = try #require(monitor.lifecycleCompletions.first)
            let before = settings.automation
            monitor.applySettings()
            #expect(monitor.ownMergeRequestItems.isEmpty)
            #expect(monitor.lifecycleCompletions.map(\.id) == [event.id])
            settings.ignoredMergeRequests.insert(target)
            #expect(monitor.lifecycleCompletions.map(\.id) == [event.id])
            #expect(settings.automation == before)
            let board = monitor.boardSnapshot
            let cards = board.otherCards(jobs: [], host: target.host, username: target.username, pinnedCards: [])
            #expect(cards.contains { if case .completion(let value) = $0.content { return value.id == event.id }; return false })
        }
    }

    @Test func staleSeenCannotAcknowledgeLaterClosureOfSameMRAndHead() throws {
        try fixture { monitor, settings in
            try close(settings)
            let old = try #require(monitor.lifecycleCompletions.first)
            settings.mrLifecycleLedger.record(try request(), for: target, now: start.addingTimeInterval(2))
            settings.mrLifecycleLedger.record(try request(state: "closed"), for: target, now: start.addingTimeInterval(3))
            let current = try #require(monitor.lifecycleCompletions.first)
            #expect(current.id != old.id && monitor.ownMergeRequestItems.isEmpty)
            let stale = monitor.acknowledgeLifecycleCompletion(id: old.id)
            #expect(!stale && monitor.lifecycleCompletions.map(\.id) == [current.id])
            let seen = monitor.acknowledgeLifecycleCompletion(id: current.id)
            #expect(seen && monitor.lifecycleCompletions.isEmpty && settings.ignoredMergeRequests.isEmpty)
        }
    }

    @Test func completionVisibilityAndAcknowledgementRemainAccountScoped() throws {
        try fixture { monitor, settings in
            try close(settings)
            let event = try #require(monitor.lifecycleCompletions.first)
            monitor.glab.currentUsername = "other"
            let wrongAccount = monitor.acknowledgeLifecycleCompletion(id: event.id)
            #expect(!wrongAccount && monitor.lifecycleCompletions.isEmpty)
            monitor.glab.currentUsername = target.username
            #expect(monitor.lifecycleCompletions.map(\.id) == [event.id])
        }
    }

    @Test func receiptAndReopenedProposalHaveSeparateIdentitiesAndCompletionIsNeverInactive() throws {
        try fixture { monitor, settings in
            try close(settings)
            let event = try #require(monitor.lifecycleCompletions.first)
            let open = try request()
            let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 7, iid: 11), title: open.title,
                url: open.webURL, mergeRequest: open)
            var automation = AutomationSettings()
            automation.applyPreset(.full, for: .codex)
            automation.scope.setEnabled(false, for: target)
            let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [item], handoffs: [],
                host: target.host, username: target.username, automation: automation, completions: [event])
            let cards = board.otherCards(jobs: [], host: target.host, username: target.username, pinnedCards: [])
            #expect(cards.count == 2)
            #expect(Set(cards.map(\.id)).count == 2)
            let receipt = try #require(cards.first { if case .completion = $0.content { return true }; return false })
            #expect(receipt.activityGroup == .regular)
            #expect(board.otherCards(jobs: [], host: target.host, username: "other", pinnedCards: []).isEmpty)
        }
    }

    @Test func remoteCompletionSeenRequiresCurrentAccountEventAndExactToken() throws {
        try fixture { monitor, settings in
            try close(settings)
            let event = try #require(monitor.lifecycleCompletions.first)
            let account = "\(target.username)@\(target.host)"
            let card = RemoteBoardAdapter.card(event, account: account)
            let action = try #require(card.actions.first)
            #expect(card.title == event.title && card.url == event.url)
            #expect(card.mergeRequestIID == 11 && card.presentation?.draftBadge == "CLOSED")
            #expect(card.presentation?.author == "Synthetic author")
            #expect(card.actions.map(\.kind) == [.markDone] && card.drafts.isEmpty)
            #expect(RemoteBoardAdapter.card(event, account: "other@host").actions.first?.token != action.token)
            var invalid = action
            invalid.token = "changed"
            let wrongToken = RemoteBoardAdapter.acknowledgeCompletion(card, action: invalid, monitor: monitor, account: account)
            let wrongAccount = RemoteBoardAdapter.acknowledgeCompletion(card, action: action, monitor: monitor, account: "other@host")
            #expect(!wrongToken && !wrongAccount)
            settings.mrLifecycleLedger.record(try request(), for: target, now: start.addingTimeInterval(2))
            settings.mrLifecycleLedger.record(try request(state: "closed"), for: target, now: start.addingTimeInterval(3))
            let oldResult = RemoteBoardAdapter.acknowledgeCompletion(card, action: action, monitor: monitor, account: account)
            #expect(!oldResult && monitor.lifecycleCompletions.count == 1)
            let latest = try #require(monitor.lifecycleCompletions.first)
            let currentCard = RemoteBoardAdapter.card(latest, account: account)
            let currentAction = try #require(currentCard.actions.first)
            let accepted = RemoteBoardAdapter.acknowledgeCompletion(currentCard, action: currentAction, monitor: monitor, account: account)
            #expect(accepted && monitor.lifecycleCompletions.isEmpty)
            #expect(settings.mrActionIntents.isEmpty && settings.assistantHandoffs.isEmpty)
        }
    }

    private func close(_ settings: SettingsManager) throws {
        settings.mrLifecycleLedger.record(try request(), for: target, now: start)
        settings.mrLifecycleLedger.record(try request(state: "closed"), for: target, now: start.addingTimeInterval(1))
    }

    private func fixture(legacyPreferences: Bool = false, _ body: (TodoMonitorService, SettingsManager) throws -> Void) throws {
        let suite = "LifecycleCompletionIntegration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if legacyPreferences {
            defaults.set(false, forKey: "autoRemoveFinishedMRs")
            defaults.set(false, forKey: "showMergedMRCompletions")
            defaults.set(false, forKey: "showClosedMRCompletions")
        }
        let settings = SettingsManager(defaults: defaults)
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        settings.resolvedHost = target.host
        let glab = GlabService()
        glab.resolvedHost = target.host
        glab.currentUsername = target.username
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        try body(monitor, settings)
    }

    private func request(state: String = "opened") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Synthetic author"},"title":"Exact completion title","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"\#(state)","draft":false,"sha":"synthetic-head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
    }
}
