import Foundation
import Testing
@testable import MergeTether

@MainActor struct MergeSubmissionTests {
    @Test(arguments: [false, true])
    func sameHeadPipelineTransitionRequiresAnotherConfirmation(_ initiallyRunning: Bool) async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("ordinary-project")
            if initiallyRunning { gitlab.write("pipeline-running") }
            let suite = "ManualMergeMode.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.setVisible(true)
            while monitor.isLoading { await Task.yield() }
            let confirmed = try #require(monitor.requests.first?.action)
            #expect(confirmed == (initiallyRunning ? .enqueue : .mergeNow))

            if initiallyRunning { gitlab.remove("pipeline-running") }
            else { gitlab.write("pipeline-running") }
            #expect(await monitor.mergeManually(request, action: confirmed) == .changed)
            #expect(monitor.requests.first?.action == (initiallyRunning ? .mergeNow : .enqueue))
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(settings.mergeSubmissions.isEmpty)
        }
    }

    @Test func pipelineCompletionDuringTheFinalReadCannotSubmitAnOrdinaryAutoMerge() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("ordinary-project")
            gitlab.write("pipeline-running")
            let handler = try #require(gitlab.handler)
            var detailReads = 0
            gitlab.handler = { call in
                if call.endpoint == "/projects/1/merge_requests/2" {
                    detailReads += 1
                    if detailReads == 2 { gitlab.remove("pipeline-running") }
                }
                return try await handler(call)
            }
            let queuePolicy = GitLabMergeActionPolicy(action: .enqueue, requiresResolvedDiscussions: true)

            await #expect(throws: CancellationError.self) {
                _ = try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
                    expectedUser: user, expectedContext: .init(request), action: .enqueue,
                    expectedPolicy: queuePolicy, beforeWrite: { _ in Issue.record("Stale queue reached the write boundary") },
                    shouldProceed: { true })
            }
            #expect(detailReads == 2)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

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
            let outcome = await monitor.mergeManually(request, action: train ? .enqueue : .mergeNow)
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

    @Test func omittedDiscussionExpectationAllowsSubmissionWithDifferentDiscussions() async throws {
        try await fixture { glab, gitlab, request in
            gitlab.write("drift", "newFeedback")
            gitlab.write("outcome", "train")
            let result = try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
                expectedUser: user, expectedContext: .init(request),
                expectedSemanticContextFingerprint: request.semanticContextFingerprint,
                action: .enqueue, expectedPolicy: policy, shouldProceed: { true })
            #expect(result == .inTrain)
            #expect(gitlab.requests.filter { $0.method != "GET" }.count == 1)
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
            #expect(await monitor.mergeManually(request, action: .enqueue) == .changed)
            while monitor.isLoading { await Task.yield() }

            // then
            let receipt = try #require(settings.mergeSubmissions.first)
            #expect(receipt.state == .uncertain)
            #expect(receipt.trainNoteIDBeforeAttempt == 0)
            #expect(receipt.confirmedTrainRejection?.noteID == 10)
            #expect(monitor.requests.first?.request.mergeTrainConflict?.noteID == 10)
            #expect(await monitor.mergeManually(request, action: .enqueue) == .uncertain)
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
            settings.automation.selectedAssistant = .codex
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
            settings.automation.selectedAssistant = .codex
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
            #expect(await monitor.mergeManually(request, action: .enqueue) == .uncertain)
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

    @Test(arguments: ["repaired", "rebuilt-train", "merged-result", "wrong-merge-parent", "stale-source-pipeline", "accepted-queue",
                      "same-head", "manual-removal", "canceled-train-pipeline", "unconfirmed", "wrong-head",
                      "already-queued", "queue-during-preflight", "queue-recheck-fails", "late-queue",
                      "queue-disappeared", "queue-in-summary", "same-head-requeued",
                      "concurrent-cancel", "late-cancel", "pipeline-restarted", "stale-live-branch",
                      "unreadable-history", "unapproved", "clock-skew", "manual"])
    func aFailedTrainPipelineReleasesOnlyAVerifiedReplacementRevision(_ scenario: String) async throws {
        try await fixture { glab, gitlab, request in
            let suite = "FailedTrainPipelineRecovery.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeEnabled = scenario != "manual"
            let oldHead = try #require(request.sha)
            let newHead = scenario == "same-head" ? oldHead : String(repeating: "c", count: 40)
            let attemptDate = Date(timeIntervalSince1970: 1_760_000_000)
            let previousState: MergeSubmissionState = switch scenario {
            case "unconfirmed": .uncertain
            case "accepted-queue": .queued
            default: .inTrain
            }
            let receipt = MergeSubmissionReceipt(target: .init(host: host, username: user.username, projectID: 1, iid: 2),
                userID: user.id, context: .init(request), semanticFingerprint: request.semanticContextFingerprint,
                discussionFingerprint: ReviewVerdict.fingerprint([]), configuration: .init(settings),
                action: .enqueue, state: previousState,
                createdAt: scenario == "clock-skew" ? attemptDate.addingTimeInterval(300) : attemptDate,
                trainNoteIDBeforeAttempt: 5)
            try #require(settings.saveMergeSubmission(receipt))
            gitlab.write("current-head", scenario == "same-head-requeued" ? oldHead : newHead)
            gitlab.write("outcome", "train-only")
            if ["already-queued", "queue-disappeared"].contains(scenario) { gitlab.write("observed", "train-only") }
            let timestamp = ISO8601DateFormatter()
            let startedAt = timestamp.string(from: attemptDate.addingTimeInterval(5))
            let failedAt = timestamp.string(from: attemptDate.addingTimeInterval(60))
            let trainPipelineStartedAt = timestamp.string(from: attemptDate.addingTimeInterval(6))
            let trainPipelineFailedAt = timestamp.string(from: attemptDate.addingTimeInterval(59))
            let oldVersion = timestamp.string(from: attemptDate.addingTimeInterval(-60))
            let newVersion = timestamp.string(from: attemptDate.addingTimeInterval(120))
            let requeuedAt = timestamp.string(from: attemptDate.addingTimeInterval(180))
            let isMergedResult = ["merged-result", "wrong-merge-parent"].contains(scenario)
            let pipelineSHA = isMergedResult ? String(repeating: "d", count: 40)
                : scenario == "stale-source-pipeline" ? oldHead : newHead
            let pipeline: [String: Any] = ["id": 12, "project_id": 1, "status": "success", "sha": pipelineSHA,
                "ref": isMergedResult ? "refs/merge-requests/2/merge" : "feature"]
            let handler = try #require(gitlab.handler)
            var discussionReadsAfterVerification = 0
            var detailReadsAfterVerification = 0
            gitlab.handler = { call in
                if scenario == "queue-in-summary", call.endpoint.hasPrefix("/merge_requests?"), !gitlab.has("listed-queue") {
                    gitlab.write("listed-queue")
                    let response = try await handler(call)
                    var rows = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [[String: Any]])
                    rows[0]["merge_when_pipeline_succeeds"] = true
                    return try InMemoryGitLab.json(rows)
                }
                if call.endpoint.contains("/discussions?") {
                    if gitlab.has("verified-history") { discussionReadsAfterVerification += 1 }
                    if ["queue-during-preflight", "queue-recheck-fails"].contains(scenario), discussionReadsAfterVerification == 2 {
                        gitlab.write("observed", "train-only")
                        if scenario == "queue-recheck-fails" { gitlab.write("fail-queue-recheck") }
                    }
                    if scenario == "late-queue", discussionReadsAfterVerification == 3 {
                        gitlab.write("observed", "train-only")
                    }
                    let reason = scenario == "manual-removal" ? "" : " because the pipeline did not succeed."
                    var notes: [[String: Any]] = [
                        ["id": 7, "system": true, "resolvable": false, "author": ["id": 3], "created_at": startedAt,
                         "body": "started a [merge train](https://gitlab.example.test/g/p/-/merge_trains)"],
                        ["id": 8, "system": true, "resolvable": false, "author": ["id": 3], "created_at": failedAt,
                         "body": "removed this merge request from the merge train" + reason]
                    ]
                    if scenario == "accepted-queue" {
                        notes.insert(["id": 6, "system": true, "resolvable": false, "author": ["id": 3], "created_at": startedAt,
                            "body": "enabled automatic add to merge train when checks pass"], at: 0)
                    }
                    if scenario == "already-queued" {
                        notes.append(["id": 9, "system": true, "resolvable": false, "author": ["id": 3], "created_at": requeuedAt,
                            "body": "started a [merge train](https://gitlab.example.test/g/p/-/merge_trains)"])
                    }
                    if gitlab.has("cancel-during-recovery") || (scenario == "late-cancel" && discussionReadsAfterVerification >= 3) {
                        notes.append(["id": 9, "system": true, "resolvable": false, "author": ["id": 3],
                            "body": "removed this merge request from the merge train"])
                    }
                    if scenario == "late-cancel" {
                        notes.append(["id": 10, "system": true, "resolvable": false, "author": ["id": 3],
                            "body": "assigned to @me"])
                    }
                    return try InMemoryGitLab.json([["id": "train", "notes": notes]])
                }
                if call.endpoint.contains("/versions?") {
                    if scenario == "unreadable-history" { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                    gitlab.write("verified-history")
                    if scenario == "concurrent-cancel" { gitlab.write("cancel-during-recovery") }
                    return try InMemoryGitLab.json([
                        ["head_commit_sha": newHead, "created_at": newVersion],
                        ["head_commit_sha": scenario == "wrong-head" ? String(repeating: "d", count: 40) : oldHead,
                         "created_at": oldVersion]
                    ])
                }
                if call.endpoint.contains("/merge_requests/2/pipelines?") {
                    let failed: [String: Any] = ["id": 11, "project_id": 1, "ref": "refs/merge-requests/2/train",
                        "status": scenario == "canceled-train-pipeline" ? "canceled" : "failed",
                        "created_at": trainPipelineStartedAt, "updated_at": trainPipelineFailedAt]
                    var pipelines = [failed]
                    if scenario == "rebuilt-train" {
                        pipelines.insert(["id": 10, "project_id": 1, "ref": "refs/merge-requests/2/train",
                            "status": "canceled", "created_at": startedAt, "updated_at": trainPipelineStartedAt], at: 0)
                    }
                    return try InMemoryGitLab.json(pipelines)
                }
                if call.endpoint == "/projects/1/merge_requests/2" {
                    if gitlab.has("fail-queue-recheck") { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                    let response = try await handler(call)
                    if gitlab.has("verified-history") { detailReadsAfterVerification += 1 }
                    var fields = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [String: Any])
                    fields["head_pipeline"] = pipeline
                    if scenario == "pipeline-restarted", detailReadsAfterVerification > 2 {
                        fields["head_pipeline"] = ["id": 13, "status": "running"]
                    }
                    return try InMemoryGitLab.json(fields)
                }
                if scenario == "unapproved", call.endpoint.hasSuffix("/approval_state") {
                    return InMemoryGitLab.output(#"{"rules":[{"approvals_required":2,"approved":false}]}"#)
                }
                if call.endpoint == "/projects/1/pipelines/12" { return try InMemoryGitLab.json(pipeline) }
                if call.endpoint == "/projects/1/repository/branches/feature" {
                    return try InMemoryGitLab.json(["commit": ["id": scenario == "stale-live-branch" ? oldHead : newHead]])
                }
                if isMergedResult, call.endpoint == "/projects/1/repository/commits/\(pipelineSHA)" {
                    let base = String(repeating: "e", count: 40)
                    let parents = scenario == "wrong-merge-parent" ? [newHead, base] : [base, newHead]
                    return try InMemoryGitLab.json(["id": pipelineSHA, "parent_ids": parents])
                }
                if scenario == "queue-during-preflight", gitlab.has("observed"), call.endpoint.contains("/draft_notes?") {
                    return InMemoryGitLab.output(#"[{"id":22,"author_id":3,"note":"Unpublished"}]"#)
                }
                return try await handler(call)
            }

            let restored = SettingsManager(defaults: defaults)
            let monitor = AuthoredMergeRequestMonitor(settings: restored, glab: glab, canAutomate: { _ in true })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            if scenario == "same-head-requeued" {
                gitlab.write("observed", "train-only")
                monitor.refreshIfNeeded()
                while monitor.isLoading { await Task.yield() }
                gitlab.write("current-head", newHead)
            }
            if ["queue-disappeared", "queue-in-summary", "queue-recheck-fails", "same-head-requeued"].contains(scenario) {
                gitlab.remove("observed")
                gitlab.remove("fail-queue-recheck")
                let restarted = SettingsManager(defaults: defaults)
                #expect(restarted.mergeSubmissions.first?.observedReplacementQueue == true)
                let restartedMonitor = AuthoredMergeRequestMonitor(settings: restarted, glab: glab, canAutomate: { _ in true })
                restartedMonitor.refreshIfNeeded()
                while restartedMonitor.isLoading { await Task.yield() }
                #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
                #expect(restartedMonitor.requests.first?.submissionState == .changed)
                return
            }
            if scenario == "manual" {
                let ready = try #require(monitor.requests.first)
                #expect(ready.mayMergeManually)
                #expect(await monitor.mergeManually(ready.request, action: .enqueue) == .inTrain)
            }
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            let writes = gitlab.requests.filter { $0.method != "GET" }
            if ["repaired", "rebuilt-train", "merged-result", "accepted-queue", "clock-skew", "manual"].contains(scenario) {
                #expect(writes.count == 1)
                #expect(writes.first?.arguments.contains("sha=\(newHead)") == true)
                #expect(restored.mergeSubmissions.first?.context.head == newHead)
                #expect(restored.mergeSubmissions.first?.origin == .appAttempt)
                #expect(restored.mergeSubmissions.first?.trainNoteIDBeforeAttempt == 8)
                #expect(monitor.requests.first?.submissionState == .inTrain)
            } else if ["already-queued", "queue-during-preflight", "late-queue"].contains(scenario) {
                #expect(writes.isEmpty)
                #expect(monitor.requests.first?.submissionState == .inTrain)
                #expect(restored.mergeSubmissions.first?.origin == .observedQueue)
                #expect(restored.mergeSubmissions.first?.context.head == newHead)
            } else {
                #expect(writes.isEmpty)
                var expected = receipt
                if scenario == "same-head" { expected.observedTrainDeparture = true }
                #expect(restored.mergeSubmissions == [expected])
            }
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
            let policy = GitLabMergeActionPolicy(action: .enqueue, requiresResolvedDiscussions: true)
            let outcome = try await glab.mergeMergeRequest(projectID: 1, iid: 2, headSHA: request.sha!, host: host,
                expectedUser: user, expectedContext: .init(request), action: .enqueue, expectedPolicy: policy, shouldProceed: { true })
            #expect(outcome == .queued)
            let write = try #require(gitlab.requests.first { $0.method != "GET" })
            #expect(write.endpoint == "/projects/1/merge_requests/2/merge" && write.method == "PUT")
            #expect(write.command.contains("auto_merge=true"))
        }
    }

    @Test(arguments: ["ready", "newFeedback", "manualQueue"])
    func ordinaryAutomaticMergeWaitsForAFreshCheckAfterCI(_ scenario: String) async throws {
        try await fixture { glab, gitlab, request in
            let suite = "OrdinaryAutomaticMergeAfterCI.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.automation.autoMergeEnabled = true
            gitlab.write("ordinary-project")
            gitlab.write("pipeline-running")
            gitlab.write("outcome", "queued")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            var assessedNoteIDs: [Int] = []
            let assessment = ReReviewAssessment(notes: [
                .init(noteID: 10, state: .blocking, reason: "The new requirement is still outstanding.")
            ])
            monitor.authorFeedbackAllowsMerge = { _, discussions, authorID in
                assessedNoteIDs = discussions.flatMap(\.notes).compactMap(\.id)
                return assessment.hasNoRemainingAuthorWork(in: discussions, authorID: authorID)
            }

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            let running = try #require(monitor.requests.first)
            #expect(running.action == .enqueue)
            #expect(running.mayMergeManually)
            #expect(running.submissionState == .none)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(settings.mergeSubmissions.isEmpty)

            if scenario == "manualQueue" {
                #expect(await monitor.mergeManually(request, action: .enqueue) == .queued)
            } else {
                if scenario == "newFeedback" { gitlab.write("drift", "newFeedback") }
                gitlab.remove("pipeline-running")
                gitlab.write("pipeline-success")
                gitlab.write("outcome", "merged")
                monitor.refreshIfNeeded()
                while monitor.isLoading { await Task.yield() }
            }

            let writes = gitlab.requests.filter { $0.method != "GET" }
            if scenario == "newFeedback" {
                #expect(assessedNoteIDs == [10])
                #expect(writes.isEmpty)
                #expect(monitor.requests.first?.request.headPipeline?.status == .success)
                #expect(monitor.requests.first?.submissionState == MergeSubmissionState.none)
                #expect(settings.mergeSubmissions.isEmpty)
            } else {
                #expect(writes.count == 1)
                let write = try #require(writes.first)
                #expect(write.endpoint == "/projects/1/merge_requests/2/merge" && write.method == "PUT")
                #expect(write.arguments.contains("auto_merge=true") == (scenario == "manualQueue"))
                #expect(settings.mergeSubmissions.first?.state == (scenario == "manualQueue" ? .queued : .merged))
                #expect(gitlab.requests.filter { $0.endpoint.hasSuffix("/approval_state") }.count >= 2)
            }
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

    @Test(arguments: ["departed", "active", "unreadable"])
    func greenPipelineWaitsNormallyForApprovalsAfterConfirmedQueueDeparture(_ queue: String) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "ApprovalsAfterQueue.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            gitlab.write("observed", "train-only")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            @MainActor func refresh() async {
                monitor.refreshIfNeeded()
                while monitor.isLoading { await Task.yield() }
            }
            await refresh()
            let receipt = try #require(settings.mergeSubmissions.first)
            #expect(receipt.state == .inTrain)

            if queue != "active" { gitlab.remove("observed") }
            gitlab.write("current-head", String(repeating: "c", count: 40))
            gitlab.write("missing-approvals")
            let transport = try #require(gitlab.handler)
            gitlab.handler = { call in
                if queue == "unreadable", call.endpoint.contains("/merge_trains?") {
                    return InMemoryGitLab.output(error: "503 Service Unavailable", code: 1)
                }
                if gitlab.has("missing-approvals"), call.endpoint.hasSuffix("/approval_state") {
                    return InMemoryGitLab.output(#"{"rules":[{"approvals_required":2,"approved":false}]}"#)
                }
                let response = try await transport(call)
                guard call.endpoint == "/projects/1/merge_requests/2" else { return response }
                var detail = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [String: Any])
                detail["head_pipeline"] = ["id": 4, "status": "success"]
                if gitlab.has("missing-approvals") { detail["detailed_merge_status"] = "not_approved" }
                return try InMemoryGitLab.json(detail)
            }
            await refresh()

            @MainActor func check(_ blocker: ManualMergeBlocker) throws {
                let status = try #require(monitor.requests.first)
                let request = status.request
                let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: request.projectID, iid: request.iid),
                    title: request.title, url: request.webURL, mergeRequest: request, isAuthored: true)
                let card = RemoteBoardAdapter.mergePresentation(RemoteBoardAdapter.card(item, account: "me@\(host)"),
                    item: item, status: status)
                #expect(item.manualMergeBlocker(using: status) == blocker)
                #expect(card.presentation?.status == String(localized: blocker.title))
                #expect(status.submissionState == .changed)
                #expect(!status.mayAutoMerge && !status.mayMergeManually)
            }
            try check(queue == "departed" ? .prerequisite(.approvals) : .submission)
            gitlab.remove("missing-approvals")
            await refresh()
            try check(.submission)
            #expect(settings.mergeSubmissions == [receipt])
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["ordinary", "train", "active-train", "unreadable-train"])
    func confirmedQueueDepartureAllowsOrdinaryConflictRepairWithoutResubmission(_ queue: String) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "ConflictAfterQueue.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.automation.conflictTasksEnabled = true
            settings.automation.autoMergeEnabled = true
            if queue == "ordinary" { gitlab.write("ordinary-project") }
            gitlab.write("observed", queue == "ordinary" ? "queued" : "train-only")
            let transport = try #require(gitlab.handler)
            gitlab.handler = { call in
                if queue == "unreadable-train", gitlab.has("ordinary-conflict"), call.endpoint.contains("/merge_trains?") {
                    return InMemoryGitLab.output(error: "503 Service Unavailable", code: 1)
                }
                let response = try await transport(call)
                guard gitlab.has("ordinary-conflict"), call.endpoint == "/projects/1/merge_requests/2" else { return response }
                var detail = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [String: Any])
                detail["has_conflicts"] = true
                detail["detailed_merge_status"] = "conflict"
                return try InMemoryGitLab.json(detail)
            }
            var launchedHeads: [String] = []
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true },
                conflictLauncher: { input, _ in
                    launchedHeads.append(input.head)
                    return .init(id: UUID(), key: .init(assistant: input.assistant, work: input.work,
                        username: input.username, workspace: "", access: input.access), title: input.title,
                        prompt: input.prompt, createdAt: Date(), allowsPush: input.allowsPush, expectedHeadSHA: input.head)
                })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            let receipt = try #require(settings.mergeSubmissions.first)
            #expect(receipt.origin == .observedQueue)
            #expect(monitor.requests.first?.submissionState == (queue == "ordinary" ? .queued : .inTrain))

            if queue == "active-train" { gitlab.write("drift", "newFeedback") }
            else { gitlab.remove("observed") }
            gitlab.write("ordinary-conflict")
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            let conflicting = try #require(monitor.requests.first)
            #expect(conflicting.submissionState == .changed)
            #expect(conflicting.request.hasConflicts == true)
            #expect(!conflicting.mayAutoMerge && !conflicting.mayMergeManually)
            if queue == "ordinary" || queue == "train" {
                let deadline = ContinuousClock.now + .seconds(3)
                while launchedHeads.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
                let head = try #require(conflicting.request.sha)
                #expect(launchedHeads == [head])
                gitlab.remove("ordinary-conflict")
                monitor.refreshIfNeeded()
                while monitor.isLoading { await Task.yield() }
                #expect(monitor.requests.first?.submissionState == .changed)
                #expect(monitor.requests.first?.mayAutoMerge == false)
                #expect(launchedHeads.count == 1)
            } else {
                #expect(settings.conflictReceipts.isEmpty)
                #expect(launchedHeads.isEmpty)
            }
            #expect(settings.mergeSubmissions == [receipt])
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: [false, true])
    func aQueueObservedWithoutDiscussionsIsRememberedAcrossRestart(_ stillQueued: Bool) async throws {
        try await fixture { glab, gitlab, _ in
            // given
            let suite = "ObservedQueueDiscussionFailure.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.automation.autoMergeEnabled = true
            settings.save()
            let transport = try #require(gitlab.handler)
            gitlab.write("observed", "queued")
            gitlab.write("discussion-read-failure")
            gitlab.handler = { call in
                if gitlab.has("discussion-read-failure"), call.endpoint.contains("/discussions?") {
                    return InMemoryGitLab.output(error: "403 Forbidden", code: 1)
                }
                return try await transport(call)
            }

            // when
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.mergeSubmissions.first?.origin == .observedQueue)
            #expect(restored.mergeSubmissions.first?.discussionFingerprint == nil)
            gitlab.remove("discussion-read-failure")
            if !stillQueued { gitlab.remove("observed") }
            let restarted = AuthoredMergeRequestMonitor(settings: restored, glab: glab, canAutomate: { _ in true })
            restarted.refreshIfNeeded()
            while restarted.isLoading { await Task.yield() }

            // then
            #expect(restarted.requests.first?.submissionState == (stillQueued ? .queued : .changed))
            #expect(restored.mergeSubmissions.first?.discussionFingerprint == (stillQueued ? ReviewVerdict.fingerprint([]) : nil))
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["queued", "train-only"])
    func aQueueForARepairedHeadSupersedesTheEarlierRejection(_ queue: String) async throws {
        try await fixture { glab, gitlab, request in
            // given
            let suite = "ObservedRepairedMergeQueue.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true; settings.notificationsEnabled = false
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.automation.autoMergeEnabled = true
            let rejectedHead = try #require(request.sha)
            let repairedHead = String(repeating: "c", count: 40)
            let rejected = MergeSubmissionReceipt(target: .init(host: host, username: user.username, projectID: 1, iid: 2),
                userID: user.id, context: .init(request), semanticFingerprint: request.semanticContextFingerprint,
                discussionFingerprint: ReviewVerdict.fingerprint([]), configuration: .init(settings),
                action: .enqueue, createdAt: Date(), trainNoteIDBeforeAttempt: 0,
                confirmedTrainRejection: .init(context: .init(request), noteID: 10, sourceSHA: rejectedHead,
                    targetSHA: String(repeating: "b", count: 40)))
            try #require(settings.saveMergeSubmission(rejected))
            gitlab.write("current-head", repairedHead)
            gitlab.write("observed", queue)
            gitlab.write("outcome", "queued")

            // when
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(monitor.requests.first?.submissionState == (queue == "queued" ? .queued : .inTrain))
            let restored = SettingsManager(defaults: defaults)
            #expect(restored.mergeSubmissions.first?.origin == .observedQueue)
            #expect(restored.mergeSubmissions.first?.context.head == repairedHead)
            #expect(restored.mergeSubmissions.first?.confirmedTrainRejection == nil)
            gitlab.remove("observed")
            let restarted = AuthoredMergeRequestMonitor(settings: restored, glab: glab, canAutomate: { _ in true })
            restarted.refreshIfNeeded()
            while restarted.isLoading { await Task.yield() }

            // then
            #expect(restarted.requests.first?.submissionState == .changed)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: [false, true])
    func automaticMergeKeepsTheDiscussionPolicyCheckedBeforeCLIReadiness(_ train: Bool) async throws {
        try await fixture { glab, gitlab, request in
            let suite = "MergeDiscussionPolicyRace.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.onboardingCompleted = true
            settings.notificationsEnabled = false
            settings.automation.autoMergeEnabled = true
            if !train { gitlab.write("ordinary-project") }
            gitlab.write("outcome", "merged")
            let transport = try #require(gitlab.handler)
            gitlab.handler = { call in
                if call.endpoint == "/projects/1/merge_requests/2/merge", call.method == "PUT" {
                    return InMemoryGitLab.output(#"{"project_id":1,"iid":2,"state":"merged"}"#)
                }
                let response = try await transport(call)
                guard call.endpoint == "/projects/1/merge_requests/2" else { return response }
                var detail = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [String: Any])
                detail["head_pipeline"] = ["id": 4, "status": "success"]
                return try InMemoryGitLab.json(detail)
            }
            var readinessChecks = 0
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in
                readinessChecks += 1
                gitlab.write("discussion-policy-disabled")
                return true
            })

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            #expect(readinessChecks == 1)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(settings.mergeSubmissions.isEmpty)

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            let status = try #require(monitor.requests.first)
            #expect(status.blockers == [.discussionPolicy])
            #expect(!status.mayAutoMerge)
            #expect(status.mayMergeManually)
            #expect(readinessChecks == 1)
            #expect(await monitor.mergeManually(request, action: train ? .enqueue : .mergeNow) == .merged)
            #expect(gitlab.requests.count { $0.method != "GET" } == 1)
        }
    }

    @Test func aQueueCreatedDuringTheFinalPreflightRemainsUserOwnedAndCannotBeReplaced() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "MergeQueueRace.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.automation.selectedAssistant = .codex
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
    func aBusyConflictLauncherPreservesThePreviousPlanAndRetriesOnTheNextPoll(_ previousPlan: Bool) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "ConflictLauncherBusy.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.selectedAssistant = .codex
            settings.automation.packageDecision = .enabled
            settings.automation.conflictTasksEnabled = true
            settings.automation.allowAssistantTools = true
            settings.automation.assistantToolProjects = "g/p"
            settings.automation.conflictPushProjects = "g/p"
            settings.automation.allowConflictPush = false
            gitlab.write("ordinary-project")
            let handler = try #require(gitlab.handler)
            gitlab.handler = { call in
                let response = try await handler(call)
                guard call.endpoint == "/projects/1/merge_requests/2" else { return response }
                var detail = try #require(JSONSerialization.jsonObject(with: response.stdout) as? [String: Any])
                detail["has_conflicts"] = true
                detail["detailed_merge_status"] = "conflict"
                return try InMemoryGitLab.json(detail)
            }
            var busy = false
            var launchAttempts: [Bool] = []
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true },
                conflictLauncher: { input, settings in
                    launchAttempts.append(input.allowsPush)
                    if busy { throw AssistantAutomationRunner.HandoffError.mergeRequestBusy }
                    let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: input.assistant, work: input.work,
                        username: input.username, workspace: "", access: input.access), title: input.title, prompt: input.prompt,
                        createdAt: Date(), allowsPush: input.allowsPush, execution: .init(state: .blocked), expectedHeadSHA: input.head)
                    settings.assistantHandoffs.append(job)
                    settings.save()
                    return job
                })
            @MainActor func poll() async throws {
                monitor.refreshIfNeeded()
                let deadline = ContinuousClock.now + .seconds(3)
                while monitor.isLoading || monitor.requests.first.map({
                    monitor.conflictAutomationState(for: $0.request) == .processing
                }) == true {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            if previousPlan { try await poll() }
            let priorJob = settings.assistantHandoffs.last?.id
            settings.automation.allowConflictPush = true
            busy = true
            try await poll()

            #expect(launchAttempts == (previousPlan ? [false, true] : [true]))
            #expect(settings.assistantHandoffs.count == (previousPlan ? 1 : 0))
            let restoredReceipts = SettingsManager(defaults: defaults).conflictReceipts
            #expect(restoredReceipts.count == (previousPlan ? 1 : 0))
            #expect(restoredReceipts.first?.jobID == priorJob)
            #expect(restoredReceipts.first?.allowsPush == (previousPlan ? false : nil))
            let conflicting = try #require(monitor.requests.first?.request)
            #expect(monitor.conflictAutomationState(for: conflicting) == .available)

            busy = false
            try await poll()
            try await poll()
            #expect(launchAttempts == (previousPlan ? [false, true, true] : [true, true]))
            #expect(settings.assistantHandoffs.count == (previousPlan ? 2 : 1))
            #expect(settings.conflictReceipts.first?.jobID == settings.assistantHandoffs.last?.id)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: ["disabled", "optedOut"])
    func explainsProjectPolicyHoldsWithoutDisablingManualMerge(_ scenario: String) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "AutomaticMergePolicyHold.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.allowAssistantTools = true
            gitlab.write("discussion-policy-disabled")
            let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
            if scenario == "optedOut" {
                settings.autoMergeOptOuts.insert(target)
            }
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            let status = try #require(monitor.requests.first)
            let request = status.request
            let mergeEnabled = settings.permitsAutomaticAction(.merge, for: request, target: target)
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: request.projectID, iid: request.iid),
                title: request.title, url: request.webURL, mergeRequest: request, isAuthored: true)
            let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
            let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
                allowsRemoval: false, assistantReady: true, mergeStatus: status, showsAutomaticMergePolicyHold: mergeEnabled)
            let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@\(host)"), model: model)
            let expected = scenario == "disabled"
                ? "Auto-merge requires GitLab to enforce resolved discussions." : "Monitoring MR"
            #expect(model.status == expected)
            #expect(phone.presentation?.status == expected)
            item.manualMergeAvailable = true
            let decisionRow = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
            let decision = MRCardPresentation(row: decisionRow, reviewingContext: ReviewingContext(row: decisionRow),
                allowsRemoval: false, assistantReady: true, mergeStatus: status, showsAutomaticMergePolicyHold: mergeEnabled)
            #expect(decision.humanAction?.action == .reviewMerge)
            #expect(decision.message == (scenario == "optedOut"
                ? String(localized: .MRHumanAction.mrHumanActionMerge) : expected))
            #expect(item.canOfferManualMerge(using: status))
            #expect(!status.mayAutoMerge)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        }
    }

    @Test(arguments: [MRAutomationPreference.default, .on, .off])
    func explicitMergeChoiceOverridesGlobalAuthorPolicy(_ preference: MRAutomationPreference) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "MergePromptAuthorOnly.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.treatAssignedMergeRequestsAsOwn = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeAuthorOnly = true
            settings.automation.requiresAssignmentClaim = false
            settings.setAutoMergePreference(preference, for: .init(host: host, username: "me", projectID: 1, iid: 2))
            gitlab.write("assigned-by-others")
            gitlab.write("ordinary-project")
            gitlab.write("outcome", "merged")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }

            #expect(gitlab.requests.filter { $0.method == "PUT" }.count == (preference == .on ? 1 : 0))
            if preference != .on {
                let item = try #require(monitor.requests.first)
                #expect(item.mayMergeManually && !item.mayAutoMerge)
                #expect(await monitor.mergeManually(item.request, action: .mergeNow) == .merged)
            }
        }
    }

    @Test func choosingOnImmediatelyRechecksMergeDespiteTheGlobalProjectAndAssigneeFilters() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "ExplicitMergeOverride.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeMode = .off
            settings.automation.autoMergeWithOtherAssignees = false
            settings.automation.autoMergeProjects = "another/project"
            gitlab.write("shared-assignment")
            gitlab.write("ordinary-project")
            gitlab.write("outcome", "merged")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })

            let target = MRAutomationScope.Target(host: host, username: user.username, projectID: 1, iid: 2)
            settings.setAutoMergePreference(.on, for: target)
            await monitor.resumeAutomaticMerge(for: target)

            #expect(gitlab.requests.filter { $0.method == "PUT" }.count == 1)
        }
    }

    @Test func assignedMergeWaitsForAnExplicitClaimEvenWithAutoMergeOn() async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "AwaitingAssignment.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.requiresAssignmentClaim = true
            let target = MRAutomationScope.Target(host: host, username: user.username, projectID: 1, iid: 2)
            settings.setAutoMergePreference(.on, for: target)
            gitlab.write("assigned-by-others")
            gitlab.write("ordinary-project")
            gitlab.write("outcome", "merged")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            let beforeClaim = try #require(monitor.requests.first)
            #expect(!beforeClaim.mayAutoMerge && beforeClaim.mayMergeManually)
            var boardInput = MRBoardProjector.Input(account: .init(host: host, username: user.username, revision: glab.accountRevision))
            boardInput.authored = [beforeClaim]
            boardInput.automation = settings.configuredAutomation
            let waiting = try #require(MRBoardProjector(input: boardInput).board().own.first)
            #expect(waiting.waitsForAssignmentClaim && waiting.needsAttention)
            #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
            #expect(settings.confirmAssignedOwnership(beforeClaim.request, target: target))
            let restored = SettingsManager(defaults: defaults)
            #expect(!restored.automation.scope.awaitsAssignmentClaim(beforeClaim.request, target: target))
            boardInput.automation = restored.configuredAutomation
            #expect(MRBoardProjector(input: boardInput).board().own.first?.waitsForAssignmentClaim == false)

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            #expect(gitlab.requests.filter { $0.method == "PUT" }.count == 1)
        }
    }

    @Test(arguments: ["allow", "train", "deny", "unavailable", "off", "on", "onDenied", "onUncertain", "onCI", "ci", "changed"])
    func mergePromptChecksReadinessEvenWhenTheUserQualifiesTheMR(_ scenario: String) async throws {
        try await fixture { glab, gitlab, _ in
            let suite = "MergePrompt.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.autoMergeMode = .prompt
            settings.automation.autoMergePrompt.criteria = "Only merge dependencies after QA signs off."
            let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
            let optedIn = ["on", "onDenied", "onUncertain", "onCI"].contains(scenario)
            if scenario == "off" || optedIn {
                settings.setAutoMergePreference(optedIn ? .on : .off, for: target)
            }
            if scenario != "train" { gitlab.write("ordinary-project") }
            if scenario == "ci" || scenario == "onCI" { gitlab.write("pipeline-running") }
            gitlab.write("outcome", scenario == "train" ? "train-only" : "merged")

            var verifications = 0
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true },
                verifyActionPrompt: { input, _ in
                    verifications += 1
                    #expect(input.action == .merge && input.target == target)
                    #expect(input.evaluationScope == (optedIn ? .readinessOnly : .qualificationAndReadiness))
                    #expect(input.criteria == settings.automation.autoMergePrompt.criteria)
                    #expect(settings.mergeSubmissions.isEmpty)
                    if scenario == "changed" { gitlab.write("drift", "target") }
                    if scenario == "unavailable" { throw AutomaticActionPromptVerifier.Failure.unavailable }
                    let decision: AutomaticActionPromptVerifier.Result.Decision = switch scenario {
                    case "deny", "onDenied": .deny
                    case "onUncertain": .uncertain
                    default: .allow
                    }
                    return .init(decision: decision, reason: "Checked the QA status.")
                })

            monitor.refreshIfNeeded()
            while monitor.isLoading { await Task.yield() }
            if ["deny", "unavailable", "onDenied", "onUncertain"].contains(scenario) {
                monitor.refreshIfNeeded()
                while monitor.isLoading { await Task.yield() }
            }

            let invoked = !["off", "ci", "onCI"].contains(scenario)
            let writes = gitlab.requests.filter { $0.method != "GET" }
            #expect(verifications == (invoked ? 1 : 0))
            #expect(writes.count == (["allow", "train", "on"].contains(scenario) ? 1 : 0))
            #expect(settings.mergeSubmissions.count == writes.count)
            let events = settings.automationEvents.filter { $0.action == .mergePrompt }
            #expect(events.count == (invoked ? 1 : 0))
            #expect(events.allSatisfy { $0.origin == .automatic && $0.message?.isEmpty == false })
        }
    }

    @Test(arguments: [false, true], ["mergeNow", "mergeTrain", "runningTrain"])
    func manualAndAutomaticSubmissionUseGitLabsCurrentApprovals(_ automatic: Bool, _ mode: String) async throws {
        try await fixture { glab, gitlab, request in
            let suite = "MergeWithCurrentApprovals.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.applyPreset(.full, for: .codex)
            settings.automation.allowAssistantTools = true
            settings.automation.autoMergeEnabled = automatic
            let train = mode != "mergeNow"
            let action: MergeSubmissionAction = train ? .enqueue : .mergeNow
            let outcome: MergeSubmissionState = train ? .inTrain : .merged
            if !train { gitlab.write("ordinary-project") }
            if mode == "runningTrain" { gitlab.write("pipeline-running") }
            gitlab.write("outcome", train ? "train-only" : "merged")
            let monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, canAutomate: { _ in true })
            if automatic { monitor.refreshIfNeeded() }
            else { monitor.setVisible(true) }
            while monitor.isLoading { await Task.yield() }
            if !automatic { #expect(await monitor.mergeManually(request, action: action) == outcome) }

            let writes = gitlab.requests.filter { $0.method != "GET" }
            #expect(writes.count == 1)
            let submission = try #require(writes.first)
            #expect(submission.method == (train ? "POST" : "PUT"))
            #expect(submission.endpoint == (train ? "/projects/1/merge_trains/merge_requests/2" : "/projects/1/merge_requests/2/merge"))
            #expect(submission.arguments.contains("sha=\(request.sha!)"))
            #expect(submission.arguments.contains("auto_merge=true") == (action == .enqueue))
            #expect(settings.mergeSubmissions.first?.state == outcome)
            #expect(gitlab.requests.filter { $0.endpoint.hasSuffix("/approval_state") }.count >= 2)
            #expect(gitlab.requests.allSatisfy { $0.endpoint != "/projects/1/approvals" && !$0.endpoint.contains("/versions?") })
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
    private var policy: GitLabMergeActionPolicy { .init(action: .enqueue, requiresResolvedDiscussions: true, usesMergeTrain: true) }
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
            let owned = gitlab.has("assigned-by-others")
                ? raw.replacingOccurrences(of: #""author":{"id":3,"username":"me","name":"Me"}"#,
                    with: #""author":{"id":7,"username":"creator","name":"Creator"},"assignees":[{"id":3,"username":"me","name":"Me"}]"#)
                : raw
            let assigned = gitlab.has("shared-assignment")
                ? owned.replacingOccurrences(of: #""draft":false"#,
                    with: #""draft":false,"assignees":[{"id":3,"username":"me","name":"Me"},{"id":7,"username":"other","name":"Other"}]"#)
                : owned
            let listed = gitlab.has("current-head")
                ? assigned.replacingOccurrences(of: String(repeating: "a", count: 40), with: gitlab.text("current-head")) : assigned
            switch call.endpoint {
            case "/user": return InMemoryGitLab.output(drift == "account" ? #"{"id":99,"username":"me"}"# : #"{"id":3,"username":"me"}"#)
            case "/version": return try InMemoryGitLab.json(["version": gitlab.has("version") ? gitlab.text("version") : "19.5.3-ee"])
            case "/projects/1":
                return try InMemoryGitLab.json(["default_branch": "main", "merge_trains_enabled": drift != "policy" && !gitlab.has("ordinary-project"),
                    "only_allow_merge_if_all_discussions_are_resolved": !gitlab.has("discussion-policy-disabled")])
            case let path where path.hasPrefix("/merge_requests?"): return InMemoryGitLab.output("[" + listed + "]")
            case let path where path.contains("/merge_trains?"):
                return InMemoryGitLab.output(["train", "train-only"].contains(gitlab.text("observed"))
                    ? #"[{"merge_request":{"project_id":1,"iid":2}}]"# : "[]")
            case "/projects/1/merge_requests/2":
                var object = try #require(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
                if gitlab.has("current-head") { object["sha"] = gitlab.text("current-head") }
                if gitlab.has("pipeline-running") {
                    object["detailed_merge_status"] = "ci_still_running"
                    object["head_pipeline"] = ["id": 4, "status": "running"]
                } else if gitlab.has("pipeline-success") {
                    object["head_pipeline"] = ["id": 4, "status": "success"]
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
                return InMemoryGitLab.output(drift == "newFeedback" ? #"[{"id":"new","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":false,"body":"New condition"}]}]"# : "[]")
            case "/projects/1/repository/branches/main":
                return try InMemoryGitLab.json(["commit": ["id": String(repeating: "b", count: 40)]])
            case "/projects/1/repository/branches/feature":
                return try InMemoryGitLab.json(["commit": ["id": String(repeating: "a", count: 40)]])
            case let path where path.contains("/diffs?"): return InMemoryGitLab.output("[]")
            case let path where path.contains("/reviewers?"): return InMemoryGitLab.output("[]")
            case let path where path.contains("/draft_notes?"):
                return InMemoryGitLab.output(drift == "drafts" ? #"[{"id":10,"author_id":3,"note":"Reply"}]"# : "[]")
            case "/projects/1/merge_trains/merge_requests/2", "/projects/1/merge_requests/2/merge":
                gitlab.write("observed", gitlab.text("outcome"))
                if call.method == "PUT", !call.arguments.contains("auto_merge=true"), gitlab.text("outcome") == "merged" {
                    return InMemoryGitLab.output(#"{"project_id":1,"iid":2,"state":"merged"}"#)
                }
                return InMemoryGitLab.output("[]")
            default: return try gitlab.unexpected(call)
            }
        }
        try await body(gitlab.service(host: host, username: user.username), gitlab, request)
    }
}
