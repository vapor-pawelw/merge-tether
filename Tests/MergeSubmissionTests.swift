import Foundation
import Testing
@testable import GitLabTodos

@MainActor struct MergeSubmissionTests {
    @Test(arguments: [false, true])
    func corruptRequiredReceiptStoreDeniesManualMergeAndEnqueueAtTheWriteBoundary(_ train: Bool) async throws {
        try await fixture { glab, gitlab, request in
            let suite = "CorruptManualMergeReceipt.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let raw = Data("unsupported submission receipt".utf8)
            defaults.set(raw, forKey: "mergeSubmissions")
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            if !train { gitlab.write("ordinary-project") }
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab,
                canAutomate: { _ in true })
            monitor.setVisible(true)
            while monitor.isLoading { await Task.yield() }
            let ready = try #require(monitor.requests.first)
            #expect(ready.mayMergeManually)
            #expect(ready.action == (train ? .enqueue : .mergeNow))
            let outcome = await monitor.mergeManually(request)
            #expect(![MergeSubmissionState.merged, .queued, .inTrain].contains(outcome))
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(defaults.data(forKey: "mergeSubmissions") == raw)
        }
    }

    @Test(arguments: ["queued", "train", "merged"])
    func submitsThroughTheTrainAPIAndReportsOnlyTheObservedOutcome(_ response: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("outcome", response)
            let result = try await submit(glab, request: request)
            #expect(result == (response == "queued" ? .queued : response == "train" ? .inTrain : .merged))
            let writes = gitlab.requests.filter { $0.method != "GET" }
            #expect(writes.count == 1)
            #expect(writes.first?.endpoint == "/projects/1/merge_trains/merge_requests/2")
            #expect(writes.first?.command.contains("sha=" + request.sha!) == true)
            #expect(writes.first?.command.contains("auto_merge=true") == true)
        }
    }

    @Test(arguments: ["queued", "train"])
    func existingUserOwnedQueueIsReadOnly(_ state: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("observed", state)
            let result = try await submit(glab, request: request)
            #expect(result == (state == "train" ? .inTrain : .queued))
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["head", "target", "account", "policy", "settings", "dependencies", "drafts", "newFeedback"])
    func finalPreflightRejectsChangedContextWithoutAnyWrite(_ drift: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("drift", drift)
            do {
                _ = try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
                    expectedUser: user, expectedContext: .init(request), expectedDiscussionFingerprint: ReviewVerdict.fingerprint([]),
                    expectedSemanticContextFingerprint: request.semanticContextFingerprint,
                    action: .enqueue, expectedPolicy: policy, shouldProceed: { drift != "settings" })
                Issue.record("Changed context must not submit")
            } catch { }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func unconfirmedTrainResponseIsUncertainAndNeverRetried() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("outcome", "unknown")
            await #expect(throws: (any Error).self) { _ = try await submit(glab, request: request) }
            #expect(gitlab.requests.filter { $0.method != "GET" }.count == 1)
        }
    }

    @Test func aTrainRebaseConflictBlocksAMergeableSummaryBeforeAnyWrite() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("train-conflict")
            await #expect(throws: MergeTrainPreparationConflict.self) { _ = try await submit(glab, request: request) }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["source", "target", "ref", "newer-removal"])
    func staleOrUntrustedTrainFailuresDoNotBecomeCurrentConflicts(_ mismatch: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("train-conflict", mismatch)
            gitlab.write("outcome", "train")
            let outcome = try await submit(glab, request: request)
            #expect(outcome == .inTrain)
            #expect(gitlab.requests.filter { $0.method != "GET" }.count == 1)
        }
    }

    @Test func aUserCommentCannotForgeTheSystemTrainFailure() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("train-conflict", "comment")
            let conflict = try await glab.fetchMergeTrainPreparationConflict(request, host: host)
            #expect(conflict == nil)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["queued", "train"])
    func anActiveQueueTakesPrecedenceOverHistoricalTrainFailure(_ state: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("train-conflict")
            gitlab.write("observed", state)
            let outcome = try await submit(glab, request: request)
            #expect(outcome == (state == "train" ? .inTrain : .queued))
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func aTrainFailureArrivingDuringDependencyChecksStopsTheFinalWrite() async throws {
        try await fixture { glab, gitlab, request in
            let handler = try #require(gitlab.handler)
            gitlab.handler = { call in
                if call.endpoint.contains("/blocks?") { gitlab.write("train-conflict") }
                return try await handler(call)
            }
            await #expect(throws: MergeTrainPreparationConflict.self) { _ = try await submit(glab, request: request) }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func aTrainRejectedBeforeThePostconditionReportsItsCauseWithoutReplaying() async throws {
        try await fixture { glab, gitlab, request in
            let handler = try #require(gitlab.handler)
            gitlab.handler = { call in
                if call.method != "GET" { gitlab.write("train-conflict") }
                return try await handler(call)
            }
            do {
                _ = try await submit(glab, request: request)
                Issue.record("A removed train must not be reported as accepted")
            } catch let conflict as MergeTrainPreparationConflict {
                #expect(conflict.sourceSHA == request.sha)
                #expect(conflict.targetSHA == String(repeating: "b", count: 40))
                #expect(conflict.noteID == 10)
            }
            #expect(gitlab.requests.filter { $0.method != "GET" }.count == 1)
        }
    }

    @Test func immediateRejectionPreservesTheAttemptAndItsNewerServerProof() async throws {
        try await fixture { glab, gitlab, request in
            // given
            let suite = "ImmediateTrainRejection.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.setVisible(true)
            while monitor.isLoading { await Task.yield() }
            let handler = try #require(gitlab.handler)
            gitlab.handler = { call in
                if call.method != "GET" { gitlab.write("train-conflict") }
                return try await handler(call)
            }

            // when
            #expect(await monitor.mergeManually(request) == .changed)
            while monitor.isLoading { await Task.yield() }

            // then
            let receipt = try #require(settings.mergeSubmissions.first)
            #expect(receipt.state == .uncertain)
            #expect(receipt.trainNoteIDBeforeAttempt == 0)
            #expect(receipt.confirmedTrainRejection?.noteID == 10)
            #expect(monitor.requests.first?.request.mergeTrainConflict?.noteID == 10)
            #expect(await monitor.mergeManually(request) == .uncertain)
            #expect(gitlab.requests.filter { $0.method != "GET" }.count == 1)
        }
    }

    @Test(arguments: [9, 10, 11])
    func onlyARejectionNewerThanTheSavedBaselineCanReleaseANewSource(_ noteID: Int) async throws {
        try await fixture { _, _, request in
            let suite = "TrainProofBaseline.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var receipt = MergeSubmissionReceipt(target: .init(host: host, username: user.username, projectID: 1, iid: 2),
                userID: user.id, context: .init(request), semanticFingerprint: request.semanticContextFingerprint,
                discussionFingerprint: ReviewVerdict.fingerprint([])!, configuration: .init(SettingsManager(defaults: defaults)),
                action: .enqueue, createdAt: Date())
            receipt.trainNoteIDBeforeAttempt = 10
            receipt.confirmedTrainRejection = .init(context: .init(request), noteID: noteID,
                sourceSHA: request.sha!, targetSHA: String(repeating: "b", count: 40))
            let encoded = try JSONEncoder().encode(request)
            var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            fields["sha"] = String(repeating: "c", count: 40)
            let repaired = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
            #expect(receipt.mayReconsiderAfterTrainRepair(repaired) == (noteID > 10))
            #expect(!receipt.mayReconsiderAfterTrainRepair(request))
        }
    }

    @Test func aTrainRebaseConflictIsVisibleAndSchedulesOneSeparatelyAuthorizedRepair() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "TrainRebaseConflict.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.packageDecision = .enabled
            settings.automation.conflictTasksEnabled = true
            gitlab.write("train-conflict")
            var prompts: [String] = []
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true },
                conflictLauncher: { input, _ in
                    prompts.append(input.prompt)
                    return .init(id: UUID(), key: .init(assistant: input.assistant, work: input.work,
                        username: input.username, workspace: "", access: input.access), title: input.title,
                        prompt: input.prompt, createdAt: Date(), allowsPush: input.allowsPush, expectedHeadSHA: input.head)
                })
            monitor.setVisible(true)
            while monitor.isLoading { await Task.yield() }
            let deadline = ContinuousClock.now + .seconds(3)
            while prompts.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            try #require(!prompts.isEmpty)
            let status = try #require(monitor.requests.first)
            #expect(status.request.hasMergeConflict)
            #expect(status.blockers.contains(.conflicts))
            #expect(!status.mayMergeManually && !status.mayAutoMerge)
            #expect(prompts.first?.contains("merge train") == true)
            #expect(prompts.first?.contains("has_conflicts=false") == true)
            #expect(prompts.first?.contains("Before any push, repeat") == true)
            #expect(prompts.first?.contains("After an authorized normal push") == true)
            #expect(prompts.first?.contains("A clean final-tree merge alone is not proof") == true)
            #expect(prompts.first?.contains("Leave force-pushes") == true)
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(prompts.count == 1)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: [false, true])
    func onlyAConfirmedRejectionAllowsANewHeadToLeaveAnUncertainAttempt(_ hasBaseline: Bool) async throws {
        try await fixture { glab, gitlab, request in
            // given
            let suite = "TrainRejectionRecovery.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.packageDecision = .enabled
            settings.automation.conflictTasksEnabled = true
            var receipt = MergeSubmissionReceipt(target: .init(host: host, username: user.username, projectID: 1, iid: 2),
                userID: user.id, context: .init(request), semanticFingerprint: request.semanticContextFingerprint,
                discussionFingerprint: ReviewVerdict.fingerprint([])!, configuration: .init(settings), action: .enqueue, createdAt: Date())
            receipt.trainNoteIDBeforeAttempt = hasBaseline ? 0 : nil
            #expect(settings.saveMergeSubmission(receipt))
            gitlab.write("train-conflict")
            var launches = 0
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true },
                conflictLauncher: { input, _ in
                    launches += 1
                    return .init(id: UUID(), key: .init(assistant: input.assistant, work: input.work,
                        username: input.username, workspace: "", access: input.access), title: input.title,
                        prompt: input.prompt, createdAt: Date(), allowsPush: input.allowsPush, expectedHeadSHA: input.head)
                })

            // when
            monitor.setVisible(true)
            while monitor.isLoading { await Task.yield() }
            let deadline = ContinuousClock.now + .seconds(3)
            while launches == 0, ContinuousClock.now < deadline { await Task.yield() }
            try #require(launches == 1)
            let rejected = try #require(monitor.requests.first)

            // then
            #expect(rejected.submissionState == .uncertain)
            #expect(rejected.request.mergeTrainConflict != nil)
            #expect((settings.mergeSubmissions.first?.confirmedTrainRejection != nil) == hasBaseline)
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.mergeSubmissions.first?.trainNoteIDBeforeAttempt == (hasBaseline ? 0 : nil))
            #expect((restored.mergeSubmissions.first?.confirmedTrainRejection != nil) == hasBaseline)
            #expect(await monitor.mergeManually(request) == .uncertain)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            gitlab.write("current-head", String(repeating: "c", count: 40))
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            let repaired = try #require(monitor.requests.first)
            #expect(repaired.submissionState == (hasBaseline ? .none : .uncertain))
            #expect(repaired.blockers.isEmpty)
            #expect(repaired.mayMergeManually == hasBaseline)
            #expect(launches == 1)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["account", "target-unavailable"])
    func trainEvidenceCannotAuthorizeAcrossASessionChangeOrMissingTarget(_ failure: String) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("train-conflict")
            let handler = try #require(gitlab.handler)
            gitlab.handler = { call in
                if call.endpoint == "/projects/1/repository/branches/main" {
                    if failure == "target-unavailable" { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                    glab.currentUsername = "other"; glab.currentUsername = "me"
                }
                return try await handler(call)
            }
            await #expect(throws: (any Error).self) { _ = try await submit(glab, request: request) }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["17.10.9-ee", "garbage"])
    func unsupportedServerNeverGuessesTheQueueAPI(_ version: String) async throws {
        try await fixture { glab, gitlab, _ in
            gitlab.write("version", version)
            let policy = try await glab.fetchMergeActionPolicy(projectID: 1, host: host)
            #expect(policy.action == nil)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func ordinaryProjectsCanSetAutoMergeWhileTheirKnownPipelineRuns() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("ordinary-project")
            gitlab.write("pipeline-running")
            gitlab.write("outcome", "queued")
            let policy = GitLabMergeActionPolicy(action: .enqueue, requiresResolvedDiscussions: true,
                resetsApprovalsOnPush: true, usesMergeTrain: false)
            let outcome = try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
                expectedUser: user, expectedContext: .init(request), action: .enqueue, expectedPolicy: policy, shouldProceed: { true })
            #expect(outcome == .queued)
            let write = try #require(gitlab.requests.first { $0.method != "GET" })
            #expect(write.endpoint == "/projects/1/merge_requests/2/merge" && write.method == "PUT")
            #expect(write.command.contains("auto_merge=true"))
        }
    }

    @Test func aUserOwnedQueueIsNotAutomaticallyReplacedAfterItDisappears() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "ObservedMergeQueue.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            gitlab.write("observed", "queued")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(monitor.requests.first?.submissionState == .queued)
            gitlab.remove("observed")
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(monitor.requests.first?.submissionState == .changed)
        }
    }

    @Test func aQueueCreatedDuringTheFinalPreflightRemainsUserOwnedAndCannotBeReplaced() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "MergeQueueRace.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.automation.packageDecision = .enabled
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            var injected = false
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in
                if !injected { injected = true; gitlab.write("observed", "queued") }
                return true
            })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(settings.mergeSubmissions.first?.origin == .observedQueue)
            gitlab.remove("observed")
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test func aSessionRoundTripDuringTheQueueReadCannotSaveAnObservationReceipt() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "MergeQueueSession.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            let transport = try #require(gitlab.handler)
            gitlab.handler = { call in
                if gitlab.has("observed"), call.endpoint.contains("/merge_trains?") {
                    glab.currentUsername = "other"; glab.currentUsername = "me"
                }
                return try await transport(call)
            }
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in
                gitlab.write("observed", "queued")
                return true
            })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(settings.mergeSubmissions.isEmpty)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: [false, true])
    func approvalResetPolicyUsesTheDedicatedEndpointAndPreservesUnavailable(_ unavailable: Bool) async throws {
        try await fixture { glab, gitlab, _ in
            gitlab.write("separate-approval-policy")
            if unavailable { gitlab.write("unavailable-approval-policy") }
            let policy = try await glab.fetchMergeActionPolicy(projectID: 1, host: host)
            #expect(policy.resetsApprovalsOnPush == (unavailable ? nil : true))
        }
    }

    @Test func persistedSubmissionContextUsesSettingsEqualityAcrossRestart() throws {
        let suite = "MergeSubmissionSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        for iid in [2, 3, 4] {
            let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: iid)
            settings.automation.scope.setEnabled(false, for: target)
            settings.autoMergeOptOuts.insert(target)
        }
        let before = MergeSubmissionConfiguration(settings)
        settings.save()
        let restored = SettingsManager(defaults: defaults)
        #expect(MergeSubmissionConfiguration(restored) == before)
        restored.automation.autoMergeEnabled.toggle()
        #expect(MergeSubmissionConfiguration(restored) != before)
    }

    private let host = "gitlab.example.test"
    private let user = GitLabAuthenticatedUser(id: 3, username: "me")
    private var policy: GitLabMergeActionPolicy { .init(action: .enqueue, requiresResolvedDiscussions: true, resetsApprovalsOnPush: true, usesMergeTrain: true) }
    private func submit(_ glab: GlabService, request: GitLabMergeRequest) async throws -> MergeSubmissionState {
        try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
            expectedUser: user, expectedContext: .init(request), expectedDiscussionFingerprint: ReviewVerdict.fingerprint([]),
            expectedSemanticContextFingerprint: request.semanticContextFingerprint, action: .enqueue, expectedPolicy: policy, shouldProceed: { true })
    }

    private func fixture(_ body: (GlabService, InMemoryGitLab, GitLabMergeRequest) async throws -> Void) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"blocking_discussions_resolved":true,"user":{"can_merge":true}}"#
        gitlab.write("request", raw)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        gitlab.handler = { call in
            let drift = gitlab.text("drift")
            let listed = gitlab.has("current-head")
                ? raw.replacingOccurrences(of: String(repeating: "a", count: 40), with: gitlab.text("current-head")) : raw
            switch call.endpoint {
            case "/user": return InMemoryGitLab.output(drift == "account" ? #"{"id":99,"username":"me"}"# : #"{"id":3,"username":"me"}"#)
            case "/version": return try InMemoryGitLab.json(["version": gitlab.has("version") ? gitlab.text("version") : "19.5.3-ee"])
            case "/projects/1":
                var project: [String: Any] = ["default_branch": "main", "merge_trains_enabled": drift != "policy" && !gitlab.has("ordinary-project"),
                    "only_allow_merge_if_all_discussions_are_resolved": true]
                if !gitlab.has("separate-approval-policy") { project["reset_approvals_on_push"] = true }
                return try InMemoryGitLab.json(project)
            case "/projects/1/approvals":
                return gitlab.has("unavailable-approval-policy") ? InMemoryGitLab.output(error: "403 Forbidden", code: 1)
                    : InMemoryGitLab.output(#"{"reset_approvals_on_push":true}"#)
            case let path where path.hasPrefix("/merge_requests?"): return InMemoryGitLab.output("[" + listed + "]")
            case let path where path.contains("/merge_trains?"):
                return InMemoryGitLab.output(gitlab.text("observed") == "train" ? #"[{"merge_request":{"project_id":1,"iid":2}}]"# : "[]")
            case "/projects/1/merge_requests/2":
                var object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                if gitlab.has("current-head") { object["sha"] = gitlab.text("current-head") }
                if gitlab.has("pipeline-running") {
                    object["detailed_merge_status"] = "ci_still_running"
                    object["head_pipeline"] = ["id": 4, "status": "running"]
                }
                if drift == "head" { object["sha"] = String(repeating: "b", count: 40) }
                if drift == "target" { object["target_branch"] = "parent" }
                if gitlab.text("observed") == "queued" || gitlab.text("observed") == "train" { object["merge_when_pipeline_succeeds"] = true }
                if gitlab.text("observed") == "merged" { object["state"] = "merged" }
                return try InMemoryGitLab.json(object)
            case let path where path.contains("/merge_requests?state=opened"): return InMemoryGitLab.output("[" + listed + "]")
            case let path where path.contains("/blocks?"):
                return InMemoryGitLab.output(drift == "dependencies" ? #"[{"blocking_merge_request":null}]"# : "[]")
            case let path where path.hasSuffix("/approval_state"): return InMemoryGitLab.output(#"{"rules":[{"approvals_required":2,"approved":true}]}"#)
            case let path where path.contains("/discussions?"):
                if gitlab.has("train-conflict") {
                    let mismatch = gitlab.text("train-conflict")
                    let source = String(repeating: mismatch == "source" ? "c" : "a", count: 40)
                    let target = String(repeating: mismatch == "target" ? "c" : "b", count: 40)
                    let ref = mismatch == "ref" ? "3" : "2"
                    var notes: [[String: Any]] = [["id": 10, "system": mismatch != "comment", "resolvable": false,
                        "body": "removed this merge request from the merge train because the merge train pipeline could not be prepared: failed to rebase \(source) on \(target) while preparing refs/merge-requests/\(ref)/train due to conflict. [Learn more](https://gitlab.example.test/help/ci/pipelines/merge_trains.md)"]]
                    if mismatch == "newer-removal" {
                        notes.append(["id": 11, "system": true, "resolvable": false,
                            "body": "removed this merge request from the merge train because the pipeline failed"])
                    }
                    return try InMemoryGitLab.json([["id": "train", "notes": notes]])
                }
                return InMemoryGitLab.output(drift == "newFeedback" ? #"[{"id":"new","notes":[{"id":10,"author":{"id":7},"system":false,"body":"New condition"}]}]"# : "[]")
            case "/projects/1/repository/branches/main":
                return try InMemoryGitLab.json(["commit": ["id": String(repeating: "b", count: 40)]])
            case "/projects/1/repository/branches/feature":
                return try InMemoryGitLab.json(["commit": ["id": String(repeating: "a", count: 40)]])
            case let path where path.contains("/diffs?"): return InMemoryGitLab.output("[]")
            case let path where path.contains("/draft_notes?"):
                return InMemoryGitLab.output(drift == "drafts" ? #"[{"id":10,"author_id":3,"note":"Reply"}]"# : "[]")
            case "/projects/1/merge_trains/merge_requests/2", "/projects/1/merge_requests/2/merge":
                gitlab.write("observed", gitlab.text("outcome"))
                return InMemoryGitLab.output("[]")
            default: return try gitlab.unexpected(call)
            }
        }
        try await body(gitlab.service(host: host, username: user.username), gitlab, request)
    }
}
