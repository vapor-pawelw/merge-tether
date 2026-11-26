import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MRSettingsRecordTests {
    private let target = MRAutomationScope.Target.mergeRequest(
        host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)

    @Test func legacyCollectionsMigrateOnSaveAndRestoreWithoutTheirMirrors() throws {
        try withDefaults { defaults in
            let conflict = conflictReceipt
            let secondAccount = MRAutomationScope.Target.mergeRequest(
                host: target.host, username: "another", projectID: target.projectID, iid: 11)
            let repository = target.repository
            let legacy = try [
                "autoPublishOptOuts": JSONEncoder().encode(Set([target, repository])),
                "autoMergeOptIns": JSONEncoder().encode(Set([secondAccount])),
                "conflictReceipts": JSONEncoder().encode(Set([conflict])),
                "assistantHandoffs": JSONEncoder().encode([job(), job(username: "another"), job()]),
                "reReviewDraftBaselines": JSONEncoder().encode([target: 2, secondAccount: 4])
            ]
            for (key, value) in legacy { defaults.set(value, forKey: key) }
            let settings = SettingsManager(defaults: defaults)
            let jobIDs = settings.assistantHandoffs.map(\.id)
            #expect(jobIDs.count == 3)
            #expect(defaults.object(forKey: "mergeRequestRecords") == nil)
            #expect(settings.save())
            _ = try #require(defaults.data(forKey: "mergeRequestRecords"))
            for key in legacy.keys {
                #expect(defaults.data(forKey: key) != nil)
                defaults.removeObject(forKey: key)
            }

            let restarted = SettingsManager(defaults: defaults)
            #expect(restarted.autoPublishOptOuts == [target, repository])
            #expect(restarted.autoMergeOptIns == [secondAccount])
            #expect(restarted.conflictReceipts == [conflict])
            #expect(restarted.assistantHandoffs.map(\.id) == jobIDs)
            #expect(restarted.reReviewDraftBaselines == [target: 2, secondAccount: 4])
        }
    }

    @Test func downgradeChangesToLegacyPreferencesAndFencesAreReadOnUpgrade() throws {
        try withDefaults { defaults in
            let settings = SettingsManager(defaults: defaults)
            settings.autoPublishOptOuts.insert(target)
            #expect(settings.save())
            defaults.set(try JSONEncoder().encode(Set<MRAutomationScope.Target>()), forKey: "autoPublishOptOuts")
            defaults.set(try JSONEncoder().encode(Set([conflictReceipt])), forKey: "conflictReceipts")

            let restarted = SettingsManager(defaults: defaults)
            #expect(restarted.autoPublishOptOuts.isEmpty)
            #expect(restarted.conflictReceipts == [conflictReceipt])
            #expect(restarted.save())
            defaults.removeObject(forKey: "conflictReceipts")
            #expect(SettingsManager(defaults: defaults).conflictReceipts == [conflictReceipt])
        }
    }

    @Test(arguments: ["merged", "closed", "failed", "partial", "partialHead", "auth", "authChanged", "wrongMR", "accountChanged", "stale"])
    func onlyCurrentExactTerminalObservationsRetireTransientData(_ response: String) async throws {
        let suite = "MRSettingsRecordTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let untouched = MRAutomationScope.Target.mergeRequest(
            host: target.host, username: "another", projectID: target.projectID, iid: 11)
        let storeDirectory = try makeAssistantRunFixtureHome()
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let storage = InstallationStorage(bundleIdentifier: "test.mergetether", home: storeDirectory)
        var run = job()
        let folder = storage.runs.appending(path: run.id.uuidString, directoryHint: .isDirectory)
        let logs = folder.appending(path: "cli-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stdout = logs.appending(path: "stdout")
        let proof = folder.appending(path: "seal-receipt.json")
        let rawLog = Data(repeating: 65, count: 262_144) + Data("diagnostic tail".utf8)
        try rawLog.write(to: stdout)
        try Data("legacy proof".utf8).write(to: proof)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86_400)], ofItemAtPath: stdout.path)
        run.execution?.finishedAt = .distantPast
        run.execution?.workingDirectory = folder.path
        settings.assistantHandoffs = [run]
        settings.newReviewTargets = [target, untouched]
        settings.heldNewReviewTargets = [target]
        settings.autoPublishOptOuts = [target]
        settings.conflictReceipts = [conflictReceipt]
        settings.beginCommentReview(for: target)
        let assessment = AuthorFeedbackAssessmentStore.fileURL(target, in: storeDirectory)
        let otherAssessment = AuthorFeedbackAssessmentStore.fileURL(untouched, in: storeDirectory)
        try Data("fixture".utf8).write(to: assessment)
        try Data("fixture".utf8).write(to: otherAssessment)
        let open = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request("opened").utf8))
        settings.mrLifecycleLedger.record(open, for: target, autoRemoveFinished: true)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        var userReads = 0
        gitlab.handler = { command in
            switch command.endpoint {
            case "/user":
                userReads += 1
                let username = response == "auth" ? "another" : target.username
                let id = response == "authChanged" && userReads > 1 ? 22 : 21
                return InMemoryGitLab.output(#"{"id":\#(id),"username":"\#(username)","name":"Viewer"}"#)
            case let path where path.hasPrefix("/merge_requests?"):
                return InMemoryGitLab.output("[]")
            case "/projects/7/merge_requests/11":
                if response == "failed" { throw GlabError.notAuthenticated }
                if response == "partial" { return InMemoryGitLab.output(#"{"state":"closed"}"#) }
                if response == "partialHead" { return InMemoryGitLab.output(request("closed", head: nil)) }
                if response == "wrongMR" { return InMemoryGitLab.output(request("closed", iid: 12)) }
                if response == "accountChanged" { glab.currentUsername = "another" }
                if response == "stale" {
                    settings.mrLifecycleLedger.record(open, for: target, now: Date().addingTimeInterval(1))
                }
                return InMemoryGitLab.output(request(response == "merged" ? "merged" : "closed"))
            default:
                return InMemoryGitLab.output("[]")
            }
        }
        let monitor = MergeRequestAttentionMonitor(glab: glab, settings: settings, provenanceDirectory: storeDirectory,
            authorFeedbackAssessmentDirectory: storeDirectory, runStorage: storage, canAutomate: { _ in false })
        await withCheckedContinuation { continuation in
            monitor.onRefreshed = {
                monitor.onRefreshed = nil
                continuation.resume()
            }
            monitor.refresh(host: target.host, username: target.username, todos: [])
        }
        let cleanup = response == "merged" || response == "closed"
        let terminal = cleanup || response == "partialHead"
        #expect(settings.newReviewTargets.contains(target) == !terminal)
        #expect(settings.newReviewTargets.contains(untouched))
        #expect(settings.heldNewReviewTargets.contains(target))
        #expect(settings.autoPublishOptOuts.contains(target))
        #expect(settings.conflictReceipts == [conflictReceipt])
        #expect(settings.pendingCommentReviews.contains(target))
        #expect(FileManager.default.fileExists(atPath: assessment.path) == (response != "merged"))
        #expect(FileManager.default.fileExists(atPath: otherAssessment.path))
        #expect(try Data(contentsOf: stdout) == (cleanup ? Data(rawLog.suffix(131_072)) : rawLog))
        #expect(FileManager.default.fileExists(atPath: proof.path))
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func reopenWithinRetentionPreservesTheOriginalFencesAndUserIntentAcrossRestart() throws {
        try withDefaults { defaults in
            let settings = SettingsManager(defaults: defaults)
            let day: TimeInterval = 86_400
            let open = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request("opened").utf8))
            let closed = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request("closed").utf8))
            let closedAt = Date(timeIntervalSince1970: 10 * day)
            let attempt = AuthorFeedbackAttempt(target: target, noteID: 10, revision: "same-note")
            let receiptKey = ReReviewReceipt.Key(host: target.host, authorID: 21, projectID: 7, iid: 11, reviewerID: 22)
            let pin = try #require(BoardCardPin.mergeRequest(host: target.host, username: target.username, projectID: 7, iid: 11))
            settings.authorFeedbackAttempts = [attempt]
            settings.conflictReceipts = [conflictReceipt]
            settings.reReviewReceipts = [receiptKey: ReReviewReceipt(noteID: 10, unconfirmed: true)]
            settings.boardPins = [pin]
            settings.autoPublishOptOuts = [target]
            settings.independentApprovalPreferences = [target: .off]
            settings.beginCommentReview(for: target)
            settings.mrLifecycleLedger.record(open, for: target, now: closedAt.addingTimeInterval(-1))
            settings.mrLifecycleLedger.record(closed, for: target, now: closedAt)
            settings.retireMRProgress(for: target, state: .closed, terminalSince: closedAt, now: closedAt.addingTimeInterval(10 * day))
            #expect(settings.save())

            let restarted = SettingsManager(defaults: defaults)
            restarted.mrLifecycleLedger.record(open, for: target, now: closedAt.addingTimeInterval(20 * day))
            #expect(restarted.mrLifecycleLedger.request(for: target)?.isOpen == true)
            #expect(restarted.authorFeedbackAttempts == [attempt])
            #expect(restarted.conflictReceipts == [conflictReceipt])
            #expect(restarted.reReviewReceipts[receiptKey]?.covers(noteID: 10, headSHA: "synthetic") == true)
            #expect(restarted.boardPins.contains(pin))
            #expect(restarted.storedActionPreference(.commentPublication, for: target) == .off)
            #expect(restarted.storedActionPreference(.approval, for: target) == .off)
            #expect(restarted.pendingCommentReviews.contains(target))
        }
    }

    @Test(arguments: ["merged", "closed"])
    func oneRunOnAnAlreadyRetiredMRGetsExactReadsBeforeCleanup(_ state: String) async throws {
        let suite = "MRSettingsRecordTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let home = try makeAssistantRunFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = InstallationStorage(bundleIdentifier: "test.mergetether", home: home)
        var run = job()
        let folder = storage.legacyRuns.appending(path: run.id.uuidString, directoryHint: .isDirectory)
        let logs = folder.appending(path: "cli-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stdout = logs.appending(path: "stdout")
        let raw = Data(repeating: 65, count: 262_144)
        let older = Date().addingTimeInterval(-8 * 86_400)
        try raw.write(to: stdout)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: stdout.path)
        run.execution?.workingDirectory = folder.path
        run.execution?.finishedAt = older
        settings.assistantHandoffs = [run]
        settings.mrLifecycleLedger.record(try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request(state).utf8)),
            for: target, now: older, autoRemoveFinished: true)
        #expect(settings.save())
        let restarted = SettingsManager(defaults: defaults)
        #expect(restarted.retainedHistoryCandidates(host: target.host, username: target.username).isEmpty)

        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        var terminal = false
        var exactReads = 0
        gitlab.handler = { command in
            switch command.endpoint {
            case "/user": return InMemoryGitLab.output(#"{"id":21,"username":"me","name":"Viewer"}"#)
            case "/projects/7/merge_requests/11":
                exactReads += 1
                if !terminal && state == "merged" { throw GlabError.notAuthenticated }
                return InMemoryGitLab.output(request(terminal ? state : "opened"))
            default: return InMemoryGitLab.output("[]")
            }
        }
        let monitor = MergeRequestAttentionMonitor(glab: glab, settings: restarted, provenanceDirectory: home,
            runStorage: storage, canAutomate: { _ in false })
        func refresh() async {
            await withCheckedContinuation { continuation in
                monitor.onRefreshed = { monitor.onRefreshed = nil; continuation.resume() }
                monitor.refresh(host: target.host, username: target.username, todos: [])
            }
        }
        await refresh()
        #expect(exactReads >= 1)
        #expect(try Data(contentsOf: stdout) == raw)
        terminal = true
        await refresh()
        #expect(try Data(contentsOf: stdout).count == 131_072)
        #expect(restarted.assistantHandoffs.map(\.id) == [run.id])
    }

    @Test(arguments: ["merged", "oldClose", "recentClose", "opened"])
    func retirementBoundsDisplayHistoryAndRetainsActiveAndReferencedRuns(_ situation: String) throws {
        try withDefaults { defaults in
            let settings = SettingsManager(defaults: defaults)
            let now = Date()
            var displayJobs = (0..<18).map { index -> AssistantAutomationRunner.Handoff in
                var run = job(createdAt: now.addingTimeInterval(Double(index)))
                run.readOnlyReview = true
                run.manual = true
                run.workflow = .review
                run.execution?.output = "Display transcript"
                return run
            }
            let referenced = displayJobs.removeFirst()
            var active = job()
            active.execution?.state = .running
            var queued = job()
            queued.execution?.state = .queued
            var evidence = job()
            evidence.followUpPushAllowed = true
            evidence.feedbackNoteIDs = [42]
            evidence.execution?.output = "Successful transcript"
            let otherAccount = job(username: "another")
            settings.assistantHandoffs = [referenced, active, queued, evidence, otherAccount] + displayJobs
            settings.conflictReceipts = [.init(host: target.host, userID: 21, projectID: 7, iid: 11,
                sourceSHA: "head", targetSHA: "target", jobID: referenced.id)]
            let pin = try #require(BoardCardPin.mergeRequest(host: target.host, username: target.username, projectID: 7, iid: 11))
            settings.boardPins = [pin]
            let state: GitLabMergeRequestState = switch situation {
            case "merged": .merged
            case "opened": .opened
            default: .closed
            }
            let terminalSince = situation == "oldClose" ? now.addingTimeInterval(-31 * 86_400) : now
            settings.retireMRProgress(for: target, state: state, terminalSince: terminalSince, now: now)
            #expect(settings.save())

            let restored = SettingsManager(defaults: defaults)
            let jobs = Dictionary(uniqueKeysWithValues: restored.assistantHandoffs.map { ($0.id, $0) })
            let shouldTrim = situation == "merged" || situation == "oldClose"
            #expect(jobs[referenced.id]?.execution?.output == "Display transcript")
            #expect(jobs[active.id]?.execution?.state == .running)
            #expect(jobs[queued.id]?.execution?.state == .queued)
            #expect(jobs[evidence.id]?.feedbackNoteIDs == [42])
            #expect((jobs[evidence.id]?.execution?.output == nil) == shouldTrim)
            #expect(jobs[otherAccount.id] != nil)
            #expect(displayJobs.filter { jobs[$0.id] != nil }.count == (shouldTrim ? 13 : 17))
            #expect(restored.boardPins.contains(pin) == !shouldTrim)
        }
    }

    @Test func successfulTranscriptsRoundTripWithoutBeingCopiedIntoEverySettingsSave() throws {
        try withDefaults { defaults in
            let settings = SettingsManager(defaults: defaults)
            var run = job()
            run.execution?.output = "Successful transcript kept in the compatibility payload"
            settings.assistantHandoffs = [run]
            #expect(settings.save())

            let archive = try #require(defaults.data(forKey: "mergeRequestRecords"))
            #expect(!String(decoding: archive, as: UTF8.self).contains("Successful transcript"))
            #expect(SettingsManager(defaults: defaults).assistantHandoffs.first?.execution?.output == run.execution?.output)
        }
    }

    @Test func invalidNewJournalPreservesRawBytesAndHoldsAutomationWithLegacyDataAvailable() throws {
        try withDefaults { defaults in
            let raw = Data(#"{"version":99}"#.utf8)
            defaults.set(raw, forKey: "mergeRequestRecords")
            defaults.set(try JSONEncoder().encode(Set([target])), forKey: "autoApproveOptOuts")
            let settings = SettingsManager(defaults: defaults)
            #expect(settings.autoApproveOptOuts == [target])
            #expect(!settings.automaticActionsAllowed)
            #expect(!settings.save())
            #expect(defaults.data(forKey: "mergeRequestRecords") == raw)
            #expect(defaults.data(forKey: "mergeRequestRecords.corrupt") == raw)
        }
    }

    private var conflictReceipt: MergeConflictReceipt {
        .init(host: target.host, userID: 21, projectID: target.projectID, iid: 11,
            sourceSHA: "synthetic-source", targetSHA: "synthetic-target", allowsPush: true, jobID: UUID(uuidString: "7BAD70AC-560D-445D-9BA2-795E12694719"))
    }

    private func job(username: String = "me", createdAt: Date = .distantPast) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: target.host, projectID: target.projectID, iid: 11),
            username: username, workspace: "", access: .gitLabRead),
            title: "Review", prompt: "Review", createdAt: createdAt, allowsPush: false,
            execution: .init(state: .succeeded))
    }

    private func request(_ state: String, iid: Int = 11, head: String? = String(repeating: "a", count: 40)) -> String {
        #"{"project_id":7,"iid":\#(iid),"author":{"id":21,"username":"me","name":"Viewer"},"title":"Fixture","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/\#(iid)","state":"\#(state)","draft":false,"sha":\#(head.map { "\"\($0)\"" } ?? "null"),"source_branch":"feature","target_branch":"main","labels":[]}"#
    }

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "MRSettingsRecordTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }
}
