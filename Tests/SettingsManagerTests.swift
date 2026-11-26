import Foundation
import Testing
@testable import MergeTether

@MainActor
@Suite("SettingsManager")
struct SettingsManagerTests {
    @Test func codingAgentCanRemainUnselectedAcrossRestart() throws {
        let suite = "CodingAgentSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.automation.selectedAssistant == nil)
        settings.automation.applyPreset(.safe, for: .claude)
        #expect(settings.save())
        #expect(SettingsManager(defaults: defaults).automation.selectedAssistant == .claude)
        settings.automation.selectedAssistant = nil
        #expect(settings.save())
        let restored = SettingsManager(defaults: defaults).automation
        #expect(restored.selectedAssistant == nil)
        #expect(restored.packageDecision == .enabled)
        #expect(restored.reviewRequested.isEnabled)
    }

    @Test(arguments: [AutomationAssistant.claude, nil])
    func codingAgentChangesAreAppliedWithTheSettingsDraft(_ assistant: AutomationAssistant?) throws {
        let suite = "CodingAgentDraft.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.selectedAssistant = .codex
        try #require(settings.save())
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let monitor = TodoMonitorService(settings: settings, glab: gitlab.service(host: "example.test", username: "alice"),
            assistantDependencies: AssistantDependencyMonitor(probe: { _ in .missingCLI }))
        let editor = SettingsPolicyEditor(settings: settings)
        let navigation = SettingsNavigation()
        var resumes = 0
        navigation.showCodingAgent(onConfigured: {
            #expect(SettingsManager(defaults: defaults).automation.selectedAssistant == assistant)
            resumes += 1
        })

        editor.selectedAssistant = assistant
        settings.automation.scope.mode = .selected
        try #require(settings.save())
        editor.updateScope(from: settings)
        editor.updateAssistant(from: settings)
        #expect(editor.draft.selectedAssistant == assistant)
        #expect(settings.automation.selectedAssistant == .codex)
        #expect(SettingsManager(defaults: defaults).automation.selectedAssistant == .codex)
        #expect(editor.saveState.canApply(draft: editor.draft, custom: nil, savedCustom: nil))
        #expect(editor.assistantRequiringSetup(comparedTo: settings.acceptedAutomation) == assistant)
        #expect(resumes == 0)

        editor.revert(settings: settings)
        #expect(editor.draft.selectedAssistant == .codex)

        editor.selectedAssistant = assistant
        editor.draft.claudeCodingThinking = .low
        editor.apply(monitor: monitor, navigation: navigation)

        #expect(settings.automation.selectedAssistant == assistant)
        #expect(editor.saveState.accepted.selectedAssistant == assistant)
        #expect(resumes == (assistant == nil ? 0 : 1))
        let restarted = SettingsManager(defaults: defaults).automation
        #expect(restarted.selectedAssistant == assistant)
        #expect(restarted.claudeCodingThinking == .low)
        #expect(restarted.scope.mode == .selected)
    }

    @Test func returningToNoCodingAgentClearsThePendingProviderChange() {
        let settings = SettingsManager(defaults: makeDefaults())
        let editor = SettingsPolicyEditor(settings: settings)
        editor.selectedAssistant = .claude
        editor.selectedAssistant = nil

        #expect(!editor.saveState.canApply(draft: editor.draft, custom: nil, savedCustom: nil))
    }

    @Test func decodingLegacyAutomationKeepsItsConfiguredProvider() throws {
        let legacy = Data(#"{"assistant":"claude","packageDecision":"enabled"}"#.utf8)
        let restored = try JSONDecoder().decode(AutomationSettings.self, from: legacy)
        #expect(restored.selectedAssistant == .claude)
    }

    @Test func existingInstallationsDefaultToManualBoardOrderWithAttentionPromotion() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.save()

        #expect(defaults.string(forKey: "boardOrderingMethod") == "manual")
        #expect(defaults.bool(forKey: "promoteBoardAttention"))
    }

