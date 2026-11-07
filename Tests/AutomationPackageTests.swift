import Foundation
import Testing
@testable import GitLabTodos

struct AutomationPackageTests {
    @Test func selectedScopeMixesRepositoriesAndMRsAndKeepsExplicitPauses() throws {
        let first = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 42)
        let sibling = MRAutomationScope.Target(host: first.host, username: first.username, projectID: 1, iid: 43)
        let other = MRAutomationScope.Target(host: first.host, username: first.username, projectID: 2, iid: 7)
        var scope = MRAutomationScope()
        #expect(scope.resolve(first).active)
        scope.mode = .selected
        #expect(!scope.resolve(first).active)
        scope[first.repository] = .active
        scope[first] = .paused
        scope[other] = .active
        #expect(!scope.resolve(first).active)
        #expect(scope.resolve(sibling).active)
        #expect(scope.resolve(other).active)
        scope[first] = .inherit
        #expect(scope.resolve(first).active)
        #expect(try JSONDecoder().decode(MRAutomationScope.self, from: JSONEncoder().encode(scope)) == scope)
    }

    @Test func recommendationEnablesAssistantWorkflowsWithSeparateMergeAndConflictPushControls() {
        var settings = AutomationSettings()
        settings.reviewRequested.runner = .shell
        settings.reviewRequested.command = "exit 42"
        settings.autoMergeEnabled = true
        settings.allowAssistantTools = true

        settings.applyRecommended(for: .claude)

        #expect(settings.packageDecision == .enabled)
        #expect(settings.assistant == .claude)
        #expect(settings.reviewRequested.isEnabled)
        #expect(settings.reviewRequested.runner == .assistant)
        #expect(settings.reviewRequested.markDoneOnSuccess)
        #expect(settings.authorFeedback.isEnabled)
        #expect(settings.autoReReviewEnabled)
        #expect(!settings.autoMergeEnabled)
        #expect(settings.conflictTasksEnabled)
        #expect(!settings.allowConflictPush)
        #expect(!settings.allowAssistantTools)
        #expect(MergeWorkflowTrigger.allCases.allSatisfy { settings.workflowRules[$0].mode != .off })
        #expect(!settings.workflowRules[.pipelineFailure].retryInfrastructureFailure)
    }

    @Test func optingOutTurnsOffCurrentRulesWithoutErasingScriptConfiguration() {
        var settings = AutomationSettings()
        settings.applyRecommended(for: .codex)
        settings.reviewRequested.runner = .shell
        settings.reviewRequested.command = "echo example"
        settings.autoMergeEnabled = true
        settings.conflictTasksEnabled = true

        settings.disableAssistantPackage()

        #expect(settings.packageDecision == .disabled)
        #expect(!settings.reviewRequested.isEnabled)
        #expect(settings.reviewRequested.command == "echo example")
        #expect(!settings.autoMergeEnabled)
        #expect(!settings.conflictTasksEnabled)
        #expect(!settings.autoReReviewEnabled)
        #expect(MergeWorkflowTrigger.allCases.allSatisfy { settings.workflowRules[$0].mode == .off })
    }

    @Test func legacyCodexConfigurationEnablesNewDefaultsOnceWithoutChangingExplicitWorkflowModes() throws {
        let legacy = Data("""
            {"codexRelayEnabled":true,"autoReReviewEnabled":false,
             "workflowRules":{"rules":{"pipelineFailure":{"mode":"off","projects":"","targetBranches":"",
                 "requiredLabel":"","retryInfrastructureFailure":false,"waitHours":48}}}}
            """.utf8)
        let decoder = JSONDecoder()
        var migrated = try decoder.decode(AutomationSettings.self, from: legacy)
        #expect(!migrated.autoReReviewEnabled && migrated.conflictTasksEnabled)
        #expect(migrated.reviewRequested.isEnabled && migrated.authorFeedback.isEnabled)
        #expect(migrated.workflowRules[.newDiscussion].mode == .assistant)
        #expect(migrated.workflowRules[.pipelineFailure].mode == .off)
        #expect(!migrated.autoMergeEnabled && !migrated.allowConflictPush)
        migrated.autoReReviewEnabled = false
        #expect(try decoder.decode(AutomationSettings.self, from: JSONEncoder().encode(migrated)) == migrated)

        let optedOut = Data(#"{"codexRelayEnabled":true,"packageDecision":"disabled"}"#.utf8)
        #expect(try !decoder.decode(AutomationSettings.self, from: optedOut).autoReReviewEnabled)
    }

    @Test func enabledProjectPermissionsUseOptionalExactAllowlists() {
        var settings = AutomationSettings()
        settings.allowAssistantTools = true
        settings.allowConflictPush = true
        settings.conflictTasksEnabled = true
        settings.autoMergeEnabled = true
        #expect(settings.permitsAssistantTools(project: "group/api"))
        #expect(settings.permitsConflictPush(project: "group/api"))
        #expect(settings.permitsAutoMerge(project: "group/api"))

        settings.assistantToolProjects = "group/api"
        settings.conflictPushProjects = "group/api"
        settings.autoMergeProjects = "group/api"
        #expect(settings.permitsConflictPush(project: "group/api"))
        #expect(settings.permitsAutoMerge(project: "group/api"))
        #expect(!settings.permitsConflictPush(project: "group/api-v2"))
    }

    @Test func fullPresetEnablesEveryConfiguredAutomaticActionWithinScope() {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .claude)
        #expect(settings.packageDecision == .enabled && settings.assistant == .claude)
        #expect(settings.reviewRequested.isEnabled && settings.authorFeedback.isEnabled)
        #expect(settings.autoVerifyReReview && settings.autoReReviewEnabled)
        #expect(settings.publicationMode == .all && settings.autoApproveEnabled && settings.autoMergeEnabled)
        #expect(settings.allowFollowUpPush && settings.autoResolveOwnReviewThreads && settings.autoResolveAcceptedFeedback)
        #expect(settings.conflictTasksEnabled && settings.allowAssistantTools && settings.allowConflictPush)
        #expect(settings.permitsConflictPush(project: "any/repository") && settings.permitsAutoMerge(project: "any/repository"))
    }

    @Test func fullPresetTracksReviewWaitingLocallyWithoutStartingAnAgent() {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        #expect(settings.workflowRules[.reviewWaiting].mode == .notify)
        #expect(settings.workflowRules[.reviewWaiting].waitHours == 48)
        #expect(MergeWorkflowTrigger.allCases.filter { $0 != .reviewWaiting }
            .allSatisfy { settings.workflowRules[$0].mode == .assistant })
        #expect(MergeWorkflowTrigger.reviewWaiting.allowedModes == [.off, .notify])
        #expect(MergeWorkflowTrigger.newDiscussion.allowedModes.contains(.assistant))
    }

    @Test func legacyReviewWaitingAgentRuleMigratesWithoutChangingOtherRulesOrThresholds() throws {
        let json = #"{"assistantDefaultsVersion":1,"workflowRules":{"rules":{"reviewWaiting":{"mode":"assistant","projects":"team/repo","targetBranches":"main","requiredLabel":"review","retryInfrastructureFailure":false,"waitHours":72},"newDiscussion":{"mode":"assistant","projects":"","targetBranches":"","requiredLabel":"","retryInfrastructureFailure":false,"waitHours":48}}}}"#
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        let waiting = settings.workflowRules[.reviewWaiting]
        #expect(waiting.mode == .notify && waiting.waitHours == 72)
        #expect(waiting.projects == "team/repo" && waiting.targetBranches == "main" && waiting.requiredLabel == "review")
        #expect(settings.workflowRules[.newDiscussion].mode == .assistant)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let workflow = try #require(encoded["workflowRules"] as? [String: Any])
        let rules = try #require(workflow["rules"] as? [String: [String: Any]])
        #expect(rules["reviewWaiting"]?["mode"] as? String == "notify")
    }

    @MainActor @Test(arguments: ["assistant", "off"])
    func reviewWaitingMigrationPersistsThroughNormalSettingsSave(mode: String) throws {
        let suite = "AutomationPackageTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule: [String: Any] = ["mode": mode, "projects": "", "targetBranches": "", "requiredLabel": "",
                                   "retryInfrastructureFailure": false, "waitHours": 48]
        let legacy: [String: Any] = ["assistantDefaultsVersion": 1, "packageDecision": "disabled",
                                     "workflowRules": ["rules": ["reviewWaiting": rule]]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "automation")
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.automation.workflowRules[.reviewWaiting].mode == (mode == "off" ? .off : .notify))
        settings.save()
        let saved = try #require(defaults.data(forKey: "automation"))
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: saved)
        #expect(loaded.workflowRules[.reviewWaiting].mode == (mode == "off" ? .off : .notify))
        #expect(loaded.workflowRules[.reviewWaiting].waitHours == 48 && loaded.packageDecision == .disabled)
    }

    @Test func reviewWaitingCanBeDisabledButCannotRegainAgentExecution() {
        var rules = MergeWorkflowRules()
        rules[.reviewWaiting].mode = .assistant
        rules[.reviewWaiting].waitHours = 96
        #expect(rules[.reviewWaiting].mode == .notify)
        #expect(rules[.reviewWaiting].effectiveMode(for: .reviewWaiting) == .notify)
        rules[.reviewWaiting].mode = .off
        #expect(rules[.reviewWaiting].mode == .off && rules[.reviewWaiting].waitHours == 96)
        #expect(!rules.enabled.contains(.reviewWaiting))
        var other = MergeWorkflowRule()
        other.mode = .assistant
        #expect(other.effectiveMode(for: .reviewWaiting) == .notify)
        #expect(other.effectiveMode(for: .newDiscussion) == .assistant)
    }

    @Test func checkpointsPresetPreparesWorkButLeavesSensitiveActionsManual() {
        var settings = AutomationSettings()
        settings.applyPreset(.checkpoints, for: .codex)
        #expect(settings.packageDecision == .enabled && settings.reviewRequested.isEnabled && settings.authorFeedback.isEnabled)
        #expect(settings.conflictTasksEnabled && settings.autoVerifyReReview)
        #expect(settings.publicationMode == .aiReplies && !settings.autoApproveEnabled && !settings.autoMergeEnabled)
        #expect(!settings.allowFollowUpPush && !settings.allowConflictPush)
        #expect(!settings.autoResolveOwnReviewThreads && !settings.autoResolveAcceptedFeedback)
    }

    @Test func manualPresetDisablesAutomaticActionsAndVerifierWithoutErasingTaskConfiguration() {
        var settings = AutomationSettings()
        settings.authorFeedback.promptTemplate = "My custom task"
        settings.applyPreset(.manual, for: .codex)
        #expect(settings.packageDecision == .disabled && !settings.usesAssistant)
        #expect(!settings.autoVerifyReReview && !settings.autoReReviewEnabled)
        #expect(settings.publicationMode == .manual && !settings.autoApproveEnabled && !settings.autoMergeEnabled)
        #expect(!settings.autoResolveOwnReviewThreads && !settings.autoResolveAcceptedFeedback)
        #expect(!settings.allowFollowUpPush && !settings.allowConflictPush)
        #expect(settings.authorFeedback.promptTemplate == "My custom task")
    }

    @Test func onboardingOffersFullByDefaultOnlyBeforeTheUserHasChosen() {
        #expect(AutomationPreset.onboardingDefault(for: .undecided) == .full)
        #expect(AutomationPreset.onboardingDefault(for: .enabled) == nil)
        #expect(AutomationPreset.onboardingDefault(for: .disabled) == nil)
    }

    @Test func publicationModesAreExclusiveAndKeepLegacyBooleanPersistence() throws {
        var settings = AutomationSettings()
        settings.publicationMode = .all
        #expect(settings.publishDraftsWithoutConfirmation && settings.publishAIRepliesWithoutConfirmation)
        settings.publicationMode = .manual
        #expect(!settings.publishDraftsWithoutConfirmation && !settings.publishAIRepliesWithoutConfirmation)
        settings.publicationMode = .aiReplies
        #expect(!settings.publishDraftsWithoutConfirmation && settings.publishAIRepliesWithoutConfirmation)
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)).publicationMode == .aiReplies)
        let legacyAll = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"publishDraftsWithoutConfirmation":true,"publishAIRepliesWithoutConfirmation":false}"#.utf8))
        #expect(legacyAll.publicationMode == .all)
        let legacyManual = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"publishDraftsWithoutConfirmation":false,"publishAIRepliesWithoutConfirmation":false}"#.utf8))
        #expect(legacyManual.publicationMode == .manual)
    }

    @Test func legacyMigrationPreservesExplicitOptOutsWhileFillingOnlyMissingDefaults() throws {
        let json = #"{"packageDecision":"enabled","autoReReviewEnabled":false,"conflictTasksEnabled":false,"publishAIRepliesWithoutConfirmation":false,"autoResolveOwnReviewThreads":false,"autoResolveAcceptedFeedback":false,"allowFollowUpPush":false,"reviewRequested":{"isEnabled":false,"runner":"assistant","promptTemplate":"Custom review"},"authorFeedback":{"isEnabled":false,"runner":"assistant","promptTemplate":"Custom follow-up"}}"#
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        #expect(!loaded.autoReReviewEnabled && !loaded.conflictTasksEnabled)
        #expect(!loaded.reviewRequested.isEnabled && !loaded.authorFeedback.isEnabled)
        #expect(!loaded.publishAIRepliesWithoutConfirmation && !loaded.autoResolveOwnReviewThreads && !loaded.autoResolveAcceptedFeedback)
        #expect(!loaded.allowFollowUpPush && !loaded.allowConflictPush && !loaded.autoMergeEnabled)
    }

    @Test func legacyEnabledButEmptyAllowlistsCannotGainPermissionsOnUpgrade() throws {
        let json = #"{"assistantDefaultsVersion":1,"conflictTasksEnabled":true,"allowAssistantTools":true,"assistantToolProjects":"","allowConflictPush":true,"conflictPushProjects":"","autoMergeEnabled":true,"autoMergeProjects":""}"#
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        #expect(!loaded.permitsAssistantTools(project: "any/repo"))
        #expect(!loaded.permitsConflictPush(project: "any/repo"))
        #expect(!loaded.permitsAutoMerge(project: "any/repo"))
    }

    @Test func explicitlyAppliedFullKeepsUnrestrictedPermissionsAcrossReload() throws {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded.permitsAssistantTools(project: "any/repo"))
        #expect(loaded.permitsConflictPush(project: "any/repo"))
        #expect(loaded.permitsAutoMerge(project: "any/repo"))
    }

    @Test func removesKnownCredentialsAndTruncatedPrivateKeysFromEvidence() {
        let redacted = GlabService.redactWorkflowEvidence("""
            token=glpat-123456789012345
            a line to keep
            -----BEGIN OPENSSH PRIVATE KEY-----
            sensitive-partial-content
            """)
        #expect(redacted.contains("a line to keep"))
        #expect(!redacted.contains("glpat-"))
        #expect(!redacted.contains("sensitive-partial-content"))
    }

    @Test func projectFiltersMatchExactPathsAndKeepRoundTrip() throws {
        var settings = AutomationSettings()
        settings.applyRecommended(for: .codex)
        settings.workflowRules[.pipelineFailure].projects = " group/api, other/service "
        let copy = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(copy == settings)
        #expect(copy.workflowRules[.pipelineFailure].includes(project: "group/api"))
        #expect(!copy.workflowRules[.pipelineFailure].includes(project: "group/api-v2"))
    }
    @Test func followUpPushIsIndependentFromConflictPushAndPreservesOptOut() throws {
        var configuration = AutomationSettings()
        #expect(configuration.allowFollowUpPush)
        #expect(!configuration.allowConflictPush)
        configuration.allowFollowUpPush = false
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(configuration))
        #expect(!loaded.allowFollowUpPush)
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8)).allowFollowUpPush)
        configuration.disableAssistantPackage()
        #expect(!configuration.allowFollowUpPush)
    }

    @Test func ownThreadResolutionDefaultsOnAndHonorsItsIndependentSwitch() throws {
        #expect(AutomationSettings().autoResolveOwnReviewThreads)
        let on = AssistantAutomationRunner.MRWorkflow.review.instructions(allowFollowUpPush: false, autoResolveOwnReviewThreads: true)
        #expect(on.contains("even without") || on.contains("no MR skill"))
        #expect(on.contains("author's replies"))
        #expect(on.contains("first non-system note belongs to the authenticated user"))
        #expect(on.contains("Do not approve directly"))
        let off = AssistantAutomationRunner.MRWorkflow.review.instructions(allowFollowUpPush: true, autoResolveOwnReviewThreads: false)
        #expect(off.contains("Do not resolve any discussion"))
        #expect(!off.contains("Automatic resolution of my own review findings is ON"))
        var settings = AutomationSettings()
        settings.autoResolveOwnReviewThreads = false
        #expect(try !JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)).autoResolveOwnReviewThreads)
        #expect(settings.autoApproveEnabled)
        settings.disableAssistantPackage()
        #expect(!settings.autoResolveOwnReviewThreads)
    }

    @Test @MainActor func conflictAndLegacyHandoffsCannotAuthorizeAuthorFollowUpPublication() throws {
        let suite = "AuthorRunKind.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        let legacy = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Legacy", prompt: "", createdAt: Date(), allowsPush: false)
        let conflict = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Conflict", prompt: "", createdAt: Date(), allowsPush: true)
        settings.assistantHandoffs = [legacy, conflict]
        #expect(FollowUpVerificationStore.latestRun(for: work, username: "me", settings: settings) == nil)
        let author = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Author", prompt: "", createdAt: .distantPast, allowsPush: false, followUpPushAllowed: true)
        settings.assistantHandoffs.append(author)
        #expect(FollowUpVerificationStore.latestRun(for: work, username: "me", settings: settings)?.id == author.id)
    }

    @Test(arguments: [AutomationAssistant.codex, .claude],
          [AssistantAutomationRunner.Access.preparation, .gitLabRead, .configuredTools])
    @MainActor func executableCLITasksCanInspectLiveEvidenceAndSavePrivateDrafts(
        assistant: AutomationAssistant, access: AssistantAutomationRunner.Access
    ) async throws {
        let suite = "ExecutableCLITaskPolicy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = assistant
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 7, iid: 11)
        let url = try #require(URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11"))
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .succeeded, summary: "Synthetic prompt fixture"), output: "")
        })
        let handoff = try await AssistantAutomationRunner.launch(assistant, title: "Inspect merge blocker",
            mergeRequestURL: url, prompt: "Inspect the live MR and save a private reply if warranted.", workspace: "",
            access: access, work: work, username: "me", settings: settings,
            expectedHeadSHA: String(repeating: "a", count: 40), jobCoordinator: coordinator)
        defer { coordinator.cancel(handoff.id) }
        #expect(!handoff.prompt.contains("external tools, follow URLs"))
        #expect(!handoff.prompt.contains("as text using the supplied evidence"))
        #expect(!handoff.prompt.contains("Otherwise leave drafts in this chat"))
        #expect(handoff.prompt.contains("authenticated local `glab`"))
        #expect(handoff.prompt.contains("private `draft_notes` endpoint"))
        #expect(handoff.prompt.contains("Never classify your own reply as the source comment"))
        #expect(handoff.prompt.contains("load and follow the applicable installed MR skills"))
        #expect(handoff.prompt.contains("Do not publish directly yourself"))
        #expect(!handoff.allowsPush && handoff.followUpPushAllowed == nil)
        #expect(!handoff.prompt.contains("Automatic author-follow-up push is ON"))
        #expect(handoff.workflow == nil)
    }

    @Test(arguments: [AssistantAutomationRunner.MRWorkflow.review, .followUp])
    @MainActor func explicitMRWorkflowsKeepLiveToolsAndTheirRemoteActionBoundaries(
        workflow: AssistantAutomationRunner.MRWorkflow
    ) async throws {
        let suite = "ExecutableMRWorkflowPolicy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .claude
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 7, iid: 11)
        let url = try #require(URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11"))
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .succeeded, summary: "Synthetic workflow fixture"), output: "")
        })
        let handoff = try await AssistantAutomationRunner.launch(.claude, title: "MR workflow",
            mergeRequestURL: url, prompt: "Inspect this synthetic MR.", workspace: "", access: .preparation,
            work: work, username: "me", settings: settings, mrWorkflow: workflow,
            expectedHeadSHA: String(repeating: "a", count: 40), jobCoordinator: coordinator)
        defer { coordinator.cancel(handoff.id) }
        #expect(!handoff.prompt.contains("external tools, follow URLs"))
        #expect(handoff.prompt.contains("authenticated local `glab`"))
        #expect(handoff.prompt.contains("private `draft_notes` endpoint"))
        #expect(handoff.prompt.contains("Get my explicit approval before publishing"))
        #expect(!handoff.allowsPush)
        if workflow == .followUp {
            #expect(handoff.followUpPushAllowed == true)
            #expect(handoff.prompt.contains("Mandatory author follow-up order"))
        } else {
            #expect(handoff.followUpPushAllowed == nil)
            #expect(handoff.prompt.contains("Leave the MR branches and code unchanged"))
        }
    }

    @Test @MainActor func obsoleteReminderCannotLaunchEvenThroughAnExplicitManualRequest() async throws {
        let suite = "RetiredReminderWorkflowPolicy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 7, iid: 11)
        let url = try #require(URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11"))
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            Issue.record("A retired reminder must not execute")
            return .init(result: .init(status: .succeeded, summary: "Unexpected reminder"), output: "")
        })
        defer { coordinator.prepareForTermination(settings: settings) }
        do {
            _ = try await AssistantAutomationRunner.launch(.codex, title: "Old reminder", mergeRequestURL: url,
                prompt: "Prepare an old reminder.", workspace: "", access: .gitLabRead, work: work, username: "me",
                settings: settings, mrWorkflow: .draftReply, manual: true, jobCoordinator: coordinator)
            Issue.record("A retired reminder must not create a new job")
        } catch {
            #expect(error as? AssistantJobExecutor.ExecutionError == .disabledPermission)
        }
        #expect(settings.assistantHandoffs.isEmpty)
    }

    @Test @MainActor func reviewPublicationPolicyKeepsHumanRepliesPrivateUnlessPublishAllIsOn() async throws {
        let suite = "ReviewPublicationPolicy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
        let url = try #require(URL(string: "https://gitlab.example.org/group/repo/-/merge_requests/2"))
        for publishAll in [false, true] {
            settings.automation.publishDraftsWithoutConfirmation = publishAll
            let coordinator = AssistantJobCoordinator(execute: { _, _ in
                .init(result: .init(status: .succeeded, summary: "Fixture review"), output: "")
            })
            let handoff = try await AssistantAutomationRunner.launch(.codex, title: "Review", mergeRequestURL: url, prompt: "Review", workspace: "", access: .gitLabRead,
                work: work, username: "me", settings: settings, mrWorkflow: .review, jobCoordinator: coordinator)
            if publishAll {
                #expect(handoff.prompt.contains("Publish comments without confirmation is ON"))
                #expect(!handoff.prompt.contains("For likely manual, unclassified or uncertain source comments, leave drafts private"))
            } else {
                #expect(handoff.prompt.contains("For likely manual, unclassified or uncertain source comments, leave drafts private"))
                #expect(handoff.prompt.contains("ask for approval"))
            }
        }
    }

}
