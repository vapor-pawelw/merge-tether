import Foundation
import Testing
@testable import GitLabTodos

struct AuthoredMergeRequestStatusTests {
    @Test func skippedDependencyChecksDoNotInventWarningsOrPermitSubmission() throws {
        let request = try makeRequest(mergeStatus: "not_approved")
        let state = try approvals(required: 2, approved: false)
        let status = AuthoredMergeRequestStatus(request: request, approvals: state, discussionsResolved: false,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true, dependencyReadiness: .notChecked)
        #expect(status.blockers.contains(.approvals) && status.blockers.contains(.discussions))
        #expect(!status.blockers.contains(.dependencyEvidence))
        #expect(status.dependencyReadiness.holdReason == nil)
        #expect(!status.mayAutoMerge && !status.mayMergeManually)
    }

    @Test func otherwiseReadyMergeStillRequiresCheckedDependencyEvidence() throws {
        let request = try makeRequest()
        let state = try approvals(required: 2, approved: true)
        let status = AuthoredMergeRequestStatus(request: request, approvals: state, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true, dependencyReadiness: .notChecked)
        #expect(status.blockers.isEmpty && status.dependencyReadiness.holdReason == nil)
        #expect(!status.mayAutoMerge && !status.mayMergeManually)
    }

    @Test(arguments: [0, 1, 3, nil])
    func draftsOrUnknownDraftsBlockMergeReadiness(count: Int?) throws {
        let request = try makeRequest()
        let approvals = try approvals(required: 2, approved: true)
        let status = AuthoredMergeRequestStatus(request: request, approvals: approvals, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true, dependencyReadiness: .ready, pendingDraftCount: count)
        #expect(status.mayAutoMerge == (count == 0))
        #expect(status.blockers.contains(.unpublishedDrafts) == (count.map { $0 > 0 } == true))
        #expect(status.blockers.contains(.unknown) == (count == nil))
    }

    @Test func anUnfinishedCommentReviewBlocksMergeWithoutDrafts() throws {
        let request = try makeRequest()
        let approvals = try approvals(required: 2, approved: true)
        let status = AuthoredMergeRequestStatus(request: request, approvals: approvals, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true, dependencyReadiness: .ready, pendingDraftCount: 0, requiresCommentReview: true)
        #expect(!status.mayAutoMerge)
        #expect(status.blockers.contains(.commentReview))
    }

    @Test func ordersReadyThenActionableThenWaitingAndDrafts() throws {
        let approved = try approvals(required: 2, approved: true)
        let unapproved = try approvals(required: 2, approved: false)
        let draft = status(try makeRequest(mergeStatus: "draft_status", iid: 1), approved, resolved: false, policy: true)
        let waiting = status(try makeRequest(mergeStatus: "ci_still_running", iid: 2), approved, resolved: true, policy: true)
        let multiple = status(try makeRequest(mergeStatus: "not_approved", hasConflicts: true, iid: 3),
                              unapproved, resolved: false, policy: true)
        let one = status(try makeRequest(mergeStatus: "discussions_not_resolved", iid: 4), approved, resolved: false, policy: true)
        let ready = status(try makeRequest(iid: 5), approved, resolved: true, policy: true)
        let manualMerge = status(try makeRequest(iid: 6), approved, resolved: true, policy: false)

        let sorted = AuthoredMergeRequestStatus.orderedForMerge([draft, waiting, multiple, one, manualMerge, ready])
        #expect(sorted.map(\.request.iid) == [5, 6, 4, 3, 2, 1])
    }

    @Test func automaticMergeRequiresVerifiedApprovalRulesAndDiscussionEnforcement() throws {
        let request = try makeRequest()
        let approved = try approvals(required: 2, approved: true)
        let optional = try approvals(required: 0, approved: true)
        let unapproved = try approvals(required: 2, approved: false)

        #expect(status(request, approved, resolved: true, policy: true).mayAutoMerge)
        #expect(!status(request, approved, resolved: false, policy: true).mayAutoMerge)
        #expect(status(request, approved, resolved: false, policy: true).blockers.contains(.discussions))
        #expect(!status(request, approved, resolved: nil, policy: true).mayAutoMerge)
        #expect(!status(request, approved, resolved: true, policy: false).mayAutoMerge)
        #expect(!status(request, optional, resolved: true, policy: true).mayAutoMerge)
        #expect(!status(request, unapproved, resolved: true, policy: true).mayAutoMerge)
    }

