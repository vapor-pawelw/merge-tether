import AppKit
import SwiftUI
import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MREffectivePolicyPresentationTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)

    @Test func savedCustomPolicyExplainsPublicationAndMergeIndependently() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.setActionAutomatic(.merge, enabled: false, for: target)
            let result = presentation(settings)
            #expect(result.clauses == [.publicationAfterChecks(.all), .mergeManual])
            #expect(settings.automation.autoMergeEnabled)
        }
    }

    @Test(arguments: ["new", "legacy", "completed"])
    func undecidedConsentExplainsTheDecisionAndOffersAutomationSettings(_ installation: String) throws {
        try fixture { settings, defaults, _ in
            // Given a new install or saved settings that have never granted automation consent.
            if installation == "legacy" {
                defaults.set(Data(#"{"autoMergeEnabled":true,"publishDraftsWithoutConfirmation":true}"#.utf8), forKey: "automation")
            } else if installation == "completed" {
                settings.onboardingCompleted = true
                settings.automation.autoMergeEnabled = true
                settings.automation.publicationMode = .all
                settings.save()
            }
            let restored = installation == "new" ? settings : SettingsManager(defaults: defaults)
            let before = restored.automation

            // When the user follows the explanation's settings action.
            let policy = presentation(restored)
            let navigation = SettingsNavigation()
            var opened: SettingsNavigation.Tab?
            let action = try #require(policy.settingsAction)
            navigation.perform(action) { opened = navigation.selection }

            // Then the existing automation tab opens, without granting consent or changing toggles.
            #expect(policy.clauses == [.automationDecisionRequired])
            #expect(action == .chooseAutomationSettings && opened == .automation)
            #expect(restored.automation == before && restored.automation.packageDecision == .undecided)
            #expect(!restored.automaticWritesAllowed)
            let request = try request()
            #expect(MRAutomaticAction.allCases.allSatisfy { !restored.permitsAutomaticAction($0, for: request, target: target) })
        }
    }

    @Test(arguments: [AutomationPackageDecision.disabled, .enabled])
    func decidedConsentDoesNotOfferTheUndecidedSetupAction(_ decision: AutomationPackageDecision) throws {
        try fixture { settings, _, _ in
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.packageDecision = decision
            let policy = presentation(settings)
            #expect(policy.settingsAction == nil)
            #expect(policy.clauses == (decision == .disabled ? [.automationOff] : [.publicationAfterChecks(.all), .mergeAfterChecks]))
            #expect(settings.automaticWritesAllowed == (decision == .enabled))
        }
    }

    @Test(arguments: [AutomationPublicationMode.all, .aiReplies, .filtered, .manual])
    func publicationExplainsTheSavedModeWithoutInventingVerifiedCounts(_ mode: AutomationPublicationMode) throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.publicationMode = mode
            if mode == .filtered { settings.automation.publicationRestrictions.requireAI = true }
            let result = presentation(settings)
            #expect(result.clauses.first == (mode == .manual ? .publicationManual : .publicationAfterChecks(mode)))
        }
    }

    @Test func aFilterWithNoConditionsDoesNotPromisePublication() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.publicationMode = .filtered
            settings.automation.publicationRestrictions = .init()
            #expect(presentation(settings).clauses.first == .publicationManual)
        }
    }

    @Test func scopeAndDraftTransitionsKeepForcedAndInheritedChoicesDistinct() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            #expect(presentation(settings, draft: true).clauses == [.draftPaused])
            settings.automation.scope.setManualChoice(.forceOn, for: target)
            #expect(presentation(settings, draft: true).clauses.first == .publicationAfterChecks(.all))
            settings.automation.scope.setManualChoice(.paused, for: target)
            #expect(presentation(settings).clauses == [.scopePaused])
            settings.automation.scope.setManualChoice(.inherit, for: target)
            settings.automation.scope.setEnabled(false, for: target.repository)
            #expect(presentation(settings).clauses == [.scopePaused])
        }
    }

    @Test(arguments: [MergeSubmissionState.queued, .inTrain, .uncertain, .changed])
    func gitLabDelegationRemainsVisibleAfterLocalAutomationIsDisabled(_ state: MergeSubmissionState) throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.manual, for: .codex)
            #expect(presentation(settings, submission: state).clauses == [.mergeSubmission(state)])
        }
    }

    @Test func corruptSafetyDataIsARuntimeHoldWithoutChangingTheSavedProfile() throws {
        try fixture { settings, defaults, domain in
            settings.automation.applyPreset(.full, for: .codex)
            settings.save()
            defaults.set(Data("corrupt".utf8), forKey: "workflowActivity")
            let restored = SettingsManager(defaults: defaults)
            #expect(presentation(restored).clauses == [.savedDataHold])
            #expect(restored.automation == settings.automation)
        }
    }

    @Test func unavailableCurrentAccountOrChangedReadCannotPromiseAutomaticWork() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            #expect(presentation(settings, current: false).clauses == [.requiresVerification])
            #expect(presentation(settings, readUnavailable: true).clauses == [.requiresVerification])
            #expect(presentation(settings, draft: nil).clauses == [.requiresVerification])
        }
    }

    @Test(arguments: ["provider", "catalog", "discussions"])
    func sameContextRevalidationKeepsPolicyWhileActionsRemainBlocked(_ source: String) throws {
        try fixture { settings, _, _ in
            // Given a checked row and a routine read in the same account and MR context.
            settings.automation.applyPreset(.full, for: .codex)
            let request = try request()
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2),
                title: request.title, url: request.webURL, mergeRequest: request, isAuthored: true)
            if source == "discussions" { item.reReviewReadiness = .checking }
            let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
            let input = MRBoardProjector.RowInput(account: .init(host: target.host, username: target.username, revision: 2),
                automation: settings.automation, workflowEntries: [], assistantReady: true,
                assistantChecking: source == "provider", catalogLoading: source == "catalog")
            let checking = MRBoardProjector.isRecheckingAttention(for: row, input: input)

            // When the policy description reads the same refresh facts as the card.
            let state = MREffectivePolicyPresentation.ReadState(catalogCurrent: true, row: row, input: input)
            let policy = MREffectivePolicyPresentation(input: .init(request: request, target: target,
                settings: settings, assistantReady: true, readState: state))
            let card = MRCardPresentation(row: row, reviewingContext: MRBoardProjector.reviewingContext(for: row, input: input),
                allowsRemoval: false, assistantReady: true, isRefreshingAttention: checking, showsReadProgress: false)

            // Then the saved policy stays useful without restoring action authorization.
            #expect(checking && state == .rechecking)
            #expect(policy.clauses == [.publicationAfterChecks(.all), .mergeAfterChecks])
            #expect(card.actionsBlocked)
        }
    }

    @Test(arguments: ["initial", "account", "context", "error"])
    func unavailableEvidenceCannotBePresentedAsRoutineRevalidation(_ reason: String) throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            let state = MREffectivePolicyPresentation.ReadState(
                catalogCurrent: reason != "initial" && reason != "account",
                sameContext: reason != "context", readFailed: reason == "error", rechecking: true)
            let policy = MREffectivePolicyPresentation(input: .init(request: try request(), target: target,
                settings: settings, assistantReady: true, readState: state))
            #expect(state == .unavailable)
            #expect(policy.clauses == [.requiresVerification])
        }
    }

    @Test func foregroundProviderProbeKeepsPolicyButAReadFailureStillBlocksIt() async throws {
        // Given a previously ready provider and the saved full automation policy.
        let name = "MREffectivePolicyPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let providers = AssistantDependencyMonitor(probe: { _, _ in .ready(URL(fileURLWithPath: "/in-memory/assistant")) })
        providers.refresh(force: true)
        for _ in 0..<1000 where providers.isChecking { await Task.yield() }
        try #require(!providers.isChecking && providers.available.contains(.codex))
        let request = try request()
        let row = MergeRequestBoardSnapshot.Row(item: .init(id: .init(projectID: 1, iid: 2),
            title: request.title, url: request.webURL, mergeRequest: request, isAuthored: true), latestJob: nil, intents: [])

        // When focus forces another provider check, the production projector reports checking.
        providers.refresh(force: true)
        var facts = MRBoardProjector.RowInput(account: .init(host: target.host, username: target.username, revision: 2),
            automation: settings.automation, workflowEntries: [],
            assistantReady: providers.available.contains(.codex), assistantChecking: providers.isChecking)
        func policy() -> MREffectivePolicyPresentation {
            let state = MREffectivePolicyPresentation.ReadState(catalogCurrent: true, row: row, input: facts)
            return .init(input: .init(request: request, target: target, settings: settings,
                assistantReady: facts.assistantReady, readState: state))
        }

        // Then probing preserves useful policy text, but a real failed read takes precedence.
        #expect(facts.assistantChecking)
        #expect(policy().clauses == [.publicationAfterChecks(.all), .mergeAfterChecks])
        let card = MRCardPresentation(row: row, reviewingContext: MRBoardProjector.reviewingContext(for: row, input: facts),
            allowsRemoval: false, assistantReady: facts.assistantReady,
            isRefreshingAttention: MRBoardProjector.isRecheckingAttention(for: row, input: facts), showsReadProgress: false)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        do {
            try await glab.publishDraftNote(projectID: 1, iid: 2, draftID: 7, host: target.host,
                shouldProceed: { !card.actionsBlocked })
            Issue.record("Revalidation restored stale write permission")
        } catch is CancellationError {}
        #expect(gitlab.requests.isEmpty)
        facts.catalogReadFailed = true
        #expect(policy().clauses == [.requiresVerification])
        for _ in 0..<1000 where providers.isChecking { await Task.yield() }
        #expect(!providers.isChecking)
    }

    @Test(arguments: ["sha", "source_branch", "target_branch", "description"])
    func changedCatalogContentInvalidatesPolicyAndCheckedActionsDuringRefresh(_ field: String) throws {
        try fixture { settings, _, _ in
            // Given an old checked envelope and genuinely different catalog content.
            settings.automation.applyPreset(.full, for: .codex)
            let checked = try request()
            var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checked)) as? [String: Any])
            data[field] = "changed"
            let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: data))
            let evidence = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: checked.title,
                url: checked.webURL, automaticDraftIDs: [7], canApprove: true, autoApproveReady: true,
                needsMerge: true, canConfirmReReview: true, mergeRequest: checked, isAuthored: true)
            let catalog = MergeRequestAttentionMonitor.Item(id: evidence.id, title: current.title,
                url: current.webURL, mergeRequest: current, isAuthored: true)
            let projection = MRCurrentRowProjection(evidence: evidence, catalog: catalog, username: target.username)

            // When a background read is also in progress.
            let state = MREffectivePolicyPresentation.ReadState(catalogCurrent: true,
                sameContext: projection.evidenceMatchesCatalogContext, readFailed: false, rechecking: true)
            let policy = MREffectivePolicyPresentation(input: .init(request: current, target: target,
                settings: settings, assistantReady: true, readState: state))

            // Then new facts cannot inherit old approval, merge or publication evidence.
            #expect(policy.clauses == [.requiresVerification])
            #expect(!projection.item.canApprove && !projection.item.autoApproveReady)
            #expect(!projection.item.needsMerge && !projection.item.canConfirmReReview)
            #expect(projection.item.automaticDraftIDs.isEmpty)
        }
    }

    @Test func commentReviewAndProviderHoldsDoNotBecomeAutomaticConsent() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.full, for: .codex)
            settings.beginCommentReview(for: target)
            #expect(presentation(settings).clauses.last == .finishCommentReview)
            #expect(presentation(settings, assistantReady: false).clauses == [.assistantUnavailable])
        }
    }

    @Test func localPreparationDoesNotClaimDeliveryOrAIExecution() throws {
        try fixture { settings, _, _ in
            settings.automation.applyPreset(.checkpoints, for: .codex)
            #expect(presentation(settings).clauses == [.publicationAfterChecks(.aiReplies), .deliveryManual])
        }
    }

    @Test func recomputingTheDescriptionDoesNotPersistOrMutateSettings() throws {
        try fixture { settings, defaults, domain in
            settings.automation.applyPreset(.full, for: .codex)
            let policy = settings.automation
            let stored = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
            for _ in 0..<10 { _ = presentation(settings) }
            #expect(settings.automation == policy)
            #expect((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary == stored)
        }
    }

    @Test func renderingTheLiveAdapterDoesNotFetchLaunchOrSave() throws {
        try fixture { settings, defaults, domain in
            // Given account-bound display metadata and a real command-boundary fake.
            let gitlab = InMemoryGitLab()
            let glab = gitlab.service(host: target.host, username: target.username)
            let monitor = TodoMonitorService(settings: settings, glab: glab)
            defer { monitor.stopTimer() }
            let request = try request()
            monitor.recordBoardDisplayRequest(request, for: target, url: request.webURL,
                accountRevision: glab.accountRevision, readStartedAt: Date())
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2),
                title: request.title, url: request.webURL)
            item.mergeRequest = request
            let before = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
            let policy = settings.automation

            // When SwiftUI evaluates and lays out the production adapter.
            let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
            let view = NSHostingView(rootView: MREffectivePolicySummary(row: row, monitor: monitor).frame(width: 280))
            #expect(view.fittingSize.height > 0)

            // Then rendering has made no GitLab request, job or persistence change.
            #expect(gitlab.requests.isEmpty && settings.assistantHandoffs.isEmpty)
            #expect(settings.automation == policy)
            #expect((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary == before)
        }
    }

    @Test func rendersPolicyWithoutMutatingSavedSettings() throws {
        try fixture { settings, defaults, domain in
            settings.automation.applyPreset(.full, for: .codex)
            let frozen = presentation(settings)
            let before = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
            let view = NSHostingView(rootView: MREffectivePolicyView(presentation: frozen).frame(width: 280))
            #expect(view.fittingSize.height > 0)
            #expect((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary == before)
            if let path = ProcessInfo.processInfo.environment["WS8_LAYOUT_PATH"] {
                try renderLayoutProof(frozen, path: path)
            }
            if let path = ProcessInfo.processInfo.environment["WS8_SETTINGS_PROOF_PATH"] {
                try renderSettingsProof(settings, path: path)
            }
        }
    }

    @Test(arguments: [AutomationPublicationMode.all, .filtered, .aiReplies, .manual])
    func renderingExplicitPublicationFiltersPreservesDormantValuesAndMakesNoRequests(_ mode: AutomationPublicationMode) throws {
        var restrictions = AutomaticPublicationRestrictions(repositories: [
            .init(host: target.host, entityID: 1, label: "Custom repository")
        ], requireAI: false)
        let before = restrictions
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        let view = NSHostingView(rootView: Form {
            PublicationRestrictionsSettingsView(restrictions: Binding(get: { restrictions }, set: { restrictions = $0 }),
                mode: mode, glab: glab, preset: .full)
        }.frame(width: 650))
        #expect(view.fittingSize.height > 0)
        #expect(restrictions == before && gitlab.requests.isEmpty)
    }

    @Test(arguments: [AutomationRunner.shell, .assistant])
    func renderingAdvancedTemplatesNeverMigratesOrRewritesStoredHandlers(_ runner: AutomationRunner) throws {
        var rule = AutomationRule(promptTemplate: "Custom prompt {url}")
        rule.runner = runner
        rule.isEnabled = true
        rule.command = "saved-handler {url}"
        rule.titleTemplate = "Custom title {repo}"
        rule.promptTemplate = "Custom prompt {url}"
        rule.projects = "group/repository"
        let before = rule
        let view = NSHostingView(rootView: Form {
            AutomationRuleTemplateSettings(rule: Binding(get: { rule }, set: { rule = $0 }),
                title: .Settings.settingsAutomationAuthorFeedback)
        }.frame(width: 650))
        #expect(view.fittingSize.height > 0)
        #expect(rule == before)
    }

    @Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func renderingDeliveryKeepsPushConsentsAndInactivePrerequisitesIndependent(_ preparation: Bool, _ tools: Bool, _ followUpPush: Bool) throws {
        try fixture { settings, defaults, domain in
            // Given a saved conflict-push choice with independently configured prerequisites.
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.conflictTasksEnabled = preparation
            settings.automation.allowAssistantTools = tools
            settings.automation.allowConflictPush = true
            settings.automation.allowFollowUpPush = followUpPush
            settings.automation.assistantToolProjects = "group/repository"
            settings.automation.conflictPushProjects = "group/repository"
            let before = settings.automation
            let stored = (defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary
            let gitlab = InMemoryGitLab()
            defer { gitlab.close() }
            let monitor = TodoMonitorService(settings: settings, glab: gitlab.service(host: target.host, username: target.username))
            defer { monitor.stopTimer() }

            // When the reorganized settings form displays inactive saved controls.
            let view = NSHostingView(rootView: AutomationSettingsTab(monitor: monitor).frame(width: 850))
            #expect(view.fittingSize.height > 0)

            // Then rendering grants nothing; each existing permission still controls its own action.
            #expect(settings.automation == before && settings.automation.allowFollowUpPush == followUpPush)
            #expect(settings.automation.permitsConflictPush(project: "group/repository") == (preparation && tools))
            #expect(!settings.automation.permitsConflictPush(project: "group/other"))
            #expect(gitlab.requests.isEmpty)
            #expect((defaults.persistentDomain(forName: domain) ?? [:]) as NSDictionary == stored)
        }
    }

    private func renderSettingsProof(_ settings: SettingsManager, path: String) throws {
        let original = settings.automation
        defer { settings.automation = original }
        let gitlab = InMemoryGitLab()
        let glab = gitlab.service(host: target.host, username: target.username)
        let monitor = TodoMonitorService(settings: settings, glab: glab)
        defer { monitor.stopTimer() }
        let content = AutomationSettingsTab(monitor: monitor).frame(width: 1040, height: 1900)
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: .aqua)
        view.frame = .init(x: 0, y: 0, width: 1040, height: 1900)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.isEnabled = true
        settings.automation.reviewRequested.command = "saved-review-handler {url}"
        settings.automation.authorFeedback.runner = .shell
        settings.automation.authorFeedback.isEnabled = false
        settings.automation.authorFeedback.command = "saved-feedback-handler {url}"
        let advanced = NSHostingView(rootView: AutomationSettingsTab(monitor: monitor, initialPage: .advanced)
            .frame(width: 1040, height: 980))
        advanced.appearance = NSAppearance(named: .aqua)
        advanced.frame = .init(x: 0, y: 0, width: 1040, height: 980)
        window.setContentSize(.init(width: 1040, height: 980))
        window.contentView = advanced
        advanced.layoutSubtreeIfNeeded()
        let advancedBitmap = try #require(advanced.bitmapImageRepForCachingDisplay(in: advanced.bounds))
        advanced.cacheDisplay(in: advanced.bounds, to: advancedBitmap)
        let advancedPNG = try #require(advancedBitmap.representation(using: .png, properties: [:]))
        try advancedPNG.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-advanced.png")))
        #expect(gitlab.requests.isEmpty)
    }

    private func renderLayoutProof(_ policy: MREffectivePolicyPresentation, path: String) throws {
        let content = VStack(alignment: .leading, spacing: 24) {
            Text("Synthetic headless layout proof").font(.title2.bold())
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Compact card · Example MR").font(.headline)
                    Text("Could not refresh. The last confirmed discussion and action remain available.")
                        .font(.caption).foregroundStyle(.orange)
                    MREffectivePolicyView(presentation: policy)
                    HStack { Button("Review comments") {}; Button("Actions") {} }
                }.padding().frame(width: 310).background(Color.secondary.opacity(0.08))
                VStack(alignment: .leading, spacing: 9) {
                    Text("Long localized copy / expanded error").font(.headline)
                    Text("The latest request could not complete. Review the existing result before starting another attempt.")
                        .foregroundStyle(.orange)
                    MREffectivePolicyView(presentation: policy).environment(\.font, .title3)
                    HStack { Button("Review and confirm") {}; Button("Actions") {} }
                }.padding().frame(width: 310).background(Color.secondary.opacity(0.08))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Details · Example MR").font(.headline)
                MREffectivePolicyView(presentation: policy)
                HStack { Button("Merge now") {}; Button("Resolve addressed threads…") {} }
                ForEach(0..<4) { _ in Text("Synthetic discussion context. Existing comments and private replies remain independently reviewable.") }
                Divider()
                HStack { Spacer(); Button("Publish selected comments") {} }
            }.padding().frame(width: 660).background(Color.secondary.opacity(0.08))
            VStack(alignment: .leading) {
                Text("Finished card · Example MR").font(.headline)
                Text("Merged").foregroundStyle(.secondary)
            }.padding().frame(width: 310, alignment: .leading).background(Color.secondary.opacity(0.08))
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    private func presentation(_ settings: SettingsManager, draft: Bool? = false, current: Bool = true,
                              readUnavailable: Bool = false, assistantReady: Bool = true,
                              submission: MergeSubmissionState = .none) -> MREffectivePolicyPresentation {
        let request = try! request(draft: draft)
        return .init(input: .init(request: current ? request : nil, target: target, settings: settings,
            assistantReady: assistantReady, readState: readUnavailable ? .unavailable : .current, submission: submission))
    }

    private func request(draft: Bool? = false) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
        {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example",
        "web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened",
        "draft":\(draft.map(String.init) ?? "null"),"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}
        """.utf8))
    }

    private func fixture(_ body: (SettingsManager, UserDefaults, String) throws -> Void) throws {
        let name = "MREffectivePolicyPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(SettingsManager(defaults: defaults), defaults, name)
    }
}
