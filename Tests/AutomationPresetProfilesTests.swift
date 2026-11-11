import Foundation
import Testing
@testable import GitLabTodos

struct AutomationPresetProfilesTests {
    @Test func fourPublicChoicesKeepTheLegacyProfileOutOfThePicker() {
        #expect(AutomationPreset.allCases == [.manual, .safe, .trusted, .full])
        #expect(AutomationPreset.onboardingDefault(for: .undecided) == .full)
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full])
    func applyingAProfileSetsItsExactAutomationBoundary(_ preset: AutomationPreset) throws {
        var settings = AutomationSettings()
        settings.applyPreset(preset, for: .codex)
        let automatic = preset != .manual
        let publicActions = preset == .trusted || preset == .full
        #expect(settings.hasAutomaticActionConsent == automatic)
        #expect(settings.hasAutomaticPublicActionConsent == publicActions)
        #expect(settings.reviewRequested.isEnabled == automatic && settings.authorFeedback.isEnabled == automatic)
        #expect(settings.autoVerifyReReview == automatic)
        #expect(settings.autoApproveEnabled == publicActions && settings.autoReReviewEnabled == publicActions)
        #expect(settings.autoResolveOwnReviewThreads == publicActions && settings.autoResolveAcceptedFeedback == publicActions)
        #expect(settings.allowFollowUpPush == publicActions && settings.allowConflictPush == publicActions)
        #expect(settings.autoMergeEnabled == (preset == .full))
        #expect(settings.publicationMode == preset.defaultPublicationMode)
        #expect(settings.matchingPreset == preset)
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded == settings && loaded.matchingPreset == preset)
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full])
    func choosingAProfilePreservesModelsScopeCustomInstructionsAndRepositoryRestrictions(_ preset: AutomationPreset) {
        var settings = AutomationSettings()
        settings.codexReviewModel = .terra
        settings.codexVerificationModel = .astra
        settings.codexReviewThinking = .max
        settings.verificationThinking = .low
        settings.claudeVerificationModel = .sonnet
        settings.assistantWorkspace = "/custom/workspace"
        settings.scope.mode = .selected
        settings.reviewRequested.promptTemplate = "Custom review"
        settings.authorFeedback.promptTemplate = "Custom feedback"
        settings.reviewRequested.projects = "group/review"
        settings.authorFeedback.projects = "group/feedback"
        settings.workflowRules[.pipelineFailure].projects = "group/pipeline"
        settings.workflowRules[.pipelineFailure].targetBranches = "release"
        settings.assistantToolProjects = "group/tools"
        settings.conflictPushProjects = "group/conflicts"
        settings.autoMergeProjects = "group/merge"
        settings.applyPreset(preset, for: .codex)
        #expect(settings.codexReviewModel == .terra && settings.codexVerificationModel == .astra)
        #expect(settings.codexReviewThinking == .max && settings.verificationThinking == .low)
        #expect(settings.claudeVerificationModel == .sonnet && settings.assistantWorkspace == "/custom/workspace")
        #expect(settings.scope.mode == .selected)
        #expect(settings.reviewRequested.promptTemplate == "Custom review" && settings.authorFeedback.promptTemplate == "Custom feedback")
        #expect(settings.reviewRequested.projects == "group/review" && settings.authorFeedback.projects == "group/feedback")
        #expect(settings.workflowRules[.pipelineFailure].projects == "group/pipeline" && settings.workflowRules[.pipelineFailure].targetBranches == "release")
        #expect(settings.assistantToolProjects == "group/tools" && settings.conflictPushProjects == "group/conflicts")
        #expect(settings.autoMergeProjects == "group/merge")
    }

    @Test func oldCheckpointSettingsKeepTheirSavedRightsAndAreNotPresentedAsTrusted() throws {
        var legacy = AutomationSettings()
        legacy.applyPreset(.checkpoints, for: .codex)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "allowAutomaticPublicActions")
        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(loaded.baselinePreset == .checkpoints && loaded.matchingPreset == nil)
        #expect(!loaded.allowFollowUpPush && !loaded.allowConflictPush && !loaded.autoApproveEnabled && !loaded.autoMergeEnabled)
        #expect(!loaded.autoResolveOwnReviewThreads && !loaded.autoResolveAcceptedFeedback)
        #expect(loaded.publicationMode == .aiReplies && loaded.hasAutomaticActionConsent)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        encoded.removeValue(forKey: "allowAutomaticPublicActions")
        #expect(NSDictionary(dictionary: encoded) == NSDictionary(dictionary: json))
    }

    @Test func changingPermissionsMarksAChosenProfileCustomizedWithoutReapplyingIt() {
        var settings = AutomationSettings()
        settings.applyPreset(.trusted, for: .codex)
        settings.allowFollowUpPush = false
        #expect(settings.baselinePreset == .trusted && settings.matchingPreset == nil)
        #expect(!settings.allowFollowUpPush && settings.autoApproveEnabled)
    }

    @Test func dormantFiltersAndCustomModelsDoNotMislabelTheEffectiveProfile() {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        settings.codexReviewModel = .terra
        settings.publicationRestrictions.requireAI = false
        settings.publicationRestrictions.repositories = [.init(host: "gitlab.example.test", entityID: 9, label: "Scoped")]
        #expect(settings.matchingPreset == .full)
        settings.applyPreset(.safe, for: .codex)
        settings.autoApproveEnabled = true
        settings.allowFollowUpPush = true
        #expect(settings.matchingPreset == .safe && !settings.hasAutomaticPublicActionConsent)
    }

    @MainActor @Test func revokingPublicActionsUpdatesPushRecordsBeforeCancellingEveryActiveWorker() throws {
        let suite = "RevokePublicActions.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        settings.onboardingCompleted = false
        let host = "revoke-\(UUID().uuidString.lowercased()).example.test"
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if request.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#) }
            return InMemoryGitLab.output("[]")
        }
        let glab = gitlab.service(host: host, username: "me")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.save()
        var cancelled: Set<UUID> = []
        let monitor = TodoMonitorService(settings: settings, glab: glab, cancelPolicyJob: { id, current in
            cancelled.insert(id)
            if let job = current.assistantHandoffs.first(where: { $0.id == id }), job.followUpPushAllowed != nil {
                let url = FollowUpVerificationStore.recordURL(kind: "follow-up-runs", work: job.key.work,
                    username: job.key.username, in: FollowUpVerificationStore.directory)
                let record = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                #expect(record?["pushAllowed"] as? Bool == false)
            }
        })
        defer { monitor.stopTimer() }
        settings.assistantHandoffs = (1...3).map { iid in
            .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: iid),
                username: "me", workspace: "", access: .preparation), title: "Active fixture", prompt: "", createdAt: Date(),
                allowsPush: false, followUpPushAllowed: iid == 2 ? nil : true, execution: .init(state: .running),
                resolvesOwnThreads: iid == 2, manual: iid == 3)
        }
        defer {
            for job in settings.assistantHandoffs {
                try? FileManager.default.removeItem(at: FollowUpVerificationStore.recordURL(kind: "follow-up-runs",
                    work: job.key.work, username: job.key.username, in: FollowUpVerificationStore.directory))
            }
        }
        settings.save()
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        #expect(cancelled.isEmpty)
        settings.automation.allowAutomaticPublicActions = false
        settings.save()
        #expect(cancelled == Set(settings.assistantHandoffs.map(\.id)))
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full], [AutomationPublicationMode.all, .aiReplies, .filtered])
    func publicationResetUsesTheExactChosenProfileAndRetainsDormantFilters(_ preset: AutomationPreset, _ before: AutomationPublicationMode) {
        var settings = AutomationSettings()
        settings.publicationMode = before
        settings.publicationRestrictions = .init(repositories: [.init(host: "gitlab.example.test", entityID: 1, label: "Repository")], requireAI: true)
        let filters = settings.publicationRestrictions
        settings.resetPublication(to: preset)
        #expect(settings.publicationMode == preset.defaultPublicationMode)
        #expect(settings.publicationRestrictions == filters)
        #expect(settings.packageDecision == .undecided)
    }

    @Test func legacyCheckpointPublicationResetKeepsItsOriginalConditionalMeaning() {
        var settings = AutomationSettings()
        settings.publicationMode = .manual
        settings.resetPublication(to: .checkpoints)
        #expect(settings.publicationMode == .manual)
        settings.publicationRestrictions.repositories = [.init(host: "gitlab.example.test", entityID: 1, label: "Repository")]
        settings.publicationMode = .filtered
        settings.resetPublication(to: .checkpoints)
        #expect(settings.publicationMode == .filtered)
    }
}
