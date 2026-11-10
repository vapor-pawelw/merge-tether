import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AuthorFeedbackMergeTests {
    @Test(arguments: ["current", "restored", "wrongDecision", "missingIDs", "remainingInSameNote", "editedSource"])
    func onlyAnActivePreciseDecisionCanSatisfyTheSemanticFeedbackGate(_ scenario: String) throws {
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let body = "Please fix the regression and consider an optional later rollout approval."
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,"resolvable":true,"resolved":false,"body":"\#(scenario == "editedSource" ? "An edited requirement" : body)"}]}]"#.utf8))
        let decision = IgnoredFeedbackSuggestion(id: UUID(), target: target, sourceNoteID: 10, sourceAuthorID: 7,
            sourceBody: body, sourceRevision: UserAttentionSnapshot.digest("7\n" + body),
            concernSummary: "Decline only the optional rollout approval.", concernReason: "The verified regression correction remains required.", createdAt: Date())
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10,
            state: scenario == "remainingInSameNote" ? .blocking : .ignoredByUser,
            reason: scenario == "remainingInSameNote" ? "The regression is still unfixed." : "The code correction is verified; only the user-declined assumption remained.",
            ignoredDecisionIDs: scenario == "missingIDs" ? nil : [scenario == "wrongDecision" ? UUID() : decision.id])])

        #expect(assessment.hasNoRemainingAuthorWork(in: discussions, authorID: 3,
            ignoredSuggestions: scenario == "restored" ? [] : [decision]) == (scenario == "current"))
        #expect(AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment, authorID: 3,
            approvedReviewerIDs: [7], ignoredSuggestions: scenario == "restored" ? [] : [decision]).allSatisfy { !$0.canResolve })
    }

    @Test(arguments: ["missingProof", "eligible", "draft", "approval", "pipeline", "scope", "changedDiscussion"])
    func exactBlockedWorkProofLiftsOnlyItsOwnAutomaticMergeStop(_ gate: String) async throws {
        var settings: SettingsManager?
        try await withFixture(configure: { settings = $0 }) { monitor, gitlab, _ in
            let settings = try #require(settings)
            let file = "request.json"
            if gate == "draft" || gate == "pipeline" {
                let raw = gitlab.text(file)
                try raw.replacingOccurrences(of: gate == "draft" ? #""draft":false"# : #""has_conflicts":false"#,
                    with: gate == "draft" ? #""draft":true"# : #""has_conflicts":false,"head_pipeline":{"id":8,"sha":"0123456789012345678901234567890123456789","status":"failed"}"#)
                    .store(in: gitlab, as: file)
            }
            if gate == "approval" {
                gitlab.write("approval-state.json", #"{"rules":[{"approvals_required":1,"approved":false}]}"#)
            }
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: gitlab.data(file))
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: gitlab.data("discussions.json"))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.org", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Feedback", prompt: "Complete assigned feedback", createdAt: Date(), allowsPush: false,
                feedbackNoteIDs: [10], execution: .init(state: .blocked, finishedAt: Date(),
                    summary: "The assigned correction is complete.", blocker: "Later release confirmation is absent."),
                workflow: .followUp, expectedHeadSHA: request.sha)
            settings.assistantHandoffs = [job]
            var proof = AuthorFeedbackStatus(head: request.sha!, fingerprint: ReviewVerdict.fingerprint(discussions)!,
                semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete, addressedNoteIDs: [10])
            if gate != "missingProof" {
                proof.reconciledFollowUpJobIDs = [job.id]
                let context = try #require(AuthorFeedbackStatus.blockedContext(for: job))
                proof.reconciledBlockedContexts[job.id] = context
            }
            if gate == "scope" {
                settings.automation.scope.setEnabled(false,
                    for: .init(host: job.key.work.host, username: "me", projectID: 1, iid: 2))
            }
            if gate == "changedDiscussion" {
                let discussionFile = "discussions.json"
                try gitlab.text(discussionFile)
                    .replacingOccurrences(of: "regression test.", with: "regression test and another requirement.")
                    .store(in: gitlab, as: discussionFile)
            }
            monitor.authorFeedbackStatus = { _ in proof }
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            #expect(AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                currentRequest: request, feedbackStatus: proof, discussionFingerprint: proof.fingerprint) == (gate == "missingProof"))

            try await refresh(monitor)

            #expect(gitlab.has("merged") == (gate == "eligible"))
            #expect(settings.assistantHandoffs[0].execution?.state == .blocked)
        }
    }

    @Test func actualAutomaticMergeIsReportedOnlyWhileTheWriteIsInFlight() async throws {
        try await withFixture { monitor, gitlab, _ in
            let request = try JSONDecoder().decode(GitLabMergeRequest.self,
                from: gitlab.data("request.json"))
            try Data("yes".utf8).store(in: gitlab, as: "hold-merge")
            defer { try? Data("yes".utf8).store(in: gitlab, as: "release-merge") }
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            #expect(!monitor.isMerging(request))
            monitor.refreshIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while !gitlab.has("merge-started"),
                  monitor.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let duringWrite = monitor.isMerging(request)
            try Data("yes".utf8).store(in: gitlab, as: "release-merge")
            while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(gitlab.has("merged"))
            #expect(duringWrite && !monitor.isMerging(request))
        }
    }

    @Test func advanceApprovalWithGeneralConditionCannotMergeWithoutSemanticProof() async throws {
        try await withFixture { monitor, gitlab, _ in
            monitor.refreshIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(!monitor.isLoading)
            #expect(!monitor.hasError)
            #expect(!gitlab.has("merged"))
            #expect(monitor.requests.count == 1)
        }
    }

    @Test func semanticProofCanAuthorizeMergeOfTheVerifiedConversation() async throws {
        try await withFixture { monitor, gitlab, _ in
            var verified = false
            monitor.authorFeedbackAllowsMerge = { request, discussions, author in
                verified = request.iid == 2 && author == 3 && discussions.flatMap(\.notes).map(\.id) == [10]
                return verified
            }
            try await refresh(monitor)
            #expect(verified)
            #expect(!monitor.hasError)
            #expect(gitlab.has("merged"))
        }
    }

    @Test func rejectedSemanticProofKeepsTheMRPending() async throws {
        try await withFixture { monitor, gitlab, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in false }
            try await refresh(monitor)
            #expect(!monitor.hasError)
            #expect(!gitlab.has("merged"))
            #expect(monitor.requests.count == 1)
        }
    }

    enum Drift: String, CaseIterable, Sendable { case newComment, editedComment, unpublishedReply, changedHead, changedTitle, changedDescription }

    @Test(arguments: Drift.allCases)
    func finalMergeRecheckRejectsChangesAfterTheSemanticVerdict(_ drift: Drift) async throws {
        try await withFixture { monitor, gitlab, _ in
            var changed = false
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                do {
                    switch drift {
                    case .newComment:
                        let file = "discussions.json"
                        let body = gitlab.text(file)
                        let extra = #",{"id":"new-condition","notes":[{"id":11,"author":{"id":7,"username":"reviewer"},"body":"Please also document the fallback.","system":false,"resolvable":false}]}]"#
                        try (String(body.dropLast()) + extra).store(in: gitlab, as: file)
                    case .editedComment:
                        let file = "discussions.json"
                        let body = gitlab.text(file)
                        try body.replacingOccurrences(of: "regression test.", with: "regression test and documentation.")
                            .store(in: gitlab, as: file)
                    case .unpublishedReply:
                        try #"[{"id":20,"author_id":3,"note":"Pending response"}]"#
                            .store(in: gitlab, as: "drafts.json")
                    case .changedHead:
                        let file = "request.json"
                        let body = gitlab.text(file)
                        try body.replacingOccurrences(of: "0123456789012345678901234567890123456789",
                                                     with: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                            .store(in: gitlab, as: file)
                    case .changedTitle, .changedDescription:
                        let file = "request.json"
                        let body = gitlab.text(file)
                        try body.replacingOccurrences(of: "\"title\":\"Feature\"",
                            with: drift == .changedTitle ? "\"title\":\"Changed acceptance criteria\""
                                : "\"title\":\"Feature\",\"description\":\"Changed acceptance criteria\"")
                            .store(in: gitlab, as: file)
                    }
                    changed = true
                } catch { Issue.record(error) }
                return true
            }
            try await refresh(monitor)
            #expect(changed)
            #expect(!monitor.hasError)
            #expect(!gitlab.has("merged"))
            #expect(monitor.requests.count == 1)
        }
    }

    @Test func finalMergeRejectsDescriptionEditedDuringFinalAuthentication() async throws {
        try await withFixture { monitor, gitlab, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                do { try Data("yes".utf8).store(in: gitlab, as: "edit-description-during-auth") }
                catch { Issue.record(error) }
                return true
            }

            try await refresh(monitor)

            #expect(gitlab.has("description-edited-during-auth"))
            #expect(!gitlab.has("merged"))
            #expect(monitor.requests.count == 1)
        }
    }

    @Test(arguments: ["ready", "pipeline", "global", "scope", "discussion"])
    func restoringMergeAutoUsesFreshAutomaticGatesWithoutAnotherRefresh(_ gate: String) async throws {
        var state: SettingsManager?
        let target = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 1, iid: 2)
        try await withFixture(configure: { settings in
            state = settings
            settings.autoMergeOptOuts.insert(target)
        }) { monitor, gitlab, _ in
            let settings = try #require(state)
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            try await refresh(monitor)
            #expect(!gitlab.has("merged"))
            #expect(monitor.requests.first?.mayAutoMerge == true)
            settings.autoMergeOptOuts.remove(target)
            if gate == "global" { settings.automation.autoMergeEnabled = false }
            if gate == "scope" { settings.automation.scope.setManualChoice(.paused, for: target) }
            if gate == "discussion" { monitor.authorFeedbackAllowsMerge = { _, _, _ in false } }
            if gate == "pipeline" {
                let file = "request.json"
                try gitlab.text(file)
                    .replacingOccurrences(of: #""has_conflicts":false"#,
                        with: #""has_conflicts":false,"head_pipeline":{"id":8,"status":"running"}"#)
                    .store(in: gitlab, as: file)
            }
            settings.save()
            await monitor.resumeAutomaticMerge(for: target)
            #expect(gitlab.has("merged") == (gate == "ready"))
        }
    }

    @Test func mergeOptOutDuringFinalSemanticReadPreventsTheAutomaticWrite() async throws {
        var state: SettingsManager?
        try await withFixture(configure: { state = $0 }) { monitor, gitlab, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                state?.autoMergeOptOuts.insert(.init(host: "gitlab.example.org", username: "me", projectID: 1, iid: 2))
                return true
            }
            try await refresh(monitor)
            #expect(!gitlab.has("merged"))
        }
    }

    private func refresh(_ monitor: AuthoredMergeRequestMonitor) async throws {
        monitor.refreshIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!monitor.isLoading)
    }

    private func withFixture(configure: (SettingsManager) -> Void = { _ in },
                             _ body: (AuthoredMergeRequestMonitor, InMemoryGitLab, GlabService) async throws -> Void) async throws {
        let gitlab = InMemoryGitLab()
        let suite = "AuthorFeedbackMergeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { gitlab.close(); defaults.removePersistentDomain(forName: suite) }
        let request = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"labels":[],"title":"Feature","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"0123456789012345678901234567890123456789","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"user":{"can_merge":true}}"#
        gitlab.write("request.json", request)
        gitlab.write("discussions.json", #"[{"id":"general","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"body":"Approved in advance, but please add the missing regression test.","system":false,"resolvable":false}]}]"#)
        gitlab.write("drafts.json", "[]")
        gitlab.write("approval-state.json", #"{"rules":[{"approvals_required":1,"approved":true}]}"#)
        gitlab.handler = { call in
            switch call.endpoint {
            case "/user":
                if gitlab.has("edit-description-during-auth") {
                    gitlab.remove("edit-description-during-auth")
                    var object = try #require(JSONSerialization.jsonObject(with: gitlab.data("request.json")) as? [String: Any])
                    object["description"] = "Changed acceptance criteria during authentication"
                    try JSONSerialization.data(withJSONObject: object).store(in: gitlab, as: "request.json")
                    gitlab.write("description-edited-during-auth")
                }
                return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#)
            case let path where path.hasPrefix("/merge_requests?"):
                return InMemoryGitLab.output("[" + gitlab.text("request.json") + "]")
            case "/projects/1/merge_requests/2": return try gitlab.response("request.json")
            case let path where path.hasSuffix("/approval_state"): return try gitlab.response("approval-state.json")
            case let path where path.contains("/reviewers?"): return InMemoryGitLab.output(code: 100)
            case let path where path.contains("/discussions?"): return try gitlab.response("discussions.json")
            case let path where path.contains("/draft_notes?"): return try gitlab.response("drafts.json")
            case let path where path.hasPrefix("/projects/1/merge_requests?state=opened"):
                return InMemoryGitLab.output("[" + gitlab.text("request.json") + "]")
            case let path where path.contains("/blocks?"): return InMemoryGitLab.output("[]")
            case "/projects/1": return InMemoryGitLab.output(#"{"default_branch":"main","only_allow_merge_if_all_discussions_are_resolved":true,"reset_approvals_on_push":true}"#)
            case let path where path.hasSuffix("/merge"):
                gitlab.write("merge-started")
                try await gitlab.pause(ifPresent: "hold-merge", entered: "merge-started", until: "release-merge")
                gitlab.write("merged")
                return InMemoryGitLab.output(#"{"project_id":1,"iid":2,"state":"merged"}"#)
            default: return try gitlab.unexpected(call)
            }
        }
        let glab = gitlab.service(host: "gitlab.example.org", username: "me")
        let settings = SettingsManager(defaults: defaults)
        settings.onboardingCompleted = true; settings.notificationsEnabled = false
        settings.automation.autoMergeEnabled = true; settings.automation.autoMergeProjects = "g/p"
        configure(settings)
        let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: NotificationService(), canAutomate: { _ in true })
        let listed = try await glab.fetchAuthoredMergeRequests(host: "gitlab.example.org")
        try #require(listed.count == 1)
        _ = try await glab.fetchMergeRequest(projectID: 1, iid: 2, host: "gitlab.example.org")
        try await body(monitor, gitlab, glab)
    }
}
