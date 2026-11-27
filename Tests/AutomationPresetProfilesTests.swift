import Foundation
import SwiftUI
import Testing
@testable import MergeTether

struct AutomationPresetProfilesTests {
    @MainActor @Test(arguments: AutomationPreset.allCases + [.manual, .checkpoints])
    func presetSummaryListsKeyActionDefaultsFirst(_ preset: AutomationPreset) {
        let expected: [AutomationPresetDescription.KeyActionDefault] = switch preset {
        case .manual, .safe: [.merge(false), .approve(false), .publish(.manual, allowsBotReplies: false)]
        case .trusted: [.merge(false), .approve(true), .publish(.aiReplies, allowsBotReplies: true)]
        case .full: [.merge(true), .approve(true), .publish(.all, allowsBotReplies: true)]
        case .checkpoints: [.merge(false), .approve(false), .publish(.aiReplies, allowsBotReplies: false)]
        }

        #expect(AutomationPresetDescription(preset: preset).keyActionDefaults == expected)
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full], [false, true])
    func missingNewPermissionUsesTheActiveProfileAfterRestart(_ preset: AutomationPreset, _ legacy: Bool) throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(preset, for: .codex)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        if legacy { json.removeValue(forKey: "selectedPreset") }
        var restrictions = try #require(json["publicationRestrictions"] as? [String: Any])
        restrictions.removeValue(forKey: "allowBotReplies")
        json["publicationRestrictions"] = restrictions
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: json))
        let persisted = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        let restored = try #require(persisted["publicationRestrictions"] as? [String: Any])
        #expect(restored["allowBotReplies"] as? Bool == (preset == .trusted || preset == .full))
        #expect(loaded.matchingPreset == preset)
    }

    @Test func addingAPresetDefaultCannotTurnLegacyAllPublicationIntoAFilter() throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.publicationRestrictions = .init()
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        fields.removeValue(forKey: "publicationPolicyMode")
        fields.removeValue(forKey: "selectedPreset")
        var restrictions = try #require(fields["publicationRestrictions"] as? [String: Any])
        restrictions.removeValue(forKey: "allowBotReplies")
        fields["publicationRestrictions"] = restrictions
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(loaded.publicationMode == .all && loaded.matchingPreset == .full)
        #expect(loaded.publicationRestrictions.allowBotReplies)
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full], [false, true])
    func foreignThreadPublicationMigratesFromTheActivePreset(_ preset: AutomationPreset, legacy: Bool) throws {
        var settings = AutomationSettings()
        settings.applyPreset(preset, for: .codex)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "publishOtherReviewThreadReplies")
        if legacy { json.removeValue(forKey: "selectedPreset") }

        let migrated = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: json))
        let restarted = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(migrated))
        #expect(restarted.publishOtherReviewThreadReplies == (preset == .full))
        #expect(restarted.matchingPreset == preset)
    }

    @Test func customForeignThreadPermissionSurvivesRestartAndProfileSwitching() throws {
        var settings = AutomationSettings()
        settings.applyPreset(.full, for: .codex)
        settings.publishOtherReviewThreadReplies = false
        let saved = try JSONEncoder().encode(settings)
        let restarted = try JSONDecoder().decode(AutomationSettings.self, from: saved)
        #expect(!restarted.publishOtherReviewThreadReplies && restarted.matchingPreset == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        legacy.removeValue(forKey: "publishOtherReviewThreadReplies")
        let migrated = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!migrated.publishOtherReviewThreadReplies && migrated.matchingPreset == nil)

        settings.applyPreset(.trusted, for: .codex)
        settings.publishOtherReviewThreadReplies = true
        let snapshot = try #require(AutomationProfileSnapshot.custom(from: settings))
        let restored = try JSONDecoder().decode(AutomationProfileSnapshot.self, from: JSONEncoder().encode(snapshot))
        settings.applyPreset(.safe, for: .codex)
        restored.apply(to: &settings)
        #expect(settings.publishOtherReviewThreadReplies && settings.publicationMode == .aiReplies && settings.matchingPreset == nil)
    }

    @Test(arguments: [false, true])
    func customizedProfilesDoNotGainNewPublicationPermissionOnUpgrade(_ legacy: Bool) throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(.trusted, for: .codex)
        configuration.allowFollowUpPush = false
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        if legacy { json.removeValue(forKey: "selectedPreset") }
        var restrictions = try #require(json["publicationRestrictions"] as? [String: Any])
        restrictions.removeValue(forKey: "allowBotReplies")
        json["publicationRestrictions"] = restrictions
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONSerialization.data(withJSONObject: json))
        let persisted = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        let restored = try #require(persisted["publicationRestrictions"] as? [String: Any])
        #expect(restored["allowBotReplies"] as? Bool == false)
        #expect(loaded.matchingPreset == nil && !loaded.allowFollowUpPush)
    }

    @MainActor @Test func choosingASettingsProfileFillsOnlyTheDraftAndReadingMatchingStateNeverReappliesIt() throws {
        let suite = "DraftProfileSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = SettingsManager(defaults: defaults)
        live.automation.applyPreset(.safe, for: .codex)
        live.automation.codexReviewModel = .terra
        live.automation.authorFeedback.promptTemplate = "Keep custom instructions"
        live.automation.scope.mode = .selected
        live.save()
        let saved = live.automation
        let persisted = defaults.data(forKey: "automation")
        var draft = saved
        var custom: AutomationProfileSnapshot?
        var draftWrites = 0
        let selection = AutomationSettingsProfilePicker.selection(for: Binding(get: { draft }, set: {
            draft = $0
            draftWrites += 1
        }), lastCustom: Binding(get: { custom }, set: { custom = $0 }))
        selection.wrappedValue = .preset(.trusted)
        #expect(draft.autoApproveEnabled && draft.allowFollowUpPush && !draft.autoMergeEnabled)
        #expect(draft.publicationMode == .aiReplies && selection.wrappedValue == .preset(.trusted))
        #expect(draftWrites == 1 && live.automation == saved && defaults.data(forKey: "automation") == persisted)
        draft.autoMergeEnabled = true
        #expect(selection.wrappedValue == .custom)
        draft.publicationMode = .all
        #expect(selection.wrappedValue == .custom)
        draft.autoMergeWithOtherAssignees = true
        draft.autoMergeAuthorOnly = false
        draft.requiresAssignmentClaim = false
        draft.publishOtherReviewThreadReplies = true
        #expect(selection.wrappedValue == .preset(.full) && draft.baselinePreset == .trusted)
        for _ in 0..<5 { _ = selection.wrappedValue }
        #expect(draftWrites == 1)
        selection.wrappedValue = nil
        #expect(draftWrites == 1)
        #expect(draft.codexReviewModel == .terra && draft.authorFeedback.promptTemplate == "Keep custom instructions")
        #expect(draft.scope.mode == .selected && live.automation == saved)
        #expect(defaults.data(forKey: "automation") == persisted)
    }
    @Test(arguments: [AutomationPreset.manual, .safe, .trusted, .full])
    func profileMatchingUsesEffectiveSettingsWithoutRewritingTheBaseline(_ preset: AutomationPreset) throws {
        var settings = AutomationSettings()
        settings.applyPreset(preset, for: .codex)
        for baseline in [AutomationPreset.checkpoints, .full] {
            settings.baselinePreset = baseline
            let before = settings
            #expect(settings.matchingPreset == preset)
            #expect(settings == before && settings.baselinePreset == baseline)
        }
        settings.baselinePreset = nil
        #expect(settings.matchingPreset == preset && settings.baselinePreset == nil)
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.matchingPreset == preset && restored.baselinePreset == nil)
    }

    @Test func noConsentHasNoProfileAndCannotBeMistakenForManual() {
        var settings = AutomationSettings()
        #expect(settings.packageDecision == .undecided && settings.matchingPreset == nil)
        settings.baselinePreset = .manual
        #expect(settings.matchingPreset == nil)
        #expect(AutomationPreset(rawValue: "custom") == nil)
    }

    @MainActor @Test func freshSettingsAndPublicProfilesDoNotInventACustomOption() {
        var draft = AutomationSettings()
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let settings = AutomationSettingsProfilePicker(draft: binding, lastCustom: .constant(nil))
        #expect(!settings.hasCustomOption)
        for preset in AutomationPreset.allCases {
            draft.applyPreset(preset, for: .codex)
            #expect(!settings.hasCustomOption)
        }
        draft.applyPreset(.trusted, for: .codex)
        draft.allowFollowUpPush = false
        #expect(settings.hasCustomOption)
        draft.packageDecision = .disabled
        #expect(!settings.hasCustomOption)
    }

    @MainActor @Test func profilesCannotBeSelectedWhileAutomationIsOff() {
        var draft = AutomationSettings()
        draft.applyPreset(.manual, for: .codex)
        let before = draft
        let selection = AutomationSettingsProfilePicker.selection(
            for: Binding(get: { draft }, set: { draft = $0 }), lastCustom: .constant(nil))
        #expect(selection.wrappedValue == nil)
        selection.wrappedValue = .preset(.full)
        #expect(draft == before)
    }

    @MainActor @Test(arguments: [false, true])
    func enablingAutomationFromAnUnconfiguredOrManualSetupPreparesSafe(_ usedManualPreset: Bool) throws {
        let name = "EnableAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        if usedManualPreset { settings.automation.applyPreset(.manual, for: .codex) }
        settings.automation.scope.mode = .selected
        #expect(settings.save())
        let editor = SettingsPolicyEditor(settings: settings)

        #expect(!editor.automationEnabled)
        editor.automationEnabled = true

        #expect(editor.draft.matchingPreset == .safe)
        #expect(editor.draft.hasAutomaticActionConsent && !editor.draft.hasAutomaticPublicActionConsent)
        #expect(editor.draft.scope.mode == .selected)
        #expect(!settings.automation.hasAutomaticActionConsent)
    }

    @MainActor @Test func turningAutomationOffAndBackOnAfterRestartRestoresTheConfiguredRules() throws {
        let name = "RestoreAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.trusted, for: .codex)
        settings.automation.baselinePreset = .manual
        settings.automation.autoMergeEnabled = true
        settings.automation.authorFeedback.promptTemplate = ""
        #expect(settings.save())
        let editor = SettingsPolicyEditor(settings: settings)
        let configured = editor.draft
        #expect(editor.hasIncompleteRule && configured.matchingPreset == nil)

        editor.automationEnabled = false
        #expect(!editor.hasIncompleteRule)
        #expect(!editor.draft.hasAutomaticActionConsent)
        #expect(!editor.draft.hasAutomaticPublicActionConsent)
        settings.automation = editor.draft
        #expect(settings.save())

        let reopened = SettingsPolicyEditor(settings: SettingsManager(defaults: defaults))
        #expect(!reopened.automationEnabled)
        reopened.automationEnabled = true
        #expect(reopened.draft == configured)
    }

    @MainActor @Test func customSummaryDoesNotDescribeDormantPublicFlagsAsAutomaticPermissions() {
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.allowAutomaticPublicActions = false
        #expect(AutomationCustomProfileDescription(configuration: configuration).publicSummary == nil)
        configuration.allowAutomaticPublicActions = true
        configuration.packageDecision = .disabled
        #expect(AutomationCustomProfileDescription(configuration: configuration).publicSummary == nil)
        configuration.packageDecision = .enabled
        #expect(AutomationCustomProfileDescription(configuration: configuration).publicSummary != nil)
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func customConflictPushSummaryRequiresBothPreparationAndToolPermission(_ preparation: Bool, _ tools: Bool) throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.conflictTasksEnabled = preparation
        configuration.allowAssistantTools = tools
        let summary = try #require(AutomationCustomProfileDescription(configuration: configuration).publicSummary)
        let automatic = String(localized: .AutomationProfiles.automatic)
        let conflict = String(localized: preparation && tools ? .AutomationProfiles.automatic : .AutomationProfiles.manualAction)
        let expected = String(localized: .AutomationProfiles.customPublicSummary(automatic, automatic, conflict, automatic))
        #expect(String(localized: summary) == expected)
    }
    @Test func onlyAutomaticPresetsAreSelectable() {
        #expect(AutomationPreset.allCases == [.safe, .trusted, .full])
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
        json.removeValue(forKey: "selectedPreset")
        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(loaded.baselinePreset == .checkpoints && loaded.matchingPreset == nil)
        #expect(!loaded.allowFollowUpPush && !loaded.allowConflictPush && !loaded.autoApproveEnabled && !loaded.autoMergeEnabled)
        #expect(!loaded.autoResolveOwnReviewThreads && !loaded.autoResolveAcceptedFeedback)
        #expect(loaded.publicationMode == .aiReplies && loaded.hasAutomaticActionConsent)
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        encoded.removeValue(forKey: "allowAutomaticPublicActions")
        encoded.removeValue(forKey: "selectedPreset")
        #expect(NSDictionary(dictionary: encoded) == NSDictionary(dictionary: json))
    }

    @MainActor @Test func approvalThresholdSurvivesRestartAndPresetChanges() throws {
        let suite = "ApprovalThreshold.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8)).autoApprovalThreshold == .noMajorIssues)
        let settings = SettingsManager(defaults: defaults)
        settings.automation.autoApprovalThreshold = .noCodeIssues
        settings.automation.applyPreset(.full, for: .codex)
        #expect(settings.automation.matchingPreset == .full)
        #expect(settings.save())
        let restarted = SettingsManager(defaults: defaults)
        #expect(restarted.automation.autoApprovalThreshold == .noCodeIssues)
        restarted.automation.applyPreset(.manual, for: .codex)
        restarted.automation.applyPreset(.trusted, for: .codex)
        #expect(restarted.automation.autoApprovalThreshold == .noCodeIssues)
        #expect(restarted.automation.matchingPreset == .trusted)
    }

    @Test func automaticApprovalDefaultsAreSafeAndUpgradesPreserveExplicitValues() throws {
        // Fresh settings and legacy blobs without the key never approve on their own.
        #expect(!AutomationSettings().autoApproveEnabled && AutomationSettings().autoApprovalThreshold == .noMajorIssues)
        var recommended = AutomationSettings()
        recommended.applyRecommended(for: .codex)
        #expect(!recommended.autoApproveEnabled)
        func load(_ json: String) throws -> AutomationSettings {
            try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        }
        #expect(try !load("{}").autoApproveEnabled)
        #expect(try !load(#"{"packageDecision":"enabled"}"#).autoApproveEnabled)
        #expect(try !load(#"{"packageDecision":"enabled","selectedPreset":"safe"}"#).autoApproveEnabled)
        // A missing permission inherits only an explicitly stored delivering profile.
        #expect(try load(#"{"packageDecision":"enabled","selectedPreset":"trusted"}"#).autoApproveEnabled)
        #expect(try load(#"{"packageDecision":"enabled","selectedPreset":"full"}"#).autoApproveEnabled)
        #expect(try !load(#"{"packageDecision":"disabled","selectedPreset":"trusted"}"#).autoApproveEnabled)
        // Explicit values, including the former permissive defaults, are preserved.
        let explicit = try load(#"{"packageDecision":"enabled","autoApproveEnabled":true,"autoApprovalThreshold":"noMajorIssues"}"#)
        #expect(explicit.autoApproveEnabled && explicit.autoApprovalThreshold == .noMajorIssues)
        #expect(try !load(#"{"packageDecision":"enabled","selectedPreset":"trusted","autoApproveEnabled":false}"#).autoApproveEnabled)
        let roundTrip = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(explicit))
        #expect(roundTrip.autoApproveEnabled && roundTrip.autoApprovalThreshold == .noMajorIssues)
        // Delivering profiles still grant the permission explicitly.
        var trusted = AutomationSettings()
        trusted.applyPreset(.trusted, for: .codex)
        #expect(trusted.autoApproveEnabled && trusted.matchingPreset == .trusted)
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
            // "Automatic work stays private" revokes automatic pushes; a job the user started keeps its permission.
            if let job = current.assistantHandoffs.first(where: { $0.id == id }), job.followUpPushAllowed != nil, job.manual != true {
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
        settings.automation.requireReviewStartConfirmation = true
        settings.save()
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
