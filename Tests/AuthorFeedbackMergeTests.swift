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
        try await withFixture(configure: { settings = $0 }) { monitor, folder, _ in
            let settings = try #require(settings)
            let file = folder.appending(path: "request.json")
            if gate == "draft" || gate == "pipeline" {
                let raw = try String(contentsOf: file, encoding: .utf8)
                try raw.replacingOccurrences(of: gate == "draft" ? #""draft":false"# : #""has_conflicts":false"#,
                    with: gate == "draft" ? #""draft":true"# : #""has_conflicts":false,"head_pipeline":{"id":8,"sha":"0123456789012345678901234567890123456789","status":"failed"}"#)
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            if gate == "approval" {
                let executable = folder.appending(path: "glab")
                try String(contentsOf: executable, encoding: .utf8)
                    .replacingOccurrences(of: #""approvals_required":1,"approved":true"#, with: #""approvals_required":1,"approved":false"#)
                    .write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(contentsOf: file))
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: Data(contentsOf: folder.appending(path: "discussions.json")))
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
                let discussionFile = folder.appending(path: "discussions.json")
                try String(contentsOf: discussionFile, encoding: .utf8)
                    .replacingOccurrences(of: "regression test.", with: "regression test and another requirement.")
                    .write(to: discussionFile, atomically: true, encoding: .utf8)
            }
            monitor.authorFeedbackStatus = { _ in proof }
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            #expect(AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                currentRequest: request, feedbackStatus: proof, discussionFingerprint: proof.fingerprint) == (gate == "missingProof"))

            try await refresh(monitor)

            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "merged").path) == (gate == "eligible"))
            #expect(settings.assistantHandoffs[0].execution?.state == .blocked)
        }
    }

    @Test func actualAutomaticMergeIsReportedOnlyWhileTheWriteIsInFlight() async throws {
        try await withFixture { monitor, folder, _ in
            let request = try JSONDecoder().decode(GitLabMergeRequest.self,
                from: Data(contentsOf: folder.appending(path: "request.json")))
            try Data("yes".utf8).write(to: folder.appending(path: "hold-merge"))
            defer { try? Data("yes".utf8).write(to: folder.appending(path: "release-merge")) }
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            #expect(!monitor.isMerging(request))
            monitor.refreshIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: folder.appending(path: "merge-started").path),
                  monitor.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let duringWrite = monitor.isMerging(request)
            try Data("yes".utf8).write(to: folder.appending(path: "release-merge"))
            while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
            #expect(duringWrite && !monitor.isMerging(request))
        }
    }

    @Test func advanceApprovalWithGeneralConditionCannotMergeWithoutSemanticProof() async throws {
        try await withFixture { monitor, folder, _ in
            monitor.refreshIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(!monitor.isLoading)
            #expect(!monitor.hasError)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
            #expect(monitor.requests.count == 1)
        }
    }

    @Test func semanticProofCanAuthorizeMergeOfTheVerifiedConversation() async throws {
        try await withFixture { monitor, folder, _ in
            var verified = false
            monitor.authorFeedbackAllowsMerge = { request, discussions, author in
                verified = request.iid == 2 && author == 3 && discussions.flatMap(\.notes).map(\.id) == [10]
                return verified
            }
            try await refresh(monitor)
            #expect(verified)
            #expect(!monitor.hasError)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
        }
    }

    @Test func rejectedSemanticProofKeepsTheMRPending() async throws {
        try await withFixture { monitor, folder, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in false }
            try await refresh(monitor)
            #expect(!monitor.hasError)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
            #expect(monitor.requests.count == 1)
        }
    }

    enum Drift: String, CaseIterable, Sendable { case newComment, editedComment, unpublishedReply, changedHead, changedTitle, changedDescription }

    @Test(arguments: Drift.allCases)
    func finalMergeRecheckRejectsChangesAfterTheSemanticVerdict(_ drift: Drift) async throws {
        try await withFixture { monitor, folder, _ in
            var changed = false
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                do {
                    switch drift {
                    case .newComment:
                        let file = folder.appending(path: "discussions.json")
                        let body = try String(contentsOf: file, encoding: .utf8)
                        let extra = #",{"id":"new-condition","notes":[{"id":11,"author":{"id":7,"username":"reviewer"},"body":"Please also document the fallback.","system":false,"resolvable":false}]}]"#
                        try (String(body.dropLast()) + extra).write(to: file, atomically: true, encoding: .utf8)
                    case .editedComment:
                        let file = folder.appending(path: "discussions.json")
                        let body = try String(contentsOf: file, encoding: .utf8)
                        try body.replacingOccurrences(of: "regression test.", with: "regression test and documentation.")
                            .write(to: file, atomically: true, encoding: .utf8)
                    case .unpublishedReply:
                        try #"[{"id":20,"author_id":3,"note":"Pending response"}]"#
                            .write(to: folder.appending(path: "drafts.json"), atomically: true, encoding: .utf8)
                    case .changedHead:
                        let file = folder.appending(path: "request.json")
                        let body = try String(contentsOf: file, encoding: .utf8)
                        try body.replacingOccurrences(of: "0123456789012345678901234567890123456789",
                                                     with: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                            .write(to: file, atomically: true, encoding: .utf8)
                    case .changedTitle, .changedDescription:
                        let file = folder.appending(path: "request.json")
                        let body = try String(contentsOf: file, encoding: .utf8)
                        try body.replacingOccurrences(of: "\"title\":\"Feature\"",
                            with: drift == .changedTitle ? "\"title\":\"Changed acceptance criteria\""
                                : "\"title\":\"Feature\",\"description\":\"Changed acceptance criteria\"")
                            .write(to: file, atomically: true, encoding: .utf8)
                    }
                    changed = true
                } catch { Issue.record(error) }
                return true
            }
            try await refresh(monitor)
            #expect(changed)
            #expect(!monitor.hasError)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
            #expect(monitor.requests.count == 1)
        }
    }

    @Test func finalMergeRejectsDescriptionEditedDuringFinalAuthentication() async throws {
        try await withFixture { monitor, folder, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                do { try Data("yes".utf8).write(to: folder.appending(path: "edit-description-during-auth")) }
                catch { Issue.record(error) }
                return true
            }

            try await refresh(monitor)

            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "description-edited-during-auth").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
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
        }) { monitor, folder, _ in
            let settings = try #require(state)
            monitor.authorFeedbackAllowsMerge = { _, _, _ in true }
            try await refresh(monitor)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
            #expect(monitor.requests.first?.mayAutoMerge == true)
            settings.autoMergeOptOuts.remove(target)
            if gate == "global" { settings.automation.autoMergeEnabled = false }
            if gate == "scope" { settings.automation.scope.setManualChoice(.paused, for: target) }
            if gate == "discussion" { monitor.authorFeedbackAllowsMerge = { _, _, _ in false } }
            if gate == "pipeline" {
                let file = folder.appending(path: "request.json")
                try String(contentsOf: file, encoding: .utf8)
                    .replacingOccurrences(of: #""has_conflicts":false"#,
                        with: #""has_conflicts":false,"head_pipeline":{"id":8,"status":"running"}"#)
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            settings.save()
            await monitor.resumeAutomaticMerge(for: target)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "merged").path) == (gate == "ready"))
        }
    }

    @Test func mergeOptOutDuringFinalSemanticReadPreventsTheAutomaticWrite() async throws {
        var state: SettingsManager?
        try await withFixture(configure: { state = $0 }) { monitor, folder, _ in
            monitor.authorFeedbackAllowsMerge = { _, _, _ in
                state?.autoMergeOptOuts.insert(.init(host: "gitlab.example.org", username: "me", projectID: 1, iid: 2))
                return true
            }
            try await refresh(monitor)
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "merged").path))
        }
    }

    private func refresh(_ monitor: AuthoredMergeRequestMonitor) async throws {
        monitor.refreshIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!monitor.isLoading)
    }

    private func withFixture(configure: (SettingsManager) -> Void = { _ in },
                             _ body: (AuthoredMergeRequestMonitor, URL, GlabService) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let suite = "AuthorFeedbackMergeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let request = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"labels":[],"title":"Feature","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"0123456789012345678901234567890123456789","source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"user":{"can_merge":true}}"#
        try Data(request.utf8).write(to: folder.appending(path: "request.json"))
        let discussions = #"[{"id":"general","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"body":"Approved in advance, but please add the missing regression test.","system":false,"resolvable":false}]}]"#
        try Data(discussions.utf8).write(to: folder.appending(path: "discussions.json"))
        try Data("[]".utf8).write(to: folder.appending(path: "drafts.json"))
        let executable = folder.appending(path: "glab")
        try Data("""
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        case "$2" in
          /user)
            if [ -f edit-description-during-auth ]; then
                rm edit-description-during-auth
                /usr/bin/python3 -c 'import json; p="request.json"; a=json.load(open(p)); a["description"]="Changed acceptance criteria during authentication"; json.dump(a,open(p,"w"))'
                touch description-edited-during-auth
            fi
            echo '{"id":3,"username":"me"}' ;;
          /merge_requests\\?*) printf '['; cat request.json; printf ']' ;;
          /projects/1/merge_requests/2) cat request.json ;;
          */approval_state) echo '{"rules":[{"approvals_required":1,"approved":true}]}' ;;
          */discussions\\?*) cat discussions.json ;;
          */draft_notes\\?*) cat drafts.json ;;
          /projects/1) echo '{"only_allow_merge_if_all_discussions_are_resolved":true,"reset_approvals_on_push":true}' ;;
          */merge)
            touch merge-started
            if [ -e hold-merge ]; then
                attempts=0
                while [ ! -e release-merge ] && [ "$attempts" -lt 200 ]; do
                    /bin/sleep 0.02
                    attempts=$((attempts + 1))
                done
            fi
            touch merged; echo '{"project_id":1,"iid":2,"state":"merged"}' ;;
          *) exit 100 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let glab = GlabService()
        glab.glabPath = executable; glab.resolvedHost = "gitlab.example.org"; glab.currentUsername = "me"
        let settings = SettingsManager(defaults: defaults)
        settings.onboardingCompleted = true; settings.notificationsEnabled = false
        settings.automation.autoMergeEnabled = true; settings.automation.autoMergeProjects = "g/p"
        configure(settings)
        let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: NotificationService(), canAutomate: { _ in true })
        let listed = try await glab.fetchAuthoredMergeRequests(host: "gitlab.example.org")
        try #require(listed.count == 1)
        _ = try await glab.fetchMergeRequest(projectID: 1, iid: 2, host: "gitlab.example.org")
        try await body(monitor, folder, glab)
    }
}
