import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct NewReviewIntakeTests {
    private let host = "gitlab.example.test"
    private let todoJSON = #"[{"id":501,"action_name":"review_requested","target_type":"MergeRequest","target_url":"https://gitlab.example.test/group/repo/-/merge_requests/42","body":"Review please","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"bob","name":"Bob"},"target":{"id":42,"iid":42,"title":"Add feature","state":"opened","author":{"id":9,"username":"bob","name":"Bob"}}}]"#
    private let mergeRequestJSON = #"{"id":4200,"project_id":1,"iid":42,"title":"Add feature","state":"opened","draft":false,"sha":"0123456789abcdef0123456789abcdef01234567","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/42","source_branch":"feature","target_branch":"main","labels":[],"author":{"id":9,"username":"bob","name":"Bob"}}"#
    private var target: MRAutomationScope.Target { .init(host: host, username: "alice", projectID: 1, iid: 42) }

    private func fixture(preset: AutomationPreset, addDirectly: Bool = true,
                         body: (TodoMonitorService, SettingsManager) async throws -> Void) async throws {
        let name = "NewReviewIntakeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(preset, for: .codex)
        settings.addNewReviewsToReviewed = addDirectly
        settings.save()
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.write("todos", todoJSON)
        gitlab.handler = { [mergeRequestJSON] request in
            if request.arguments.first == "config" { return InMemoryGitLab.output(host) }
            if request.arguments.first == "auth" { return InMemoryGitLab.output(error: "Logged in to \(host) as alice") }
            if request.arguments.contains(where: { $0.hasPrefix("/todos?") }) { return try gitlab.response("todos") }
            if !addDirectly, request.endpoint.hasPrefix("/merge_requests?scope=all&state=opened&reviewer_id=7") {
                return InMemoryGitLab.output("[\(mergeRequestJSON)]")
            }
            if request.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"alice"}"#) }
            if request.endpoint == "/projects/1/merge_requests/42" { return InMemoryGitLab.output(mergeRequestJSON) }
            if request.method == "POST" { return InMemoryGitLab.output("{}") }
            return InMemoryGitLab.output("[]")
        }
        let glab = gitlab.service(host: host, username: "alice")
        settings.glabPath = glab.glabPath
        settings.resolvedHost = host
        settings.onboardingCompleted = false
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            notifications: NotificationService(authorization: { .denied }, post: { _ in }))
        defer { monitor.stopTimer() }
        await monitor.bootstrap()
        if !addDirectly {
            // This fixture keeps onboarding off to avoid the periodic timer. Explicitly
            // load the assignment catalog before exercising the Inbox preference.
            await monitor.refreshNow()
            monitor.attention.refresh(host: host, username: "alice", todos: monitor.visibleTodos)
            await monitor.refreshManually()
            try #require(settings.reviewAssignments.entries(host: host, username: "alice")?.map(\.request.iid) == [42])
        }
        try await body(monitor, settings)
    }

    @Test(arguments: [AutomationPreset.manual, .safe])
    func newReviewWaitsInReviewingUntilTheUserStartsIt(preset: AutomationPreset) async throws {
        try await fixture(preset: preset) { monitor, settings in
            settings.automation.startNewReviewsAutomatically = false
            await monitor.refreshNow()
            #expect(settings.automation.scope.isManaged(target))
            #expect(settings.newReviewTargets.contains(target))
            #expect(settings.automation.scope[target] == .paused && settings.heldNewReviewTargets.contains(target))
            #expect(monitor.otherTodos.isEmpty && settings.mrActionIntents.isEmpty)
            monitor.releaseNewReview(target)
            #expect(settings.automation.scope[target] == .inherit && !settings.newReviewTargets.contains(target))
            #expect(settings.heldNewReviewTargets.isEmpty)
        }
    }

    @Test func profilesThatStartNewReviewsKeepTheMergeRequestActive() async throws {
        try await fixture(preset: .trusted) { monitor, settings in
            await monitor.refreshNow()
            #expect(settings.newReviewTargets.contains(target))
            #expect(settings.automation.scope[target] == .inherit && settings.heldNewReviewTargets.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func phoneSharesTheNewBadgeAndCanAcknowledgeTheSameAssignment(confirmedAssignment: Bool) async throws {
        try await fixture(preset: .manual) { monitor, settings in
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(mergeRequestJSON.utf8))
            settings.mrLifecycleLedger.record(request, for: target)
            settings.automation.startNewReviewsAutomatically = false
            monitor.trackReviewCandidate(target, projectPath: request.webURL.gitLabProjectPath, markNew: !confirmedAssignment)
            if confirmedAssignment {
                settings.reviewAssignments.observe([], host: host, username: "alice", at: Date())
                settings.reviewAssignments.observe([request], host: host, username: "alice", at: Date())
            }
            let session = UUID()
            let account = "alice@\(host)"
            func phoneBoard(_ supportsReviewBoard: Bool = true) -> RemoteBoard {
                RemoteBoardAdapter.board(monitor: monitor, session: session, account: account,
                    includesReviewBoard: supportsReviewBoard)
            }
            let legacy = try #require(phoneBoard(false).cards.first { $0.id == "mr:1:42" })
            #expect(legacy.boardTraits == nil)
            #expect(legacy.actions.allSatisfy { $0.id != RemoteAction.reviewSeenID })
            let board = phoneBoard()
            let card = try #require(board.cards.first { $0.id == "mr:1:42" })
            #expect(card.boardTraits?.isNew == true)
            let seen = try #require(card.actions.first { $0.id == RemoteAction.reviewSeenID })
            #expect(RemoteBoardAdapter.acknowledgeReviewAssignment(card, action: seen, monitor: monitor, account: "other@\(host)") == .changed)
            #expect(phoneBoard().cards.first { $0.id == card.id }?.boardTraits?.isNew == true)
            #expect(RemoteBoardAdapter.acknowledgeReviewAssignment(card, action: seen, monitor: monitor, account: account) == .completed)
            #expect(!settings.newReviewTargets.contains(target))
            #expect(settings.heldNewReviewTargets.contains(target))
            #expect(phoneBoard().cards.first { $0.id == card.id }?.boardTraits?.isNew == false)
            #expect(RemoteBoardAdapter.acknowledgeReviewAssignment(card, action: seen, monitor: monitor, account: account) == .changed)
            if !confirmedAssignment {
                monitor.trackReviewCandidate(target, projectPath: request.webURL.gitLabProjectPath, markNew: true)
                #expect(phoneBoard().cards.first { $0.id == card.id }?.boardTraits?.isNew == true)
                #expect(RemoteBoardAdapter.acknowledgeReviewAssignment(card, action: seen, monitor: monitor, account: account) == .changed)
            }
        }
    }

    @Test func knownFinishedHiddenReviewsDoNotAppearInTheRestoreList() async throws {
        try await fixture(preset: .manual) { monitor, settings in
            await monitor.refreshNow()
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(mergeRequestJSON.utf8))
            try #require(settings.hideReviewedMergeRequest(.init(target: target, title: request.title, url: request.webURL)))
            settings.mrLifecycleLedger.record(request, for: target)
            #expect(monitor.hiddenReviewAssignments.map(\.target) == [target])

            let closedJSON = mergeRequestJSON.replacingOccurrences(of: #""state":"opened""#, with: #""state":"closed""#)
            let closed = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(closedJSON.utf8))
            settings.mrLifecycleLedger.record(closed, for: target)
            #expect(monitor.hiddenReviewAssignments.isEmpty)
        }
    }

    @Test func disablingDirectAddingKeepsTheCandidateInTheInbox() async throws {
        try await fixture(preset: .trusted, addDirectly: false) { monitor, settings in
            await monitor.refreshNow()
            #expect(!settings.automation.scope.isManaged(target) && settings.newReviewTargets.isEmpty)
            #expect(monitor.boardSnapshot.reviewed.isEmpty)
            #expect(monitor.boardSnapshot.proposals.map(\.target) == [target])
        }
    }

    @Test func addingFromTheInboxTracksWithoutNewMarkOrWork() async throws {
        try await fixture(preset: .manual, addDirectly: false) { monitor, settings in
            await monitor.refreshNow()
            let proposal = try #require(monitor.boardSnapshot.proposals.first)
            await monitor.addReviewCandidate(proposal)
            #expect(settings.automation.scope.isManaged(target) && settings.newReviewTargets.isEmpty)
            #expect(settings.automation.scope[target] == .paused && settings.mrActionIntents.isEmpty)
            #expect(monitor.boardSnapshot.reviewed.map(\.id.iid) == [42])
        }
    }

    @Test(arguments: [AutomationPreset.manual, .safe, .trusted])
    func inboxOffersAddAndHandleOnlyWhenAutomationWouldTakeTheReviewOver(preset: AutomationPreset) async throws {
        try await fixture(preset: preset, addDirectly: false) { monitor, settings in
            #expect(monitor.automationHandlesNewReview(projectPath: "group/repo") == (preset != .manual))
            settings.automation.startNewReviewsAutomatically = false
            #expect(!monitor.automationHandlesNewReview(projectPath: "group/repo"))
        }
    }

    @Test(arguments: [AutomationPreset.safe, .trusted, .full])
    func profilesStartNewReviewsAutomaticallyExceptManual(preset: AutomationPreset) throws {
        var configuration = AutomationSettings()
        configuration.applyPreset(preset, for: .codex)
        #expect(configuration.startNewReviewsAutomatically && configuration.matchingPreset == preset)
        configuration.startNewReviewsAutomatically = false
        #expect(configuration.matchingPreset == nil)
        configuration.applyPreset(.manual, for: .codex)
        #expect(!configuration.startNewReviewsAutomatically)
    }

    @Test func legacySettingsInheritTheProfileDefault() throws {
        let enabled = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"packageDecision":"enabled","baselinePreset":"safe"}"#.utf8))
        let disabled = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"packageDecision":"disabled","baselinePreset":"manual"}"#.utf8))
        #expect(enabled.startNewReviewsAutomatically && !disabled.startNewReviewsAutomatically)
        let confirmation = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"packageDecision":"enabled","requireReviewStartConfirmation":true}"#.utf8))
        #expect(!confirmation.startNewReviewsAutomatically)
        let saved = try JSONEncoder().encode(confirmation)
        let settings = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(settings["startNewReviewsAutomatically"] as? Bool == false)
        #expect(settings["requireReviewStartConfirmation"] == nil)
        let roundTrip = try JSONDecoder().decode(AutomationSettings.self, from: saved)
        #expect(roundTrip.requireReviewStartConfirmation)

        let profile = AutomationProfileSnapshot(confirmation)
        let profileJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        #expect(profileJSON["startNewReviews"] as? Bool == false)
        #expect(profileJSON["reviewStartConfirmation"] == nil)

        var legacyProfile = profileJSON
        legacyProfile.removeValue(forKey: "startNewReviews")
        legacyProfile["reviewStartConfirmation"] = true
        let storedProfile = try JSONDecoder().decode(AutomationProfileSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyProfile))
        var restored = enabled
        storedProfile.normalizingReviewStart().apply(to: &restored)
        #expect(!restored.startNewReviewsAutomatically)
    }
}
