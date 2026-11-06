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
        #expect(migrated.autoReReviewEnabled && migrated.conflictTasksEnabled)
        #expect(migrated.reviewRequested.isEnabled && migrated.authorFeedback.isEnabled)
        #expect(migrated.workflowRules[.newDiscussion].mode == .assistant)
        #expect(migrated.workflowRules[.pipelineFailure].mode == .off)
        #expect(!migrated.autoMergeEnabled && !migrated.allowConflictPush)
        migrated.autoReReviewEnabled = false
        #expect(try decoder.decode(AutomationSettings.self, from: JSONEncoder().encode(migrated)) == migrated)

        let optedOut = Data(#"{"codexRelayEnabled":true,"packageDecision":"disabled"}"#.utf8)
        #expect(try !decoder.decode(AutomationSettings.self, from: optedOut).autoReReviewEnabled)
    }

    @Test func toolsAndRemoteChangesRequireAnExactProject() {
        var settings = AutomationSettings()
        settings.allowAssistantTools = true
        settings.allowConflictPush = true
        settings.conflictTasksEnabled = true
        settings.autoMergeEnabled = true
        #expect(!settings.permitsAssistantTools(project: "group/api"))
        #expect(!settings.permitsConflictPush(project: "group/api"))
        #expect(!settings.permitsAutoMerge(project: "group/api"))

        settings.assistantToolProjects = "group/api"
        settings.conflictPushProjects = "group/api"
        settings.autoMergeProjects = "group/api"
        #expect(settings.permitsConflictPush(project: "group/api"))
        #expect(settings.permitsAutoMerge(project: "group/api"))
        #expect(!settings.permitsConflictPush(project: "group/api-v2"))
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
                #expect(!handoff.prompt.contains("For human or uncertain feedback, leave drafts private"))
            } else {
                #expect(handoff.prompt.contains("For human or uncertain feedback, leave drafts private"))
                #expect(handoff.prompt.contains("ask for approval"))
            }
        }
    }

}
