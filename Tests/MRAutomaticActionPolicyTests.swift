import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRAutomaticActionPolicyTests {
    @Test(arguments: MRAutomaticAction.allCases)
    func privateWorkBoundaryCannotBeOverriddenByPermissiveIndividualFlags(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.allowAutomaticPublicActions = false
            let ready = try request()
            #expect(settings.automaticWritesAllowed)
            #expect(!settings.automaticPublicWritesAllowed)
            #expect(!settings.permitsAutomaticAction(action, for: ready, target: target))
        }
    }
    @Test(arguments: [AutomationPackageDecision.undecided, .disabled, .enabled], MRAutomaticAction.allCases)
    func automaticActionsRequireExplicitConsentEvenWithPermissiveFlags(_ decision: AutomationPackageDecision, _ action: MRAutomaticAction) async throws {
        try await fixture { settings, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.packageDecision = decision
            let ready = try request()
            #expect(settings.automaticActionsAllowed)
            #expect(settings.permitsAutomaticAction(action, for: ready, target: target) == (decision == .enabled))
            #expect(settings.automation.hasEnabledAutomation == (decision == .enabled))
            let presentation = MREffectivePolicyPresentation(input: .init(request: ready, target: target,
                settings: settings, assistantReady: true))
            if decision != .enabled {
                #expect(presentation.clauses == [decision == .undecided ? .automationDecisionRequired : .automationOff])
            }
        }
    }

    @Test(arguments: MRAutomaticAction.allCases)
    func corruptedSafetyHistoryBlocksEveryAutomaticActionWithoutChangingPolicy(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, defaults in
            settings.automation.applyPreset(.full, for: .codex)
            settings.save()
            let expected = settings.automation
            defaults.set(Data("unreadable admission history".utf8), forKey: "workflowActivity")
            let restored = SettingsManager(defaults: defaults)
            let ready = try request()
            #expect(!restored.automaticActionsAllowed)
            #expect(!restored.permitsAutomaticAction(action, for: ready, target: target))
            #expect(restored.actionIsAutomatic(action, for: target))
            #expect(restored.automation == expected)
        }
    }

    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)

    private func request(draft: Bool = false) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example",
        "web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened",
        "draft":\(draft),"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
    }

    private func fixture(_ body: @MainActor (SettingsManager, UserDefaults) async throws -> Void) async throws {
        let suite = "MRAutomaticActionPolicyTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(SettingsManager(defaults: defaults), defaults)
    }

    @Test(arguments: MRAutomaticAction.allCases)
    func optingOutOnlyThatActionDoesNotChangeScopeTrackingOrGlobalPolicy(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, _ in
            let global = settings.automation
            #expect(settings.actionIsAutomatic(action, for: target))
            settings.setActionAutomatic(action, enabled: false, for: target)
            #expect(!settings.actionIsAutomatic(action, for: target))
            #expect(MRAutomaticAction.allCases.filter { $0 != action }.allSatisfy { settings.actionIsAutomatic($0, for: target) })
            #expect(settings.automation == global && !settings.automation.scope.isManaged(target))
            #expect(settings.ignoredMergeRequests.isEmpty && settings.mrActionIntents.isEmpty && settings.boardPins.isEmpty)
            let other = MRAutomationScope.Target(host: target.host, username: "another", projectID: 1, iid: 2)
            #expect(settings.actionIsAutomatic(action, for: other))
        }
    }

    @Test(arguments: MRAutomaticAction.allCases)
    func actionChoicesRequireExplicitSaveAndSurviveReloadAndRestore(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, defaults in
            settings.setActionAutomatic(action, enabled: false, for: target)
            #expect(SettingsManager(defaults: defaults).actionIsAutomatic(action, for: target))
            settings.save()
            let restored = SettingsManager(defaults: defaults)
            #expect(!restored.actionIsAutomatic(action, for: target))
            restored.setActionAutomatic(action, enabled: true, for: target)
            restored.save()
            #expect(SettingsManager(defaults: defaults).actionIsAutomatic(action, for: target))
        }
    }

    @Test func legacyApprovalOptOutIsTheSameControlAndRemainsPersisted() async throws {
        try await fixture { settings, defaults in
            defaults.set(try JSONEncoder().encode(Set([target])), forKey: "autoApproveOptOuts")
            let upgraded = SettingsManager(defaults: defaults)
            #expect(!upgraded.actionIsAutomatic(.approval, for: target))
            upgraded.setActionAutomatic(.approval, enabled: true, for: target)
            #expect(!upgraded.autoApproveOptOuts.contains(target))
            upgraded.save()
            #expect(SettingsManager(defaults: defaults).autoApproveOptOuts.isEmpty)
            #expect(settings.autoApproveOptOuts.isEmpty)
        }
    }

    @Test func autoMergeChoicesPersistAndLegacyOptOutIsOff() async throws {
        try await fixture { _, defaults in
            defaults.set(try JSONEncoder().encode(Set([target])), forKey: "autoMergeOptOuts")
            let settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeEnabled = false
            let monitor = TodoMonitorService(settings: settings, glab: GlabService())
            defer { monitor.stopTimer() }
            let ready = try request()
            let other = MRAutomationScope.Target(host: target.host, username: "other", projectID: 1, iid: 2)

            #expect(settings.autoMergePreference(for: target) == .off)
            for preference in [MRAutoMergePreference.on, .default, .off] {
                await monitor.setAutoMergePreference(preference, for: target)

                let restored = SettingsManager(defaults: defaults)
                #expect(restored.autoMergePreference(for: target) == preference)
                #expect(restored.permitsAutomaticAction(.merge, for: ready, target: target) == (preference == .on))
                #expect(restored.autoMergePreference(for: other) == .default)
                #expect(!restored.automation.autoMergeEnabled && !restored.automation.scope.isManaged(target))
            }
        }
    }

    @Test func autoMergeOnStillRequiresPublicActionConsentScopeAndReadiness() async throws {
        try await fixture { settings, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeEnabled = false
            settings.setAutoMergePreference(.on, for: target)
            let ready = try request()
            #expect(settings.permitsAutomaticAction(.merge, for: ready, target: target))

            settings.automation.scope.setManualChoice(.forceOn, for: target)
            #expect(!settings.permitsAutomaticAction(.merge, for: try request(draft: true), target: target))
            #expect(settings.setAutomationGloballyEnabled(false))
            #expect(!settings.permitsAutomaticAction(.merge, for: ready, target: target))
            #expect(settings.permitsAutomaticAction(.merge, for: ready, target: target, ignoringGlobalSuspension: true))
            #expect(settings.setAutomationGloballyEnabled(true))

            settings.automation.allowAutomaticPublicActions = false
            #expect(!settings.permitsAutomaticAction(.merge, for: ready, target: target))
            settings.automation.allowAutomaticPublicActions = true
            settings.automation.scope.setManualChoice(.paused, for: target)
            #expect(!settings.permitsAutomaticAction(.merge, for: ready, target: target))
        }
    }

    @Test(arguments: MRAutomaticAction.allCases)
    func autoAlwaysInheritsGlobalScopeAndDraftRules(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, _ in
            settings.automation.applyPreset(.full, for: .codex)
            let ready = try request()
            #expect(settings.permitsAutomaticAction(action, for: ready, target: target))
            settings.setActionAutomatic(action, enabled: false, for: target)
            #expect(!settings.permitsAutomaticAction(action, for: ready, target: target))
            settings.setActionAutomatic(action, enabled: true, for: target)
            settings.automation.scope.setManualChoice(.paused, for: target)
            #expect(!settings.permitsAutomaticAction(action, for: ready, target: target))
            settings.automation.scope.setManualChoice(.inherit, for: target)
            #expect(!settings.permitsAutomaticAction(action, for: try request(draft: true), target: target))
            settings.automation.applyPreset(.manual, for: .codex)
            settings.automation.scope.setManualChoice(.forceOn, for: target)
            #expect(!settings.permitsAutomaticAction(action, for: ready, target: target))
            #expect(settings.actionIsAutomatic(action, for: target))
        }
    }

    @Test(arguments: MRAutomaticAction.allCases)
    func serviceSavesActionChoiceWithoutCancellingWorkersOrChangingMembership(_ action: MRAutomaticAction) async throws {
        try await fixture { settings, defaults in
            settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
            var cancelled: [UUID] = []
            let monitor = TodoMonitorService(settings: settings, cancelPolicyJob: { id, _ in cancelled.append(id) })
            defer { monitor.stopTimer() }
            let global = settings.automation
            await monitor.setAutomaticAction(action, enabled: false, for: target)
            #expect(!SettingsManager(defaults: defaults).actionIsAutomatic(action, for: target))
            #expect(settings.automation == global && cancelled.isEmpty)
            #expect(!settings.automation.scope.isManaged(target) && settings.mrActionIntents.isEmpty)
        }
    }
}