    @Test(arguments: [false, true])
    func assignedMergeRequestsDefaultToMineAndPreserveExistingPreference(_ existingInstallation: Bool) throws {
        let suite = "AssignedMergeRequestOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if existingInstallation { defaults.set(true, forKey: "onboardingCompleted") }

        #expect(SettingsManager(defaults: defaults).save())
        #expect(defaults.bool(forKey: "treatSoleAssigneeAsOwn"))

        defaults.set(false, forKey: "treatSoleAssigneeAsOwn")
        let restarted = SettingsManager(defaults: defaults)
        #expect(!restarted.treatAssignedMergeRequestsAsOwn)
        #expect(restarted.save())
        #expect(!defaults.bool(forKey: "treatSoleAssigneeAsOwn"))
    }

    @Test func issueDiscoveryDefaultsToOnAndPreservesChangesAcrossRestart() throws {
        let suite = "IssueDiscovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SettingsManager(defaults: defaults)
        #expect(fresh.findMergeRequestIssues)

        defaults.set(false, forKey: "notificationsEnabled")
        let upgraded = SettingsManager(defaults: defaults)
        #expect(upgraded.findMergeRequestIssues)
        upgraded.findMergeRequestIssues = false
        #expect(upgraded.save())
        let restarted = SettingsManager(defaults: defaults)
        #expect(!restarted.findMergeRequestIssues)

        restarted.findMergeRequestIssues = true
        #expect(restarted.save())
        #expect(SettingsManager(defaults: defaults).findMergeRequestIssues)
    }

    @Test(arguments: ["automation", "mergeSubmissions", "automationReceipts", "automationAttemptReceipts",
        "authorFeedbackAttempts", "feedbackSuggestionDecisions", "pipelineRefreshAttempts",
        "pipelineClaimAssessmentAttempts", "pendingTodoAcknowledgements", "assistantHandoffs",
        "workflowActivity", "automationEvents", "mrActionIntents", "routedMRTodoReceipts", "boardPins", "boardManualOrder",
        "mrLifecycleLedger", "conflictReceipts", "reReviewReceipts", "reReviewDraftBaselines",
        "pendingCommentReviews", "commentReviewProgress", "ignoredMergeRequests", "autoApproveOptOuts",
        "autoPublishOptOuts", "autoMergeOptOuts", "lastSeenTodoIDs"])
    func corruptRecordsSurviveUnrelatedSavesAndRestart(_ key: String) {
        // given
        let defaults = makeDefaults()
        let corrupt = Data("{unreadable historical record".utf8)
        defaults.set(corrupt, forKey: key)
        let settings = SettingsManager(defaults: defaults)
        let convenience = ["automationEvents", "boardPins", "boardManualOrder", "lastSeenTodoIDs"].contains(key)
        #expect(settings.automaticActionsAllowed == convenience)
        #expect(settings.persistenceDegraded.contains(key) == !convenience)
        #expect(defaults.object(forKey: key + ".corrupt") == nil)

        // when
        settings.notificationsEnabled = false
        settings.save()
        SettingsManager(defaults: defaults).save()

        // then
        #expect(defaults.data(forKey: key) == corrupt)
        #expect(defaults.data(forKey: key + ".corrupt") == corrupt)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(key + ".corrupt") }.count == 1)
        #expect(SettingsManager(defaults: defaults).automaticActionsAllowed == convenience)
        #expect(!SettingsManager(defaults: defaults).notificationsEnabled)
    }

    @Test func corruptReceiptDoesNotResetSavedProfileOrPermissions() throws {
        // given
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.checkpoints, for: .claude)
        settings.automation.allowFollowUpPush = false
        settings.automation.autoResolveAcceptedFeedback = false
        settings.save()
        let expected = settings.automation
        defaults.set(Data("unsupported journal".utf8), forKey: "mergeSubmissions")

        // when
        let restored = SettingsManager(defaults: defaults)
        restored.notificationsEnabled.toggle()
        restored.save()