    @Test func honorsGitLabMergeabilityAndShowsIndependentBlockers() throws {
        let approvals = try approvals(required: 2, approved: false)
        let conflict = try makeRequest(mergeStatus: "not_approved", hasConflicts: true)
        let view = status(conflict, approvals, resolved: false, policy: true)
        #expect(view.blockers.contains(.conflicts))
        #expect(view.blockers.contains(.approvals))
        #expect(view.blockers.contains(.discussions))

        let pipeline = try makeRequest(mergeStatus: "ci_still_running")
        #expect(status(pipeline, approvals, resolved: true, policy: true).blockers.contains(.pipeline))
        let unknown = try makeRequest(mergeStatus: "new_server_policy")
        #expect(!status(unknown, approvals, resolved: true, policy: true).mayAutoMerge)
    }

    @Test func migratesExistingRulesAndWorkspaceToSharedAssistant() throws {
        let data = Data("""
            {"codexWorkspace":"/tmp/project","reviewRequested":{
                "isEnabled":true,"runner":"codex","command":"",
                "titleTemplate":"Custom","promptTemplate":"Custom prompt"
            }}
            """.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: data)
        #expect(settings.assistant == .codex)
        #expect(settings.assistantWorkspace == "/tmp/project")
        #expect(settings.reviewRequested.runner == .assistant)
        #expect(settings.reviewRequested.isEnabled)
        #expect(settings.reviewRequested.titleTemplate == "Custom")
        #expect(!settings.autoMergeEnabled)
        #expect(!settings.conflictTasksEnabled)
        #expect(settings.packageDecision == .undecided && !settings.hasEnabledAutomation)
        #expect(!settings.allowConflictPush)
    }

    @Test func redPipelineBlocksAutomationEvenWhenGitLabMarksTheMRMergeable() throws {
        let json = requestJSON().dropLast() + #", "head_pipeline":{"status":"failed"}}"#
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        let view = status(request, try approvals(required: 2, approved: true), resolved: true, policy: true)
        #expect(view.blockers.contains(.pipeline))
        #expect(!view.mayAutoMerge)
    }

    @Test func assistantChangesRequireAConfirmedApprovalResetPolicy() throws {
        let request = try makeRequest()
        let status = AuthoredMergeRequestStatus(
            request: request, approvals: try approvals(required: 2, approved: true), discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: true, dependencyReadiness: .ready, canVerifyFreshApprovals: false
        )
        #expect(status.blockers.contains(.approvalPolicy))
        #expect(!status.mayAutoMerge)
    }

