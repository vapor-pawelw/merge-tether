import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MRBoardGroupingTests {
    private let host = "gitlab.example.test"
    private var target: MRAutomationScope.Target { .init(host: host, username: "me", projectID: 1, iid: 2) }

    @Test func draftGroupingChangesPresentationWithoutChangingEffectiveAutomation() {
        var automation = AutomationSettings()
        automation.applyPreset(.full, for: .codex)
        automation.scope.setEnabled(true, for: target)
        let draft = MRBoardActivity(automation: automation, target: target, isDraft: true, grouping: .drafts)
        #expect(draft.group == .drafts && draft.isMuted)
        #expect(automation.scope.resolve(target, isDraft: true).active)
        automation.scope.setEnabled(false, for: target)
        let ready = MRBoardActivity(automation: automation, target: target, isDraft: false, grouping: .drafts)
        #expect(ready.group == .regular && !ready.isMuted)
        #expect(!automation.scope.resolve(target, isDraft: false).active)
        let finished = MRBoardActivity(automation: automation, target: target, isDraft: true,
            isFinished: true, grouping: .drafts)
        #expect(finished.group == .finished && !finished.isMuted)
    }

    @Test(arguments: [MRBoardGrouping.withoutAutomation, .drafts])
    func groupingPreferencePersistsWhileGlobalOffUsesDraftsAndReenableRestoresTheChoice(_ choice: MRBoardGrouping) throws {
        let suite = "MRBoardGroupingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.boardGrouping == .withoutAutomation)
        settings.automation.applyPreset(.full, for: .codex)
        settings.boardGrouping = choice
        #expect(settings.effectiveBoardGrouping == choice)
        settings.automation.applyPreset(.manual, for: .codex)
        #expect(settings.effectiveBoardGrouping == .drafts && settings.boardGrouping == choice)
        settings.save()
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.boardGrouping == choice && restored.effectiveBoardGrouping == .drafts)
        restored.automation.applyPreset(.full, for: .codex)
        #expect(restored.effectiveBoardGrouping == choice)
        restored.save()
        #expect(SettingsManager(defaults: defaults).boardGrouping == choice)
    }

    @Test func savingAPresentationGroupingChoiceDoesNotSignalAnAutomationPolicyChange() throws {
        let suite = "MRBoardGroupingSaveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        settings.save()
        let automation = settings.automation
        var policyChanged = false
        settings.onAutomationChanged = { _ in policyChanged = true }
        settings.boardGrouping = .drafts
        settings.save()
        #expect(!policyChanged && settings.automation == automation)
        #expect(SettingsManager(defaults: defaults).boardGrouping == .drafts)
    }

    @Test(arguments: [true, false])
    func automationOffSectionsRememberIndependentExpansionAcrossRestart(_ ownExpanded: Bool) throws {
        let suite = "MRBoardAutomationOffExpansion.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.ownAutomationOffExpanded && settings.reviewingAutomationOffExpanded)

        settings.ownAutomationOffExpanded = ownExpanded
        settings.reviewingAutomationOffExpanded = !ownExpanded
        #expect(settings.save())

        let restartedDefaults = try #require(UserDefaults(suiteName: suite))
        let restored = SettingsManager(defaults: restartedDefaults)
        #expect(restored.ownAutomationOffExpanded == ownExpanded)
        #expect(restored.reviewingAutomationOffExpanded == !ownExpanded)
    }

    @Test func legacyAndUnknownGroupingPreferencesUseTheDefaultWithoutChangingAutomation() throws {
        let suite = "MRBoardGroupingFallbackTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = SettingsManager(defaults: defaults)
        #expect(legacy.boardGrouping == .withoutAutomation)
        defaults.set("future-option", forKey: "boardGrouping")
        let unknown = SettingsManager(defaults: defaults)
        #expect(unknown.boardGrouping == .withoutAutomation)
        #expect(unknown.automation == legacy.automation)
    }

    private func request(_ iid: Int, draft: Bool, state: String = "opened") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":\(iid),"author":{"id":9,"username":"author","name":"Author"},"title":"MR",
         "web_url":"https://\(host)/g/p/-/merge_requests/\(iid)","state":"\(state)","draft":\(draft),
         "source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
    }

    @Test(arguments: [true, false])
    func automationOffHeaderCountsAllInactiveRowsWhileOnlyShowingThemWhenExpanded(_ expanded: Bool) throws {
        let rows = try (1...4).map { iid in
            let request = try request(iid, draft: false)
            let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: iid),
                title: request.title, url: request.webURL, needsDiscussion: iid != 4, mergeRequest: request)
            return MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        }
        let entries = CommandCenterBoardView.laneEntries(rows, automationOffExpanded: expanded,
            activity: { $0.id.iid == 1 ? .regular : .inactive }, hasHumanAction: { $0.id.iid != 3 })

        let expectedEntries: [CommandCenterBoardView.LaneEntry.ID] = expanded
            ? [.card(rows[0].id), .automationOff, .card(rows[1].id), .card(rows[2].id), .card(rows[3].id)]
            : [.card(rows[0].id), .automationOff]
        #expect(entries.map(\.id) == expectedEntries)
        let header = try #require(entries.first { $0.id == .automationOff })
        guard case let .automationOff(count, attentionCount) = header else {
            Issue.record("Missing Automation off header")
            return
        }
        #expect(count == 3)
        #expect(attentionCount == 1)
    }

    @Test func laneFilterCombinesCardChoicesAndNarrowsBySectionWithoutMovingCards() {
        let rows = (1...5).map { iid in
            let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: iid),
                title: "MR", url: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)")!,
                needsDiscussion: iid == 3 || iid == 4)
            return MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [],
                newReviewAssignedAt: iid == 1 || iid == 4 ? Date() : nil)
        }
        func visible(_ filter: MRBoardLaneFilter) -> [Int] {
            rows.filter { row in
                filter.matches(row, activity: row.id.iid >= 3 ? .inactive : .regular,
                    isPinned: row.id.iid == 2 || row.id.iid == 4)
            }.map(\.id.iid)
        }

        #expect(visible(.init(cards: [.new, .pinned])) == [1, 2, 4])
        #expect(visible(.init(cards: [.needsAttention], sections: [.inactive])) == [3, 4])
        #expect(visible(.init(cards: [.new, .pinned], sections: [.inactive])) == [4])
        #expect(visible(.init(sections: [.regular, .inactive])) == [1, 2, 3, 4, 5])
        #expect(visible(.init()) == [1, 2, 3, 4, 5])
    }

    @Test func changingTheSecondarySectionKeepsFinishedFirstAndPreservedRanksWithinTheirCurrentGroup() throws {
        let requests = try [request(1, draft: true), request(2, draft: false), request(3, draft: false), request(4, draft: true, state: "merged")]
        let items = requests.map { MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: $0.iid),
            title: $0.title, url: $0.webURL, mergeRequest: $0) }
        var automation = AutomationSettings()
        automation.applyPreset(.full, for: .codex)
        automation.scope.setEnabled(true, for: .init(host: host, username: "me", projectID: 1, iid: 1))
        automation.scope.setEnabled(false, for: target)
        let ranks = [items[0].id: 0, items[1].id: 1, items[2].id: 2]
        let board = MergeRequestBoardSnapshot(own: items, reviewed: [], todos: [], attention: [], handoffs: [],
            host: host, username: "me", preservedOrder: ranks, automation: automation, grouping: .drafts)
        #expect(board.own.map(\.id.iid) == [4, 2, 3, 1])
    }

    @Test(arguments: [false, true])
    func otherLaneUsesDraftGroupingIncludingTheGlobalOffFallback(_ automationOff: Bool) throws {
        var automation = AutomationSettings()
        automation.applyPreset(automationOff ? .manual : .full, for: .codex)
        automation.scope.setEnabled(true, for: target)
        let current = try request(2, draft: true)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Earlier work", prompt: "Check", createdAt: Date(), allowsPush: false, execution: .init(state: .failed))
        let board = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [], attention: [], handoffs: [job],
            host: host, username: "me", automation: automation, displayRequests: [current],
            grouping: automationOff ? .withoutAutomation : .drafts)
        #expect(board.otherCards(jobs: [job], host: host, username: "me", pinnedCards: []).first?.activityGroup == .drafts)
    }
}