        // then
        #expect(!restored.automaticActionsAllowed)
        #expect(restored.automation == expected)
        #expect(SettingsManager(defaults: defaults).automation == expected)
    }

    @Test func restoresCLIJobHistoryWithoutDesktopHandoffs() throws {
        let defaults = makeDefaults()
        let key = AssistantAutomationRunner.JobKey(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2),
            username: "me", workspace: "", access: .gitLabRead)
        let desktop = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false)
        let cli = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .succeeded))
        defaults.set(try JSONEncoder().encode([desktop, cli]), forKey: "assistantHandoffs")

        let restored = SettingsManager(defaults: defaults)

        #expect(restored.assistantHandoffs.map(\.id) == [cli.id])
        #expect(restored.automaticActionsAllowed)
    }

    @Test func wrongStorageTypeIsPreservedRatherThanTreatedAsAMissingProfile() {
        let defaults = makeDefaults()
        defaults.set("unsupported profile", forKey: "automation")
        let settings = SettingsManager(defaults: defaults)
        settings.save()
        #expect(defaults.string(forKey: "automation") == "unsupported profile")
        #expect(defaults.string(forKey: "automation.corrupt") == "unsupported profile")
        #expect(settings.persistenceDegraded == ["automation"])
    }

    @Test(arguments: [AutomationPackageDecision.undecided, .disabled])
    func manualSubmissionJournalRemainsAvailableWithoutAutomaticConsent(_ decision: AutomationPackageDecision) throws {
        // given
        let suite = "ManualSubmissionConsent.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = decision
        let receipt = try mergeReceipt(settings)

        // when
        let saved = settings.saveMergeSubmission(receipt)

        // then
        #expect(saved && settings.automaticActionsAllowed && !settings.automaticWritesAllowed)
        #expect(SettingsManager(defaults: defaults).mergeSubmissions == [receipt])
    }

    @Test(arguments: ["encode", "write", "synchronize"])
    func failedMergeReceiptPersistenceCannotAuthorizeASubmissionOrClearOnRestart(_ failure: String) throws {
        // given
        let suite = "SettingsPersistenceFailure.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let original = try mergeReceipt(settings)
        #expect(settings.saveMergeSubmission(original))
        let saved = defaults.data(forKey: "mergeSubmissions")
        defaults.rejectedKey = failure == "write" ? "mergeSubmissions" : nil
        defaults.synchronizationFails = failure == "synchronize"
        let next = try mergeReceipt(settings,
            date: failure == "encode" ? Date(timeIntervalSinceReferenceDate: .nan) : Date(timeIntervalSince1970: 20))

        // when
        let authorized = settings.saveMergeSubmission(next)
        if failure != "synchronize" { #expect(defaults.data(forKey: "mergeSubmissions") == saved) }
        defaults.rejectedKey = nil
        defaults.synchronizationFails = false
        settings.save()
        let restarted = SettingsManager(defaults: defaults)

        // then
        #expect(!authorized && !settings.automaticActionsAllowed && !restarted.automaticActionsAllowed)
        #expect(!restarted.saveMergeSubmission(original))
        if failure == "encode" || failure == "write" {
            // A failed attempt cannot erase the last known receipt.
            #expect(saved != nil)
            #expect(settings.persistenceDegraded.contains("mergeSubmissions"))
        } else {
            #expect(settings.persistenceDegraded.contains("settingsPersistence"))
        }
    }

    @Test(arguments: ["origin", "missingOrigin", "configuration", "extraCorruptRow"])
    func unsupportedMergeReceiptSnapshotsStayRawAndCannotAuthorizeManualEnqueue(_ field: String) throws {
        // given
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        let receipt = try mergeReceipt(settings)
        #expect(settings.saveMergeSubmission(receipt))
        let encoded = try JSONEncoder().encode([receipt])
        let object = try JSONSerialization.jsonObject(with: encoded)
        var rows = try #require(object as? [[String: Any]])
        switch field {
        case "origin": rows[0]["origin"] = "unknown-origin"
        case "missingOrigin": rows[0].removeValue(forKey: "origin")
        case "configuration": rows[0]["configuration"] = ["automation": "unsupported snapshot"]
        default: rows.append(["origin": "unknown-origin"])
        }
        let raw = try JSONSerialization.data(withJSONObject: rows)
        defaults.set(raw, forKey: "mergeSubmissions")

        // when
        let restored = SettingsManager(defaults: defaults)
        let authorized = restored.saveMergeSubmission(receipt)
        restored.save()

        // then
        #expect(!authorized && !restored.automaticActionsAllowed)
        #expect(defaults.data(forKey: "mergeSubmissions") == raw)
        #expect(defaults.data(forKey: "mergeSubmissions.corrupt") == raw)
    }

    @Test func validTypedMergeReceiptsKeepObservedQueueOriginAndExplicitPolicy() throws {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.checkpoints, for: .claude)
        settings.automation.allowFollowUpPush = false
        let receipt = try mergeReceipt(settings)
        #expect(settings.saveMergeSubmission(receipt))
        let restored = SettingsManager(defaults: defaults)
        #expect(restored.mergeSubmissions == [receipt])
        #expect(restored.automation == settings.automation)
        #expect(restored.automaticActionsAllowed)
    }

    private func mergeReceipt(_ settings: SettingsManager, date: Date = Date(timeIntervalSince1970: 10)) throws -> MergeSubmissionReceipt {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
            {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Fixture",
             "web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,
             "sha":"0123456789012345678901234567890123456789","source_project_id":1,"target_project_id":1,
             "source_branch":"feature","target_branch":"main","labels":[]}
            """.utf8))
        return .init(origin: .observedQueue,
            target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2), userID: 3,
            context: .init(request), semanticFingerprint: request.semanticContextFingerprint,
            discussionFingerprint: "checked", configuration: .init(settings), action: .enqueue, createdAt: date)
    }

    @Test(arguments: [AssistantContextLauncher.Destination.claudeDesktop, .t3Code])
    func manualConversationDestinationPersistsOnlyOnSaveAndIgnoresAutomationChoice(
        _ destination: AssistantContextLauncher.Destination
    ) {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.conversationDestination == .codexApp)
        settings.conversationDestination = destination
        #expect(SettingsManager(defaults: defaults).conversationDestination == .codexApp)
        settings.automation.assistant = .codex
        settings.save()
        #expect(SettingsManager(defaults: defaults).conversationDestination == destination)
        defaults.set("unknown-future-app", forKey: "conversationDestination")
        #expect(SettingsManager(defaults: defaults).conversationDestination == .codexApp)
    }

    @Test func unrelatedSavesDoNotRewriteLoadedAssistantHistory() throws {
        let suite = "SettingsHistoryWrites.\(UUID())"
        let defaults = try #require(HistoryWriteDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 1, iid: 2),
                username: "me", workspace: "", access: .gitLabRead),
            title: "Fixture", prompt: String(repeating: "Synthetic transcript ", count: 10_000),
            createdAt: Date(timeIntervalSince1970: 1), allowsPush: false,
            execution: .init(state: .queued))
        settings.assistantHandoffs = [handoff]
        #expect(settings.save())
        let history = try #require(defaults.data(forKey: "assistantHandoffs"))
        defaults.historyWrites = 0

        settings.notificationsEnabled.toggle()
        #expect(settings.save())
        let restarted = SettingsManager(defaults: defaults)
        #expect(restarted.save())

        #expect(defaults.historyWrites == 0)
        #expect(defaults.data(forKey: "assistantHandoffs") == history)
        #expect(restarted.assistantHandoffs.first?.prompt == handoff.prompt)
        restarted.assistantHandoffs[0].execution?.state = .running
        #expect(restarted.save())
        #expect(defaults.historyWrites == 1)
        #expect(SettingsManager(defaults: defaults).assistantHandoffs.first?.execution?.state == .running)
    }

    @Test func failedHistoryWriteIsRetriedAndNeverClearsThePersistenceHold() throws {
        let suite = "SettingsHistoryFailure.\(UUID())"
        let defaults = try #require(PersistenceFaultDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.save())
        defaults.rejectedKey = "assistantHandoffs"
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 1, iid: 2),
                username: "me", workspace: "", access: .gitLabRead),
            title: "Fixture", prompt: "Synthetic prompt", createdAt: Date(timeIntervalSince1970: 1), allowsPush: false,
            execution: .init(state: .succeeded))
        settings.assistantHandoffs.append(handoff)
        settings.save()
        #expect(settings.persistenceDegraded.contains("assistantHandoffs"))
        #expect(SettingsManager(defaults: defaults).assistantHandoffs.isEmpty)
        defaults.rejectedKey = nil
        settings.save()
        let restarted = SettingsManager(defaults: defaults)
        #expect(restarted.assistantHandoffs.map(\.id) == [handoff.id])
        #expect(!restarted.automaticActionsAllowed)
    }

    @Test(arguments: ["workflowActivity", "automationEvents", "mrActionIntents"])
    func unrelatedSavesDoNotRewriteOtherHistoryCollections(_ key: String) throws {
        let suite = "SettingsOtherHistoryWrites.\(UUID())"
        let defaults = try #require(HistoryWriteDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.save())
        let original = try #require(defaults.data(forKey: key))
        defaults.writesByKey = [:]
        settings.notificationsEnabled.toggle()
        #expect(settings.save())
        #expect(SettingsManager(defaults: defaults).save())
        #expect(defaults.writesByKey[key] == nil)
        #expect(defaults.data(forKey: key) == original)
    }

    @Test func unexpectedHistoryReplacementIsPreservedAndFailsClosed() throws {
        let suite = "SettingsHistoryReplacement.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.save())
        let unsupported = Data("unsupported history".utf8)
        defaults.set(unsupported, forKey: "assistantHandoffs")
        settings.notificationsEnabled.toggle()
        settings.save()
        #expect(defaults.data(forKey: "assistantHandoffs") == unsupported)
        #expect(settings.persistenceDegraded.contains("assistantHandoffs"))
        #expect(!SettingsManager(defaults: defaults).automaticActionsAllowed)
    }

    @Test func failedSynchronizationRetriesChangedHistoryOnTheNextExplicitSave() throws {
        let suite = "SettingsHistorySynchronization.\(UUID())"
        let defaults = try #require(HistoryWriteDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.save())
        defaults.writesByKey = [:]
        let key = AssistantAutomationRunner.JobKey(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2),
            username: "me", workspace: "", access: .gitLabRead)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, execution: .init(state: .succeeded))
        settings.assistantHandoffs = [job]
        defaults.synchronizationFails = true
        #expect(!settings.save())
        #expect(defaults.writesByKey["assistantHandoffs"] == 1)
        defaults.synchronizationFails = false
        #expect(settings.save())
        #expect(defaults.writesByKey["assistantHandoffs"] == 2)
        let restarted = SettingsManager(defaults: defaults)
        #expect(restarted.assistantHandoffs.map(\.id) == [job.id])
        #expect(!restarted.automaticActionsAllowed)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MergeTetherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("registers sensible defaults on first init")
    func registersDefaults() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.refreshInterval == .fiveMinutes)
        #expect(settings.unreadReminderInterval == .fiveMinutes)
        #expect(settings.unreadReminderSound == .off)
        #expect(settings.notificationsEnabled == true)
        #expect(settings.onboardingCompleted == false)
        #expect(settings.launchAtLoginPreference == true)
        #expect(settings.lastSeenTodoIDs.isEmpty)
        #expect(settings.glabPath == nil)
        #expect(settings.resolvedHost == nil)
        #expect(settings.isFirstLaunch == true)
    }

    @Test func obsoleteCompletionPreferencesAreRemovedWithoutChangingAutomation() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "autoRemoveFinishedMRs")
        defaults.set(false, forKey: "showMergedMRCompletions")
        defaults.set(false, forKey: "showClosedMRCompletions")
        let settings = SettingsManager(defaults: defaults)
        let automation = settings.automation
        settings.save()
        #expect(defaults.object(forKey: "autoRemoveFinishedMRs") == nil)
        #expect(defaults.object(forKey: "showMergedMRCompletions") == nil)
        #expect(defaults.object(forKey: "showClosedMRCompletions") == nil)
        #expect(SettingsManager(defaults: defaults).automation == automation)
    }

    @Test("round-trips mutated state through save/reload")
    func roundTrip() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.refreshInterval = .fifteenMinutes
        settings.unreadReminderInterval = .thirtyMinutes
        settings.unreadReminderSound = .ping
        settings.notificationsEnabled = false
        settings.onboardingCompleted = true
        settings.launchAtLoginPreference = false
        settings.lastSeenTodoIDs = [1, 2, 3, 42]
        settings.resolvedHost = "gitlab.corp.example.com"
        settings.glabPath = URL(fileURLWithPath: "/opt/homebrew/bin/glab")
        settings.save()

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.refreshInterval == .fifteenMinutes)
        #expect(reloaded.unreadReminderInterval == .thirtyMinutes)
        #expect(reloaded.unreadReminderSound == .ping)
        #expect(reloaded.notificationsEnabled == false)
        #expect(reloaded.onboardingCompleted == true)
        #expect(reloaded.launchAtLoginPreference == false)
        #expect(reloaded.lastSeenTodoIDs == [1, 2, 3, 42])
        #expect(reloaded.resolvedHost == "gitlab.corp.example.com")
        #expect(reloaded.glabPath?.path == "/opt/homebrew/bin/glab")
    }

    @Test func automaticEventBannersDefaultOnForNewAndExistingInstallsAndPreserveOptOut() {
        let defaults = makeDefaults()
        #expect(SettingsManager(defaults: defaults).autoHandledEventBannersEnabled)
        defaults.set(true, forKey: "onboardingCompleted")
        defaults.set(false, forKey: "notificationsEnabled")
        let upgraded = SettingsManager(defaults: defaults)
        #expect(upgraded.autoHandledEventBannersEnabled)
        upgraded.autoHandledEventBannersEnabled = false
        upgraded.save()
        #expect(!SettingsManager(defaults: defaults).autoHandledEventBannersEnabled)
    }

    @Test func ignoredMRsPersistPerHostAccountProjectAndNumber() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        let ignored = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 7, iid: 42)
        settings.ignoredMergeRequests.insert(ignored)
        settings.save()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.ignoredMergeRequests == [ignored])
        #expect(!reloaded.ignoredMergeRequests.contains(.init(host: "other.example.org", username: "me", projectID: 7, iid: 42)))
        #expect(!reloaded.ignoredMergeRequests.contains(.init(host: "gitlab.example.org", username: "other", projectID: 7, iid: 42)))
    }

    @Test("clearing optional fields removes them from defaults")
    func clearsOptionals() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        settings.resolvedHost = "gitlab.com"
        settings.glabPath = URL(fileURLWithPath: "/usr/local/bin/glab")
        settings.save()

        settings.resolvedHost = nil
        settings.glabPath = nil
        settings.save()

        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.resolvedHost == nil)
        #expect(reloaded.glabPath == nil)
    }

    @Test func acceptedFeedbackResolutionDefaultsOnAndPreservesAnExplicitOptOut() throws {
        #expect(AutomationSettings().autoResolveAcceptedFeedback)
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8)).autoResolveAcceptedFeedback)
        var configuration = AutomationSettings()
        configuration.autoResolveAcceptedFeedback = false
        let saved = try JSONEncoder().encode(configuration)
        #expect(try !JSONDecoder().decode(AutomationSettings.self, from: saved).autoResolveAcceptedFeedback)
    }

    @Test("markLaunched flips isFirstLaunch")
    func firstLaunchFlip() {
        let defaults = makeDefaults()
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.isFirstLaunch == true)
        settings.markLaunched()
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.isFirstLaunch == false)
    }
    @MainActor @Test func explicitPolicySavesNotifySynchronouslyWithoutReentrantDuplicates() throws {
        let suite = "SettingsPolicyCallback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let previous = settings.automation
        var callbacks: [AutomationSettings] = []
        settings.onAutomationChanged = { old in
            callbacks.append(old)
            #expect(SettingsManager(defaults: defaults).automation == settings.automation)
            settings.save()
        }
        settings.notificationsEnabled.toggle()
        settings.save()
        #expect(callbacks.isEmpty)
        settings.automation.allowFollowUpPush.toggle()
        #expect(callbacks.isEmpty)
        settings.save()
        #expect(callbacks == [previous])

        let beforeScopeChange = settings.automation
        settings.automation.scope.mode = .selected
        settings.save()
        #expect(callbacks == [previous, beforeScopeChange])
        settings.onAutomationChanged = nil
    }

    @Test func scopeSaveCancelsOnlyItsPausedAutomaticJob() async throws {
        let suite = "ScopeCancellation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = .enabled
        settings.save()
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        let coordinator = AssistantJobCoordinator(maximumConcurrentJobs: 3, execute: { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init(result: .init(status: .succeeded, summary: "Fixture"), output: "")
        })
        let monitor = TodoMonitorService(settings: settings, cancelPolicyJob: { id, _ in coordinator.cancel(id) })
        defer { monitor.stopTimer() }
        let host = "scope.example.org"
        let jobs = [1, 2, 3].map { iid in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: host, projectID: 1, iid: iid), username: "me", workspace: "", access: .gitLabRead),
                title: "Fixture", prompt: "", createdAt: Date(), allowsPush: false,
                execution: .init(state: .queued), manual: iid == 3)
        }
        settings.assistantHandoffs = jobs
        for job in jobs { #expect(coordinator.schedule(job, settings: settings)) }
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 99)] = .paused
        settings.save()
        try await Task.sleep(for: .milliseconds(100))
        #expect(settings.assistantHandoffs.allSatisfy { $0.execution?.state.isActive == true })
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 1)] = .paused
        settings.automation.scope[.init(host: host, username: "me", projectID: 1, iid: 3)] = .paused
        settings.save()
        try await Task.sleep(for: .milliseconds(100))
        #expect(settings.assistantHandoffs[0].execution?.state == .cancelled)
        #expect(settings.assistantHandoffs[1].execution?.state.isActive == true)
        #expect(settings.assistantHandoffs[2].execution?.state.isActive == true)
        for job in jobs { coordinator.cancel(job.id) }
        let deadline = ContinuousClock.now + .seconds(2)
        while jobs.contains(where: { coordinator.isRunning($0.id) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

/// Fault injection stays at the preferences adapter; successful reads/writes use a real isolated suite.
final class PersistenceFaultDefaults: UserDefaults {
    var rejectedKey: String?
    var synchronizationFails = false
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName != rejectedKey { super.set(value, forKey: defaultName) }
    }
    override func synchronize() -> Bool {
        let result = super.synchronize()
        return !synchronizationFails && result
    }
}

private final class HistoryWriteDefaults: UserDefaults {
    var historyWrites = 0
    var writesByKey: [String: Int] = [:]
    var synchronizationFails = false
    override func set(_ value: Any?, forKey key: String) {
        if key == "assistantHandoffs" { historyWrites += 1 }
        writesByKey[key, default: 0] += 1
        super.set(value, forKey: key)
    }
    override func synchronize() -> Bool {
        let saved = super.synchronize()
        return !synchronizationFails && saved
    }
}
