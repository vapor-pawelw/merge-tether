import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRFeedbackLaunchCoordinatorTests {
    @Test func aLateFailureFromAnEarlierAccountRevisionCannotBlockCurrentVerifiedFeedback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.monitor.bootstrap()
        try #require(fixture.glab.resolvedHost == Fixture.host && fixture.glab.glabPath != nil)
        fixture.gitlab.write("pause-first")
        let old = Task { await fixture.runVerified() }
        try await fixture.waitFor("first-entered")
        fixture.glab.currentUsername = "other"
        fixture.glab.currentUsername = "me"
        fixture.gitlab.write("release-first")
        await old.value
        await fixture.runVerified()
        await fixture.coordinator.waitForTermination()
        #expect(fixture.settings.assistantHandoffs.count == 1)
        #expect(fixture.settings.assistantHandoffs.first?.key.username == "me")
        #expect(fixture.settings.assistantHandoffs.first?.feedbackNoteIDs == [20])
    }

    @Test(arguments: [false, true])
    func rawAndVerifiedPreflightsShareOneLaunchSlot(_ verifiedFirst: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let item = try f.item()
        f.gitlab.write("hold-read")
        let first = Task {
            if verifiedFirst { await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint) }
            else { await f.owner.runAttentionFeedback(for: item) }
        }
        try await f.waitFor("read-entered")
        #expect(f.owner.action(for: item) == .running)
        if verifiedFirst { await f.owner.runAttentionFeedback(for: item) }
        else { await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint) }
        #expect(f.mrReads == 1 && f.settings.assistantHandoffs.isEmpty)
        f.gitlab.write("release-read")
        await first.value
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(f.owner.failures.isEmpty && f.owner.action(for: item) == nil)
    }

    @Test func oldCompletionCannotChangeTheNewAccountsStillPreparingSlot() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let item = try f.item()
        f.gitlab.write("pause-first")
        let old = Task { await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint) }
        try await f.waitFor("first-entered")
        f.glab.currentUsername = "other"; f.glab.currentUsername = "me"
        f.gitlab.write("hold-read")
        let current = Task { await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint) }
        try await f.waitFor("read-entered")
        f.gitlab.write("release-first")
        await old.value
        #expect(f.owner.action(for: item) == .running && f.owner.failures.isEmpty)
        f.gitlab.write("release-read")
        await current.value
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1 && f.owner.failures.isEmpty)
    }

    @Test(arguments: [false, true])
    func editingTheSameNoteCannotInheritAnEarlierFailure(_ updateFingerprint: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let original = try f.item()
        f.gitlab.write("pause-first"); f.gitlab.write("release-first")
        await f.owner.runAttentionFeedback(for: original)
        #expect(f.owner.action(for: original) == .failed)
        let failure = try #require(f.owner.failures.first)
        var changed = original
        changed.feedback[0].body = "Edited request with the same note ID"
        if updateFingerprint { changed.observedDiscussionFingerprint = "new-observed-conversation" }
        let count = f.gitlab.requests.count
        #expect(f.owner.action(for: changed) == .ready(.assistant))
        #expect(!failure.matches(changed, host: Fixture.host, username: "me", revision: f.glab.accountRevision,
            configuration: f.settings.automation))
        #expect(f.gitlab.requests.count == count && f.settings.assistantHandoffs.isEmpty)
    }

    @Test func aCurrentFailureHoldsAutomaticReplayButAnExplicitManualRetryCanAdmit() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.gitlab.write("pause-first"); f.gitlab.write("release-first")
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        #expect(f.owner.failures.count == 1)
        let count = f.mrReads
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        #expect(f.mrReads == count && f.settings.assistantHandoffs.isEmpty)
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: true)
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1 && f.owner.failures.isEmpty)
    }

    @Test func aTypedAdmissionReturnsTheActualPersistedJobAndCoveredWorkDoesNotRefundItsAttempt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let outcome = try await f.prepare()
        guard case .admitted(let id) = outcome else { Issue.record("Expected an actual admitted Handoff"); return }
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.first?.id == id)
        #expect(f.settings.assistantHandoffs.first?.execution?.state == .succeeded)
        let attempts = f.settings.authorFeedbackAttempts
        try #require(!attempts.isEmpty)
        let repeated = try await f.prepare()
        #expect(repeated == .notAdmitted(.noActionableFeedback))
        #expect(f.settings.authorFeedbackAttempts == attempts && f.settings.assistantHandoffs.count == 1)
        let restored = SettingsManager(defaults: f.defaults)
        #expect(restored.assistantHandoffs.first?.id == id && restored.authorFeedbackAttempts == attempts)
    }

    @Test func noActionableFeedbackDoesNotBecomeAFailedLaunchOrADisplayedJob() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let old = try f.item()
        f.gitlab.write("discussions", Fixture.discussionJSON.replacingOccurrences(of: "\"resolvable\":false",
            with: "\"resolvable\":true,\"resolved\":true"))
        await f.owner.runAttentionFeedback(for: old)
        #expect(f.owner.failures.isEmpty && f.settings.assistantHandoffs.isEmpty)
        #expect(f.owner.action(for: old) == .ready(.assistant))
        var current = old; current.feedback = []; current.needsDiscussion = false
        #expect(f.owner.action(for: current) == nil)
    }

    @Test func changingConfigurationDuringPreflightDoesNotBecomeFailureOrAdmission() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.gitlab.write("hold-read")
        let pending = Task { await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint) }
        try await f.waitFor("read-entered")
        f.settings.automation.allowFollowUpPush.toggle()
        f.gitlab.write("release-read")
        await pending.value
        #expect(f.owner.failures.isEmpty && f.settings.assistantHandoffs.isEmpty)
        #expect(f.settings.authorFeedbackAttempts.isEmpty)
    }

    @Test func rawPreflightCanReadANewerHeadWithoutAUIHeadFence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let old = try f.item()
        f.gitlab.write("request", Fixture.requestJSON.replacingOccurrences(of: "head-a", with: "head-b"))
        await f.owner.runAttentionFeedback(for: old)
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1 && f.owner.failures.isEmpty)
    }

    @Test func notAdmittedDoesNotBlockALegalLaterExternalCommand() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.gitlab.write("request", Fixture.requestJSON.replacingOccurrences(of: "\"state\":\"opened\"", with: "\"state\":\"closed\""))
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        #expect(f.settings.assistantHandoffs.isEmpty && f.owner.failures.isEmpty)
        f.gitlab.write("request", Fixture.requestJSON)
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1)
    }

    @Test func aRawFailureCannotBeReplayedAutomaticallyBySwitchingToVerifiedInput() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.readyForRaw()
        let item = try f.item()
        f.gitlab.write("pause-first"); f.gitlab.write("release-first")
        await f.owner.runAttentionFeedback(for: item, manual: false)
        #expect(f.owner.action(for: item) == .failed)
        let count = f.mrReads
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        await f.coordinator.waitForTermination()
        #expect(f.mrReads == count && f.settings.assistantHandoffs.isEmpty)
    }

    @Test func aChangedCanonicalDecisionRevisionDoesNotInheritTheOldFailure() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.gitlab.write("pause-first"); f.gitlab.write("release-first")
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        #expect(f.owner.failures.count == 1)
        let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
        let note = try #require(f.item().feedback.first)
        let decision = f.settings.feedbackSuggestionDecisions.ignore(note,
            concernSummary: "Specific concern", concernReason: "Explicit decision", for: target)
        let ignored = try #require(decision)
        let removed = f.settings.feedbackSuggestionDecisions.remove(ignored.id, for: target)
        #expect(removed)
        #expect(!f.settings.feedbackSuggestionDecisions.revision(for: target).isEmpty)
        #expect(f.owner.failures.isEmpty)
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        await f.coordinator.waitForTermination()
        #expect(f.settings.assistantHandoffs.count == 1)
    }

    @Test func aVerifiedFailureCannotDescribeFeedbackWhoseSelectedNoteWasRemoved() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.gitlab.write("pause-first"); f.gitlab.write("release-first")
        await f.owner.runVerifiedAuthorFeedback(request: f.request, noteIDs: [20], fingerprint: f.fingerprint, manual: false)
        let failure = try #require(f.owner.failures.first)
        var current = try f.item()
        current.feedback = []
        #expect(!failure.matches(current, host: Fixture.host, username: "me", revision: f.glab.accountRevision,
            configuration: f.settings.automation))
    }

    @MainActor private final class Fixture {
        static let host = "gitlab.example.test"
        static let requestJSON = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example MR","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head-a","source_branch":"feature","target_branch":"main","source_project_id":1,"labels":[]}"#
        static let discussionJSON = #"[{"id":"general-condition","notes":[{"id":20,"author":{"id":7,"username":"alice"},"system":false,"body":"Please rename X","resolvable":false}]}]"#
        let name = "MRFeedbackLaunchCoordinatorTests.\(UUID())"
        let defaults: UserDefaults
        let directory: URL
        let settings: SettingsManager
        let gitlab = InMemoryGitLab()
        let glab: GlabService
        let coordinator: AssistantJobCoordinator
        let monitor: TodoMonitorService
        let service: TodoAutomationService
        let providers: AssistantDependencyMonitor
        let inbox: InboxTodoStore
        let owner: MRFeedbackLaunchCoordinator
        let request: GitLabMergeRequest
        var fingerprint: String
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = false
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.scope.setEnabled(true, for: .init(host: Self.host, username: "me", projectID: 1, iid: 2))
            settings.save()
            glab = gitlab.service(host: Self.host, username: "me")
            settings.glabPath = glab.glabPath
            settings.resolvedHost = Self.host
            settings.save()
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Self.requestJSON.utf8))
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(Self.discussionJSON.utf8))
            fingerprint = try #require(ReviewVerdict.fingerprint(discussions))
            coordinator = AssistantJobCoordinator(execute: { _, _ in
                .init(result: .init(status: .succeeded, summary: "Synthetic execution"), output: "")
            })
            service = TodoAutomationService(canAutomate: { _ in true }, jobCoordinator: coordinator, followUpDirectory: directory)
            monitor = TodoMonitorService(settings: settings, glab: glab,
                notifications: NotificationService(authorization: { .denied }, post: { _ in }), automation: service)
            providers = AssistantDependencyMonitor(probe: { _, _ in .ready(URL(fileURLWithPath: "/in-memory/assistant")) })
            inbox = InboxTodoStore(settings: settings, glab: glab)
            owner = MRFeedbackLaunchCoordinator(settings: settings, glab: glab, automation: service, inbox: inbox,
                providers: providers, health: AssistantCLIHealthStore(defaults: defaults, persists: false))
            gitlab.write("request", Self.requestJSON)
            gitlab.write("discussions", Self.discussionJSON)
            gitlab.handler = { [gitlab] command in
                if command.arguments.first == "config" { return InMemoryGitLab.output(Self.host) }
                if command.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(Self.host) as me") }
                switch command.endpoint {
                case "/projects/1/merge_requests/2":
                    if gitlab.has("pause-first") {
                        gitlab.remove("pause-first")
                        gitlab.write("first-entered")
                        try await gitlab.waitFor("release-first")
                        throw GlabError.unknown("Earlier account read failed")
                    }
                    if gitlab.has("hold-read") {
                        gitlab.remove("hold-read"); gitlab.write("read-entered")
                        try await gitlab.waitFor("release-read")
                    }
                    return try gitlab.response("request")
                case let path where path.contains("/discussions?"): return try gitlab.response("discussions")
                case let path where path.hasPrefix("/projects/1/merge_requests?"): return InMemoryGitLab.output("[]")
                case "/projects/1": return InMemoryGitLab.output(#"{"default_branch":"main"}"#)
                default: return try gitlab.unexpected(command)
                }
            }
        }
        var mrReads: Int { gitlab.requests.filter { $0.endpoint == "/projects/1/merge_requests/2" }.count }
        func item() throws -> MergeRequestAttentionMonitor.Item {
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions"))
            return .init(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL,
                observedDiscussionFingerprint: ReviewVerdict.fingerprint(discussions), needsDiscussion: true,
                mergeRequest: request, isAuthored: true, feedback: discussions.flatMap(\.notes))
        }
        func readyForRaw() async throws {
            await monitor.bootstrap()
            inbox.bindAccount(host: Self.host, username: "me", revision: glab.accountRevision)
            inbox.accept([])
            gitlab.write("discussions", Self.discussionJSON.replacingOccurrences(of: "\"resolvable\":false",
                with: "\"resolvable\":true,\"resolved\":false"))
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions"))
            fingerprint = try #require(ReviewVerdict.fingerprint(discussions))
            providers.refresh(force: true)
            let deadline = ContinuousClock.now + .seconds(3)
            while providers.isChecking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(providers.available.contains(.codex))
        }
        func prepare() async throws -> TodoAutomationService.FeedbackPreparationOutcome {
            try await service.prepareFeedback(work: .init(host: Self.host, projectID: 1, iid: 2), noteIDs: [20], username: "me",
                settings: settings, glab: glab, manual: false, verifiedFingerprint: fingerprint,
                expectedHeadSHA: request.sha, shouldProceed: { true })
        }
        func runVerified(manual: Bool = false) async {
            await monitor.runVerifiedAuthorFeedback(request: request, noteIDs: [20], fingerprint: fingerprint, manual: manual)
        }
        func waitFor(_ flag: String) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !gitlab.has(flag), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(gitlab.has(flag))
        }
        func cleanup() {
            monitor.stopTimer()
            gitlab.close()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
