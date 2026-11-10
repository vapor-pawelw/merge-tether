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
        }
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
            assistantReady: assistantReady, readUnavailable: readUnavailable, submission: submission))
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
