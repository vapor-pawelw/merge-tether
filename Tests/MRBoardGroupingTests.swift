import Foundation
import Testing
@testable import GitLabTodos

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