    @MainActor
    @Test func attentionOrdersOpenWorkByMergeReadinessAndPutsDraftsLast() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let requests = [
            requestJSON(mergeStatus: "draft_status", iid: 1),
            requestJSON(mergeStatus: "not_approved", hasConflicts: true, iid: 2),
            requestJSON(iid: 3),
            requestJSON(mergeStatus: "discussions_not_resolved", iid: 4),
            requestJSON(mergeStatus: "mergeable", iid: 5)
        ]
        try Data("[\(requests.joined(separator: ","))]".utf8).write(to: folder.appending(path: "requests.json"))
        let executable = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            case "$2" in
                /user) echo '{"id":3,"username":"me"}' ;;
                /merge_requests?scope=created_by_me*) cat requests.json ;;
                /merge_requests?scope=all*) echo '[]' ;;
                */1/draft_notes*|*/3/draft_notes*|*/4/draft_notes*) echo '[{"author_id":3}]' ;;
                */draft_notes*) echo '[]' ;;
                */5/discussions*) echo '[{"notes":[{"id":7,"author":{"id":7},"system":false,"resolvable":true,"resolved":false}]}]' ;;
                */discussions*) echo '[]' ;;
                *) exit 100 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = "gitlab.example.org"
        glab.currentUsername = "me"
        let monitor = MergeRequestAttentionMonitor(glab: glab)
        monitor.refresh(host: "gitlab.example.org", username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!monitor.isLoading && !monitor.hasError)
        // Drafts without current completion evidence stay outside Ready. Within open
        // work, MR 3 is mergeable; MR 5's live discussion puts it beside MR 4.
        #expect(monitor.currentItems.map(\.id.iid) == [3, 4, 5, 2, 1])
        #expect(monitor.currentItems.map(\.section) == [.open, .open, .open, .open, .draftMergeRequests])
    }

    @MainActor
    @Test func rereviewWaitsForPublishedRepliesAndRequestsEachReviewerOnlyOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let suite = "ReReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }
        try write("request.json", requestJSON())
        let executable = folder.appending(path: "glab")
        try write("glab", """
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            case "$2" in
                /user) echo '{"id":3,"username":"me"}' ;;
                /users/7) echo '{"id":7,"username":"alice","bot":false,"state":"active"}' ;;
                /users/8) echo '{"id":8,"username":"bob","bot":false,"state":"active"}' ;;
                /merge_requests?scope=created_by_me*) printf '['; cat request.json; printf ']' ;;
                /merge_requests?scope=all*) echo '[]' ;;
                */reviewers*) echo '[{"user":{"id":7},"state":"reviewed"}]' ;;
                */approvals*) echo '{"approved_by":[]}' ;;
                */draft_notes*) cat drafts.json ;;
                */discussions*) cat discussions.json ;;
                /projects/1/merge_requests/2) cat request.json ;;
                graphql)
                    case "$*" in
                        *mergeRequestReviewerRereview*userId=gid://gitlab/User/7)
                            echo alice >> sent
                            echo '{"data":{"mergeRequestReviewerRereview":{"mergeRequest":{"iid":"2"},"errors":[]}}}' ;;
                        *mergeRequestSetReviewers*APPEND*username=bob)
                            echo bob >> sent
                            echo '{"data":{"mergeRequestSetReviewers":{"mergeRequest":{"iid":"2"},"errors":[]}}}' ;;
                        *) exit 101 ;;
                    esac ;;
                *) exit 100 ;;
            esac
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = .enabled
        settings.automation.autoReReviewEnabled = true
        settings.automation.autoVerifyReReview = false
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = "gitlab.example.org"
        glab.currentUsername = "me"
        let monitor = MergeRequestAttentionMonitor(glab: glab, settings: settings, reportDirectory: folder)
        func poll() async throws {
            monitor.refresh(host: "gitlab.example.org", username: "me", todos: [])
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isLoading && !monitor.hasError)
        }
        let discussion = """
            {"notes":[{"id":10,"author":{"id":7},"body":"First feedback","system":false},
            {"id":11,"author":{"id":8},"body":"Second feedback","system":false}]}
            """
        let sent = folder.appending(path: "sent")
        try write("drafts.json", #"[{"author_id":3}]"#)
        let answered = discussion.replacingOccurrences(of: "]}", with: #",{"id":12,"author":{"id":3},"body":"Verified fixes","system":false}]}"#)
        try write("discussions.json", "[\(answered)]")
        try await poll()
        #expect(monitor.currentItems.first?.draftCount == 1)
        #expect(!FileManager.default.fileExists(atPath: sent.path))
        try write("drafts.json", "[]")
        try write("discussions.json", "[\(discussion)]")
        try await poll()
        #expect(!FileManager.default.fileExists(atPath: sent.path))
        try write("discussions.json", "[\(answered)]")
        try await poll()
        await monitor.finishCommentReview(try #require(monitor.currentItems.first))
        try await poll()
        #expect(!FileManager.default.fileExists(atPath: sent.path))

        try write("drafts.json", #"[{"author_id":3}]"#)
        try write("discussions.json", "[\(discussion)]")
        try await poll()
        #expect(!FileManager.default.fileExists(atPath: sent.path))
        try write("drafts.json", "[]")
        try write("discussions.json", "[\(answered)]")
        try await poll()
        await monitor.finishCommentReview(try #require(monitor.currentItems.first))
        try await poll()
        #expect(!FileManager.default.fileExists(atPath: sent.path))
        let item = try #require(monitor.currentOpenItems.first)
        let fingerprint = try #require(item.reReviewFingerprint)
        await monitor.confirmReReview(item.id, head: try #require(item.mergeRequest?.sha), fingerprint: fingerprint)
        #expect(try String(contentsOf: sent, encoding: .utf8) == "alice\nbob\n")
        #expect(monitor.currentOpenItems.first?.id.iid == 2)
        #expect(monitor.currentOpenItems.first?.draftCount == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "mr-status.json").path))
    }

    @MainActor
    @Test func pollingWaitsForDiscussionsAndMergesOnlyTheVerifiedHead() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = requestJSON()
        try Data(request.utf8).write(to: folder.appending(path: "request.json"))
        let executable = folder.appending(path: "glab")
        try Data("""
            #!/bin/sh
            set -eu
            cd "$(dirname "$0")"
            test "$1" = api
            test "$3" = --hostname
            test "$4" = gitlab.example.org
            case "$2" in
                /user) echo '{"id":3,"username":"me"}' ;;
                /merge_requests\\?*) printf '['; cat request.json; printf ']' ;;
                /projects/1/merge_requests/2) cat request.json ;;
                /projects/1/merge_requests/2/approval_state)
                    echo '{"rules":[{"approvals_required":2,"approved":true}]}' ;;
                /projects/1/merge_requests/2/draft_notes\\?*) echo '[]' ;;
                /projects/1/merge_requests/2/discussions\\?*)
                    if [ -e resolve ]; then echo '[]'; else echo '[{"notes":[{"resolvable":true,"resolved":false}]}]'; fi ;;
                /projects/1/merge_requests\\?state=opened*) printf '['; cat request.json; printf ']' ;;
                /projects/1/merge_requests/2/blocks\\?*) echo '[]' ;;
                /projects/1) echo '{"default_branch":"main","merge_trains_enabled":false,"only_allow_merge_if_all_discussions_are_resolved":true}' ;;
                /projects/1/merge_requests/2/merge)
                    test "$*" = "api /projects/1/merge_requests/2/merge --hostname gitlab.example.org --method PUT --raw-field sha=0123456789012345678901234567890123456789"
                    touch merged
                    echo '{"project_id":1,"iid":2,"state":"merged"}' ;;
                *) exit 100 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let suite = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.packageDecision = .enabled
        settings.onboardingCompleted = true
        settings.notificationsEnabled = false
        settings.automation.autoMergeEnabled = true
        settings.automation.autoMergeProjects = "g/p"
        let glab = GlabService()
        glab.glabPath = executable
        glab.resolvedHost = "gitlab.example.org"
        glab.currentUsername = "me"
        @MainActor final class Availability { var ready = false }
        let availability = Availability()
        let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab,
                                                  canAutomate: { _ in availability.ready })
        let merged = folder.appending(path: "merged")

        try await refresh(monitor)
        #expect(monitor.requests.first?.blockers.contains(.discussions) == true)
        #expect(!FileManager.default.fileExists(atPath: merged.path))

        try Data().write(to: folder.appending(path: "resolve"))
        try await refresh(monitor)
        #expect(!FileManager.default.fileExists(atPath: merged.path))
        #expect(monitor.requests.count == 1)

        availability.ready = true
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex,
            work: .init(host: "gitlab.example.org", projectID: 1, iid: 2),
            username: "me", workspace: "", access: .gitLabRead)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review", prompt: "",
            createdAt: Date(), allowsPush: false, execution: .init(state: .running))
        settings.assistantHandoffs.append(job)
        try await refresh(monitor)
        #expect(!FileManager.default.fileExists(atPath: merged.path))
        #expect(monitor.requests.count == 1)

        settings.assistantHandoffs[0].execution?.state = .succeeded
        try await refresh(monitor)
        #expect(!monitor.hasError)
        #expect(monitor.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: merged.path))
    }

    @MainActor
    private func refresh(_ monitor: AuthoredMergeRequestMonitor) async throws {
        monitor.refreshIfNeeded()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while monitor.isLoading, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!monitor.isLoading)
    }

    private func status(
        _ request: GitLabMergeRequest, _ approvals: GitLabMergeRequestApprovalState,
        resolved: Bool?, policy: Bool?
    ) -> AuthoredMergeRequestStatus {
        AuthoredMergeRequestStatus(
            request: request, approvals: approvals, discussionsResolved: resolved,
            projectRequiresResolvedDiscussions: policy, autoMergeEnabled: true, dependencyReadiness: .ready
        )
    }

    private func makeRequest(mergeStatus: String = "mergeable", hasConflicts: Bool = false, iid: Int = 2) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON(
            mergeStatus: mergeStatus, hasConflicts: hasConflicts, iid: iid
        ).utf8))
    }

    private func requestJSON(mergeStatus: String = "mergeable", hasConflicts: Bool = false, iid: Int = 2) -> String {
        """
            {"id":\(iid),"project_id":1,"iid":\(iid),"author":{"id":3,"username":"me","name":"Me"},
             "title":"Fix","web_url":"https://gitlab.example.org/g/p/-/merge_requests/\(iid)",
             "state":"opened","draft":false,"sha":"0123456789012345678901234567890123456789",
             "source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main",
             "detailed_merge_status":"\(mergeStatus)","has_conflicts":\(hasConflicts),
             "labels":[],"user":{"can_merge":true},"blocking_discussions_resolved":true}
        """
    }

    private func approvals(required: Int, approved: Bool) throws -> GitLabMergeRequestApprovalState {
        try JSONDecoder().decode(GitLabMergeRequestApprovalState.self, from: Data("""
            {"rules":[{"approvals_required":\(required),"approved":\(approved)}]}
            """.utf8))
    }
}
