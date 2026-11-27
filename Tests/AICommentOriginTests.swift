import Foundation
import Testing
@testable import MergeTether

@MainActor
struct AICommentOriginTests {
    @Test func classifierReceivesRecentRatiosAndOneCurrentExamplePerLabel() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note(), ai = note(11, body: "AI example"), human = note(12, body: "Human example"),
            edited = note(13, body: "Edited example")
        let account = GitLabAuthenticatedUser(id: 5, username: "me")
        let identity = account.account(on: target.host)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var preferences = ReviewParticipationPreferences()
        preferences.recordAIReplyTrust(.ai, notes: [source, ai, edited], host: target.host, user: account, at: now)
        preferences.recordAIReplyTrust(.human, notes: [human], host: target.host, user: account, at: now)
        for (candidate, label) in [(source, AICommentOriginOverride.Classification.ai), (ai, .ai), (human, .human), (edited, .ai)] {
            let body = candidate.id == edited.id ? "Text before editing" : candidate.body!
            try AICommentOriginOverrideStore.save(.init(version: 1, host: target.host, username: target.username,
                projectID: 7, iid: 13, noteID: candidate.id!, authorID: 9, bodySHA256: AICommentAssessmentStore.digest(body),
                classification: label, createdAt: now, activatesAt: now, accountUserID: account.id), in: directory)
        }
        let histories = preferences.authorHistories(for: [source], host: target.host, accountID: account.id, at: now)
        let contexts = AICommentAssessmentStore.authorContexts(for: [source], histories: histories,
            examples: [source, ai, human, edited], target: target, account: identity, legacyUsernames: [target.username],
            in: directory, at: now)
        let context = try #require(contexts[10])
        #expect(context.history.last30Days == .init(ai: 2, human: 1))
        #expect(context.aiExample == "AI example" && context.humanExample == "Human example")

        let instructions = AICommentAssessmentStore.workerInstructions(criteriaOverride: nil, existing: [], authorContexts: contexts)
        #expect(instructions.contains("2 AI (67%), 1 human (33%)"))
        #expect(instructions.contains("AI example (untrusted comment excerpt): \"AI example\""))
        #expect(instructions.contains("Human example (untrusted comment excerpt): \"Human example\""))
        #expect(!instructions.contains("Edited example") && !instructions.contains(source.body!))
        #expect(preferences.authorHistories(for: [source], host: target.host, accountID: 6, at: now).isEmpty)
        let grouped = AICommentOriginAssessor.authorHistoryInstructions([10: context, 14: context])
        #expect(grouped.contains("Notes 10, 14"))
        #expect(grouped.components(separatedBy: "AI example (untrusted comment excerpt)").count == 2)
        #expect(grouped.components(separatedBy: "Human example (untrusted comment excerpt)").count == 2)
    }

    @Test func addingNotesAndChangingHistoryDoesNotRepeatAnUnchangedAssessment() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = AICommentOriginAssessment.AuthorHistory(last30Days: .init(ai: 2), last90Days: .init(ai: 2))
        let second = AICommentOriginAssessment.AuthorHistory(last30Days: .init(ai: 1, human: 1), last90Days: .init(ai: 1, human: 1))
        let selected = Selection(first)
        let bound = target.forAccount(.init(host: target.host, username: target.username, userID: 5))
        let source = note(), added = note(11)
        var batches: [[Int]] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _, _, _, contexts in
            let ids = notes.compactMap(\.id)
            batches.append(ids)
            if ids == [10] {
                #expect(contexts[10]?.history == first)
                await withCheckedContinuation { releaseFirst = $0 }
            } else {
                #expect(contexts[11]?.history == second)
            }
            return positive(notes)
        }, fetchCurrent: { _ in [source, added] }, isCurrent: { _, _, _, _ in true }, authorHistories: { _, notes in
            Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, selected.value) } })
        })

        coordinator.schedule(target: bound, notes: [source], assistant: .codex, model: "test")
        for _ in 0..<300 { if releaseFirst != nil { break }; await Task.yield() }
        let release = try #require(releaseFirst)
        selected.value = second
        coordinator.schedule(target: bound, notes: [source, added], assistant: .codex, model: "test")
        release.resume()
        await settle(coordinator)
        coordinator.schedule(target: bound, notes: [source, added], assistant: .codex, model: "another-model")
        await settle(coordinator)

        #expect(batches == [[10], [11]])
        for note in [source, added] {
            #expect(AICommentAssessmentStore.assessment(for: note, host: target.host, projectID: 7, iid: 13,
                userID: 5, in: directory) != nil)
        }
    }

    @Test func customCriteriaSurvivesSettingsReloadAndCanBeRestoredToDefault() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        #expect(settings.aiCommentCriteria == AICommentOriginAssessor.criteriaInstructions)
        settings.aiCommentCriteria = "Check for the team's review-tool signature."

        var reloaded = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        #expect(reloaded.aiCommentCriteria == settings.aiCommentCriteria)
        reloaded.aiCommentCriteria = AICommentOriginAssessor.criteriaInstructions

        let restored = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(reloaded))
        #expect(restored.aiCommentCriteria == AICommentOriginAssessor.criteriaInstructions)
        #expect(restored.aiCommentCriteriaOverride == nil)

        reloaded.aiCommentCriteria = " \n "
        let blank = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(reloaded))
        #expect(blank.aiCommentCriteria == AICommentOriginAssessor.criteriaInstructions)
    }

    @Test func changingCriteriaRequiresNewPublicationEvidenceAndRestoringReusesDefaultEvidence() throws {
        let directory = try folder(), source = note()
        defer { try? FileManager.default.removeItem(at: directory) }
        let criteria = "Require a recognizable review-tool template."
        let customDirectory = AICommentAssessmentStore.scopedDirectory(directory, criteriaOverride: criteria)
        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source],
            assistant: .codex, model: "test", in: directory)

        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13,
            criteriaOverride: criteria, in: directory))
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))

        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source],
            assistant: .codex, model: "test", in: customDirectory)
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13,
            criteriaOverride: criteria, in: directory))
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13,
            criteriaOverride: "New prompt", in: directory))
    }

    @Test func assessmentUsesSelectedCriteriaAndDiscardsAnInFlightResultWhenTheyChange() async throws {
        let directory = try folder(), source = note()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = Selection("First prompt")
        var inputs: [String?] = []
        var first: CheckedContinuation<Void, Never>?
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _, _, criteria, _ in
            inputs.append(criteria)
            if criteria == "First prompt" { await withCheckedContinuation { first = $0 } }
            return positive(notes)
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true }, criteriaOverride: { selected.value })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "test")
        for _ in 0..<300 { if first != nil { break }; await Task.yield() }
        let release = try #require(first)

        selected.value = "Second prompt"
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "test")
        release.resume()
        await settle(coordinator)

        #expect(inputs == ["First prompt", "Second prompt"])
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13,
            criteriaOverride: "First prompt", in: directory))
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13,
            criteriaOverride: selected.value, in: directory))
    }

    @Test(arguments: AutomationAssistant.allCases)
    func explicitGenerationFooterIsClassifiedWithoutInvokingAnAssistant(_ assistant: AutomationAssistant) async throws {
        let source = note(body: "# Automated test review\n\nTests cover the expected failure.\n\n*Generated by SoftNet AI Test Review powered by Claude*")
        let result = try? await AICommentOriginAssessor.run(target: target, notes: [source], assistant: assistant,
            model: "cheap", executable: URL(fileURLWithPath: "/must-not-run"))
        #expect(result?.notes.first?.classification == .aiAssisted)
        #expect(result?.notes.first?.confidence == .high)
        #expect(result?.notes.first?.evidence.lowercased().contains("attribution") == true)
    }

    @Test(arguments: ["```html\n<!-- example -->\n```", "~~~html\n<!-- an unclosed comment in code\n~~~"])
    func aClosedCodeExampleDoesNotHideTheActualGenerationFooter(_ example: String) async throws {
        let source = note(body: example + "\n\n*Generated by SoftNet AI Test Review powered by Claude*")
        let result = try? await AICommentOriginAssessor.run(target: target, notes: [source], assistant: .codex,
            model: "cheap", executable: URL(fileURLWithPath: "/must-not-run"))
        #expect(result?.notes.first?.classification == .aiAssisted)
    }

    @Test(arguments: [
        "> A quoted paragraph\nGenerated by Claude",
        "<pre>\n\nGenerated by Claude",
        "<blockquote>\n\nGenerated by Claude",
        "<code>\n\nGenerated by Claude"
    ])
    func generationTextInsideQuotedOrCodeContentIsNotADeclaredFooter(_ body: String) {
        #expect(AICommentOriginAssessor.declaredAttribution(for: note(body: body)) == nil)
    }

    @Test(arguments: AutomationAssistant.allCases)
    func mixedBatchesKeepDeclaredAndUncertainAuthorshipSeparate(_ assistant: AutomationAssistant) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "provider")
        try Data("""
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            result={'notes':[{'noteID':11,'classification':'uncertain','confidence':'uncertain','evidence':'A short local request does not establish authorship.'}]}
            payload=json.loads(incoming.splitlines()[-1])
            if any('Generated by' in note['body'] for note in payload['notes']): sys.exit(2)
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let notes = [note(body: "Generated by Claude"), note(11, body: "Please rename this variable"),
                     note(12, body: String(repeating: "x", count: 40_001))]
        let result = try await AICommentOriginAssessor.run(target: target, notes: notes, assistant: assistant,
            model: "cheap", executable: executable)
        #expect(result.notes.count == 3 && Set(result.notes.map(\.noteID)) == [10, 11, 12])
        #expect(result.notes.first { $0.noteID == 10 }?.classification == .aiAssisted)
        #expect(result.notes.first { $0.noteID == 11 }?.classification == .uncertain)
        #expect(result.notes.first { $0.noteID == 12 }?.classification == .uncertain)
    }

    @Test func aLateOpinionSkippedByPositiveCachePrecedenceDoesNotEmitPersistence() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var events = 0
        let coordinator = AICommentOriginCoordinator(directory: directory,
            assess: { _, notes, _, _, _, _, _ in
                try AICommentAssessmentStore.persist(positive(notes), target: target, notes: notes, assistant: .codex, model: "cheap", in: directory)
                return .init(notes: notes.map { .init(noteID: $0.id!, classification: .uncertain,
                    confidence: .uncertain, evidence: "A late lightweight opinion") })
            }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in true })
        coordinator.onPersisted = { _, _, _ in events += 1 }
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.isChecking(work: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(events == 0 && coordinator.failure(work: work) == nil)
        #expect(AICommentAssessmentStore.isAI(note(), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test func aPersistenceFailureDoesNotEmitAStoredOriginEvent() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Blocked record folder".utf8).write(to: directory.appending(path: target.host))
        var calls = 0, events = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, purpose: .display,
            assess: { _, notes, _, _, _, _, _ in calls += 1; return positive(notes) },
            fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in })
        coordinator.onPersisted = { _, _, _ in events += 1 }
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.isChecking(work: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!coordinator.isChecking(work: work) && coordinator.failure(work: work) != nil)
        #expect(calls == 1 && events == 0)
    }

    @Test func originPersistenceNotificationFiresOnlyForSuccessfullyStoredNewResults() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var failed = false, events: [[Int]] = []
        let coordinator = AICommentOriginCoordinator(directory: directory, purpose: .display,
            assess: { _, notes, _, _, _, _, _ in
                if failed { throw AICommentOriginAssessor.AssessmentError.invalidEvidence }
                return positive(notes)
            }, fetchCurrent: { _ in [note(10), note(11)] }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in })
        coordinator.onPersisted = { _, notes, assessment in
            events.append(notes.compactMap(\.id))
            #expect(assessment.notes.map(\.noteID) == notes.compactMap(\.id))
            #expect(AICommentAssessmentStore.result(for: notes[0], host: target.host, projectID: 7, iid: 13, in: directory)?.purpose == .display)
        }
        @MainActor func finish() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while coordinator.isChecking(work: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(!coordinator.isChecking(work: work))
        }
        coordinator.schedule(target: target, notes: [note(10)], assistant: .codex, model: "cheap")
        try await finish()
        #expect(events == [[10]])
        coordinator.schedule(target: target, notes: [note(10)], assistant: .codex, model: "cheap")
        try await finish()
        #expect(events == [[10]])
        failed = true
        coordinator.schedule(target: target, notes: [note(11)], assistant: .codex, model: "cheap")
        try await finish()
        #expect(events == [[10]])
    }

    @Test func displayBatchesRetainEarlierFailuresForTheExistingRetryBoundary() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls: [Int] = [], fail = true
        var retryDelays: [Duration] = []
        let coordinator = AICommentOriginCoordinator(directory: directory, purpose: .display,
            assess: { _, notes, _, _, _, _, _ in
                calls += notes.compactMap(\.id)
                if fail && notes.first?.id == 10 { throw AICommentOriginAssessor.AssessmentError.invalidEvidence }
                return positive(notes)
            }, fetchCurrent: { _ in [note(10), note(11)] }, isCurrent: { _, _, _, _ in true },
            retryWait: { retryDelays.append($0) })
        @MainActor func waitForIdle() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while coordinator.isChecking(work: work), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(!coordinator.isChecking(work: work))
        }
        coordinator.schedule(target: target, notes: [note(10)], assistant: .codex, model: "cheap")
        try await waitForIdle()
        #expect(calls == [10, 10, 10] && retryDelays == [.seconds(2), .seconds(8)])
        #expect(coordinator.failure(work: work) != nil)
        coordinator.schedule(target: target, notes: [note(11)], assistant: .codex, model: "cheap")
        try await waitForIdle()
        #expect(coordinator.failure(work: work) != nil)
        coordinator.schedule(target: target, notes: [note(10)], assistant: .codex, model: "cheap")
        try await waitForIdle()
        #expect(calls == [10, 10, 10, 11])
        fail = false
        coordinator.retryReadOnlyFailures()
        coordinator.schedule(target: target, notes: [note(10)], assistant: .codex, model: "cheap")
        try await waitForIdle()
        #expect(calls == [10, 10, 10, 11, 10])
        #expect(coordinator.failure(work: work) == nil)
    }

    @Test func displayPurposeCannotAuthorizePublicationEvenWhenItsDirectoryIsPassedToActionAPIs() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source],
            assistant: .codex, model: "cheap", purpose: .display, in: directory)
        #expect(AICommentAssessmentStore.result(for: source, host: target.host, projectID: 7, iid: 13, in: directory)?.purpose == .display)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [source])]
        let draft = GitLabDraftNote(id: 11, authorID: 5, note: "Reply", discussionID: "thread", position: nil)
        #expect(!AICommentAssessmentStore.eligible(draft, discussions: discussions, userID: 5, duoUserIDs: [],
            host: target.host, projectID: 7, iid: 13, in: directory))
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        let storedJSON = try JSONSerialization.jsonObject(with: SealedAssessmentFile.payload(at: path))
        var raw = try #require(storedJSON as? [String: Any])
        raw["purpose"] = "unrecognized"
        try JSONSerialization.data(withJSONObject: raw).write(to: path)
        #expect(AICommentAssessmentStore.result(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    @Test func aSavedDisplayVerdictPreventsAnotherAssessmentAndOnlySealedEvidenceIsReusableForPublishing() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let display = AICommentAssessmentStore.displayDirectory(for: directory)
        let source = note(), bound = target.forAccount(.init(host: target.host, username: target.username, userID: 5))
        try AICommentAssessmentStore.persist(positive([source]), target: bound, notes: [source],
            assistant: .codex, model: "cheap", purpose: .display, in: display)
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, _, _, _, _, _, _ in
            Issue.record("A saved display decision must be reused for the unchanged source")
            throw CancellationError()
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true },
            criteriaOverride: { "New prompt for future evaluations" })
        coordinator.schedule(target: bound, notes: [source], assistant: .codex, model: "different-model")
        await settle(coordinator)
        #expect(AICommentAssessmentStore.sealedDisplayAssessment(for: source, host: target.host, projectID: 7, iid: 13,
            userID: 5, legacyUsernames: [], in: display) != nil)
        #expect(AICommentAssessmentStore.sealedDisplayAssessment(for: source, host: target.host, projectID: 7, iid: 13,
            userID: 6, legacyUsernames: [], in: display) == nil)
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, userID: 5, in: display)
        let payload = try SealedAssessmentFile.payload(at: path)
        try payload.write(to: path)
        #expect(AICommentAssessmentStore.sealedDisplayAssessment(for: source, host: target.host, projectID: 7, iid: 13,
            userID: 5, legacyUsernames: [], in: display) == nil)
    }

    @Test func pendingDisplayOpinionCannotBeRestoredAsAnActionOpinion() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let verdict = try #require(positive([note()]).notes.first)
        try AICommentAssessmentStore.preservePendingVerdict(verdict, for: note(), target: target,
            assistant: .codex, model: "cheap", purpose: .display, in: directory)
        let pending = try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", purpose: .display, in: directory)
        let restored = try #require(pending)
        #expect(restored.noteID == verdict.noteID && restored.classification == verdict.classification)
        #expect(try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", in: directory) == nil)
    }

    @MainActor private final class Selection<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @MainActor private final class RetryState {
        var calls = 0
        var reads = 0
        var now = Date()
        var recovered = false
    }

    @Test(arguments: ["assessment", "live-read"])
    func transientReadOnlyFailureRetriesWithoutAnotherPoll(_ stage: String) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        var calls = 0
        var reads = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _, _, _, _ in
            calls += 1
            if stage == "assessment" && calls == 1 { throw AICommentOriginAssessor.AssessmentError.failed }
            return positive(notes)
        }, fetchCurrent: { _ in
            reads += 1
            if stage == "live-read" && reads == 1 { throw AICommentOriginAssessor.AssessmentError.failed }
            return [source]
        }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.isChecking(work: work), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(calls == (stage == "assessment" ? 2 : 1))
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: [AICommentOriginAssessment.Classification.uncertain, .manualLikely])
    func completedNonAIVerdictSurvivesFinalReadFailuresAndCooldown(_ classification: AICommentOriginAssessment.Classification) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = RetryState()
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            state.calls += 1
            if state.calls > 1 { return positive(incoming) }
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: classification,
                confidence: .uncertain, evidence: "The completed assessment does not establish AI assistance.") })
        }, fetchCurrent: { _ in
            state.reads += 1
            if !state.recovered { throw AICommentOriginAssessor.AssessmentError.failed }
            return [note()]
        }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() }, now: { state.now })
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(state.calls == 1 && state.reads == 3)
        #expect(coordinator.failure(work: work) != nil)
        state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        state.recovered = true
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(state.calls == 1 && state.reads == 4)
        #expect(coordinator.failure(work: work) == nil)
        let stored = try #require(AICommentAssessmentStore.result(for: note(), host: target.host, projectID: 7, iid: 13, in: directory))
        #expect(stored.classification == classification.rawValue)
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        let metadata = try #require(JSONSerialization.jsonObject(with: SealedAssessmentFile.payload(at: path)) as? [String: Any])
        #expect(metadata["thinking"] as? String == "high")
        #expect(metadata["username"] as? String == target.username)
        #expect(metadata["authorID"] as? Int == 9)
        #expect(!AICommentAssessmentStore.isAI(note(), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: [AICommentOriginAssessment.Classification.uncertain, .manualLikely, .aiAssisted])
    func completedVerdictSurvivesRestartBeforeFinalSourceVerification(_ classification: AICommentOriginAssessment.Classification) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = RetryState()
        do {
            let original = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
                state.calls += 1
                return .init(notes: incoming.map { .init(noteID: $0.id!, classification: classification,
                    confidence: classification == .aiAssisted ? .veryHigh : .uncertain,
                    evidence: "A completed semantic assessment awaiting live source verification.") })
            }, fetchCurrent: { _ in
                state.reads += 1
                throw AICommentOriginAssessor.AssessmentError.failed
            }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() }, now: { state.now })
            original.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
            await settle(original)
            #expect(state.calls == 1 && state.reads == 3)
            #expect(AICommentAssessmentStore.result(for: note(), host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        }
        state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        let restarted = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            state.calls += 1
            return positive(incoming)
        }, fetchCurrent: { _ in state.reads += 1; return [note()] }, isCurrent: { _, _, _, _ in true },
            retryWait: { _ in await Task.yield() }, now: { state.now })
        restarted.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(restarted)
        #expect(state.calls == 1 && state.reads == 4)
        let stored = try #require(AICommentAssessmentStore.result(for: note(), host: target.host, projectID: 7, iid: 13, in: directory))
        #expect(stored.classification == classification.rawValue)
        #expect(stored.qualifiesAsAI == (classification == .aiAssisted))
    }

    @Test func completedPendingVerdictIsNotReusedAfterSourceAuthorChanges() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = RetryState()
        let original = note()
        let changed = GitLabMergeRequestDiscussion.Note(id: original.id,
            author: .init(id: 19, username: "different-author", name: "Different Author"),
            system: false, resolvable: nil, resolved: nil, resolvedBy: nil, body: original.body)
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            state.calls += 1
            if state.calls > 1 { return positive(incoming) }
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: .uncertain,
                confidence: .uncertain, evidence: "A verdict tied to the original source author.") })
        }, fetchCurrent: { _ in
            if !state.recovered { throw AICommentOriginAssessor.AssessmentError.failed }
            return [changed]
        }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() }, now: { state.now })
        coordinator.schedule(target: target, notes: [original], assistant: .codex, model: "cheap")
        await settle(coordinator)
        state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        state.recovered = true
        coordinator.schedule(target: target, notes: [changed], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(state.calls == 2)
        #expect(AICommentAssessmentStore.isAI(changed, host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: ["body", "author", "note", "account", "host", "project", "mr", "model", "provider"])
    func durablePendingVerdictCannotCrossItsSourceOrAssessmentContext(_ changed: String) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let pending = AICommentOriginAssessment.Note(noteID: 10, classification: .uncertain,
            confidence: .uncertain, evidence: "Only the original exact assessment context was verified.")
        try AICommentAssessmentStore.preservePendingVerdict(pending, for: source, target: target,
            assistant: .codex, model: "cheap", in: directory)
        let nextTarget = MRAutomationScope.Target(host: changed == "host" ? "other.example.test" : target.host,
            username: changed == "account" ? "other-account" : target.username,
            projectID: changed == "project" ? 8 : target.projectID, iid: changed == "mr" ? 14 : target.iid)
        let nextSource = GitLabMergeRequestDiscussion.Note(id: changed == "note" ? 11 : source.id,
            author: .init(id: changed == "author" ? 19 : 9, username: "person", name: "Person"),
            system: false, resolvable: nil, resolved: nil, resolvedBy: nil,
            body: changed == "body" ? "An edited source body" : source.body)
        var calls = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            calls += 1; return positive(incoming)
        }, fetchCurrent: { _ in [nextSource] }, isCurrent: { _, _, _, _ in true })
        coordinator.schedule(target: nextTarget, notes: [nextSource], assistant: changed == "provider" ? .claude : .codex,
            model: changed == "model" ? "different-model" : "cheap")
        let nextIID = try #require(nextTarget.iid)
        let nextWork = AssistantAutomationRunner.MergeRequestWork(host: nextTarget.host, projectID: nextTarget.projectID, iid: nextIID)
        for _ in 0..<300 {
            await Task.yield()
            if !coordinator.isChecking(work: nextWork) { break }
        }
        #expect(calls == 1)
        #expect(AICommentAssessmentStore.isAI(nextSource, host: nextTarget.host,
            projectID: nextTarget.projectID, iid: nextIID, in: directory))
    }

    @Test func unreadablePendingVerdictCannotSolicitAnotherOpinion() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        try AICommentAssessmentStore.preservePendingVerdict(.init(noteID: 10, classification: .manualLikely,
            confidence: .high, evidence: "The completed opinion must not be replaced by another vote."),
            for: source, target: target, assistant: .codex, model: "cheap", in: directory)
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let jsonFiles = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        let path = try #require(jsonFiles.first)
        try Data("malformed pending verdict".utf8).write(to: path)
        var calls = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            calls += 1; return positive(incoming)
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 0)
        #expect(coordinator.failure(work: work) != nil)
        #expect(AICommentAssessmentStore.result(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    @Test(arguments: ["cooldown", "dependency"])
    func exhaustedReadOnlyBudgetDoesNotRestartOnLaterPolls(_ recovery: String) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = RetryState()
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            state.calls += 1
            if state.recovered { return positive(incoming) }
            throw AICommentOriginAssessor.AssessmentError.failed
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() }, now: { state.now })
        for _ in 0..<3 {
            coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
            await settle(coordinator)
        }
        #expect(state.calls == 3)
        #expect(coordinator.failure(work: work)?.isEmpty == false)
        #expect(!coordinator.isChecking(work: work))
        #expect(!AICommentAssessmentStore.isAI(note(), host: target.host, projectID: 7, iid: 13, in: directory))
        if recovery == "cooldown" { state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1) }
        else { coordinator.retryReadOnlyFailures() }
        state.recovered = true
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(state.calls == 4)
        #expect(coordinator.failure(work: work) == nil)
        #expect(AICommentAssessmentStore.isAI(note(), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: [AICommentOriginAssessment.Classification.uncertain, .manualLikely])
    func successfulNonAIOriginRemainsPrivateAfterFailureCooldown(_ classification: AICommentOriginAssessment.Classification) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        var clock = Date()
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            calls += 1
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: classification,
                confidence: .uncertain, evidence: "Current source evidence remains uncertain.") })
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in true }, now: { clock })
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        clock = clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
        #expect(coordinator.failure(work: work) == nil)
        #expect(!AICommentAssessmentStore.isAI(note(), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test func cancellationDuringReadOnlyBackoffCannotPersistOrRetry() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        var current = true
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, _, _, _, _, _, _ in
            calls += 1
            throw AICommentOriginAssessor.AssessmentError.failed
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in current }, retryWait: { _ in current = false })
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
        #expect(!coordinator.isChecking(work: work))
        #expect(coordinator.failure(work: work) == nil)
        #expect(AICommentAssessmentStore.result(for: note(), host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13)
    private var work: AssistantAutomationRunner.MergeRequestWork { .init(host: target.host, projectID: 7, iid: 13) }
    private func note(_ id: Int = 10, body: String = "A detailed review with a suggested patch") -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: .init(id: 9, username: "person", name: "Person"), system: false,
              resolvable: nil, resolved: nil, resolvedBy: nil, body: body)
    }
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func settle(_ coordinator: AICommentOriginCoordinator) async {
        for _ in 0..<300 {
            await Task.yield()
            if !coordinator.isChecking(work: work) { break }
        }
    }
    private func positive(_ notes: [GitLabMergeRequestDiscussion.Note]) -> AICommentOriginAssessment {
        .init(notes: notes.map { .init(noteID: $0.id!, classification: .aiAssisted, confidence: .veryHigh,
            evidence: "Several specific content and context signals support substantial AI assistance.") })
    }

    @Test(arguments: ["high", "very_high", "uncertain", "manual_high", "manual_very_high", "unknown_high"])
    func highConfidenceQualifiesOnlyAnAIClassificationForTheExactBody(_ variant: String) throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let classification = variant.hasPrefix("manual_") ? "manual_likely"
            : variant.hasPrefix("unknown_") ? "uncertain" : "ai_assisted"
        let confidence = variant.replacingOccurrences(of: "manual_", with: "").replacingOccurrences(of: "unknown_", with: "")
        let record = AICommentAssessment(version: 2, host: target.host, projectID: 7, iid: 13, noteID: 10,
            bodySHA256: AICommentAssessmentStore.digest(source.body!), confidence: confidence,
            evidence: "Combined content signals assessed for this exact comment.", classification: classification)
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SealedAssessmentFile.write(record, to: path)
        let expected = variant == "high" || variant == "very_high"
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory) == expected)
        #expect(!AICommentAssessmentStore.isAI(note(body: "Edited source"), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: ["manual_likely", "uncertain"])
    func earlierCriteriaResultsStayVisibleWithoutAnotherAssessment(_ classification: String) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let old = AICommentAssessment(version: 2, host: target.host, projectID: 7, iid: 13, noteID: 10,
            bodySHA256: AICommentAssessmentStore.digest(source.body!), confidence: "uncertain",
            evidence: "Previous criteria did not consider combined signals.", classification: classification,
            provider: AutomationAssistant.codex.rawValue, model: "cheap")
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: path)
        var calls = 0
        let assess: AICommentOriginCoordinator.Assess = { _, notes, _, _, _, _, _ in
            calls += 1
            return .init(notes: notes.map { .init(noteID: $0.id!, classification: .aiAssisted, confidence: .high,
                evidence: "Precise cross-code references with consistent formatting and polished language.") })
        }
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: assess,
            fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 0)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
        let saved = try JSONDecoder().decode(AICommentAssessment.self, from: Data(contentsOf: path))
        #expect(saved == old)
        let restarted = AICommentOriginCoordinator(directory: directory, assess: assess,
            fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true })
        restarted.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(restarted)
        #expect(calls == 0)
    }

    @Test func legacyEvidenceArraysNormalizeWithoutTreatingHumanAccountAsNegative() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = note()
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = ["version": 1, "host": target.host, "projectID": 7, "iid": 13, "noteID": 10,
            "bodySHA256": AICommentAssessmentStore.digest(note.body!), "confidence": "very_high",
            "evidence": ["Generated review structure", "Specific supporting context"]]
        try SealedAssessmentFile.write(JSONSerialization.data(withJSONObject: record), to: path)
        let assessment = AICommentAssessmentStore.assessment(for: note, host: target.host, projectID: 7, iid: 13, in: directory)
        #expect(assessment?.evidence == "Generated review structure\nSpecific supporting context")
        #expect(AICommentAssessmentStore.assessment(for: self.note(body: "Edited"), host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    @Test func malformedIncompleteAndUnsupportedHighConfidenceResultsAreRejected() throws {
        let valid = positive([note()])
        try AICommentOriginAssessor.validate(valid, noteIDs: [10])
        #expect(throws: (any Error).self) { try AICommentOriginAssessor.validate(.init(notes: []), noteIDs: [10]) }
        #expect(throws: (any Error).self) { try AICommentOriginAssessor.validate(.init(notes: valid.notes + valid.notes), noteIDs: [10]) }
        #expect(throws: (any Error).self) { try AICommentOriginAssessor.validate(valid, noteIDs: [11]) }
        let blank = AICommentOriginAssessment(notes: [.init(noteID: 10, classification: .aiAssisted, confidence: .veryHigh, evidence: " ")])
        #expect(throws: (any Error).self) { try AICommentOriginAssessor.validate(blank, noteIDs: [10]) }
        let huge = AICommentOriginAssessment(notes: [.init(noteID: 10, classification: .aiAssisted, confidence: .veryHigh, evidence: String(repeating: "x", count: 601))])
        #expect(throws: (any Error).self) { try AICommentOriginAssessor.validate(huge, noteIDs: [10]) }
    }

    @Test func proactiveClassificationPersistsExactBodyAndCachesUnknownWithoutAWorkerOrDraftCount() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let notes = [note(), note(11, body: "Please rename the variable")]
        var calls = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            calls += 1
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: $0.id == 10 ? .aiAssisted : .uncertain,
                confidence: $0.id == 10 ? .veryHigh : .uncertain, evidence: "Content and context assessment; not based on account name.") })
        }, fetchCurrent: { _ in notes }, isCurrent: { _, _, _, _ in true })
        coordinator.schedule(target: target, notes: notes, assistant: .codex, model: "cheap")
        #expect(coordinator.isChecking(work: work))
        await settle(coordinator)
        #expect(AICommentAssessmentStore.assessment(for: notes[0], host: target.host, projectID: 7, iid: 13, in: directory) != nil)
        #expect(AICommentAssessmentStore.assessment(for: notes[1], host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        let unknownPath = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 11, in: directory)
        #expect(FileManager.default.fileExists(atPath: unknownPath.path))
        coordinator.schedule(target: target, notes: notes, assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
    }

    @Test func changedLiveBodyOrAccountCannotGainARecordAndFailuresHaveABoundedBudget() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        var calls = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _, _, _, _ in
            calls += 1; return positive(notes)
        }, fetchCurrent: { _ in [note(body: "Changed while assessing")] }, isCurrent: { _, _, _, _ in true })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        let failedDirectory = try folder(); defer { try? FileManager.default.removeItem(at: failedDirectory) }
        var failedCalls = 0
        let failed = AICommentOriginCoordinator(directory: failedDirectory, assess: { _, _, _, _, _, _, _ in
            failedCalls += 1; throw AICommentOriginAssessor.AssessmentError.failed
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in true }, retryWait: { _ in await Task.yield() })
        for _ in 0..<3 {
            failed.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
            await settle(failed)
        }
        #expect(failedCalls == 3)
        #expect(failed.failure(work: work) != nil && !failed.isChecking(work: work))
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: failedDirectory) == nil)
        let obsoleteDirectory = try folder(); defer { try? FileManager.default.removeItem(at: obsoleteDirectory) }
        var current = true
        var obsoleteCalls = 0
        let obsolete = AICommentOriginCoordinator(directory: obsoleteDirectory, assess: { _, notes, _, _, _, _, _ in
            obsoleteCalls += 1; current = false; return positive(notes)
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _, _ in current })
        obsolete.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(obsolete)
        #expect(obsoleteCalls == 1)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: obsoleteDirectory) == nil)
    }

    @Test func oversizedBodyRemainsUnknownWithoutInvokingAnExecutable() async throws {
        let result = try await AICommentOriginAssessor.run(target: target, notes: [note(body: String(repeating: "x", count: 40_001))],
            assistant: .codex, model: "cheap", executable: URL(fileURLWithPath: "/must-not-run"))
        #expect(result.notes.first?.classification == .uncertain)
        #expect(result.notes.first?.confidence == .uncertain)
    }

    @Test func atMostTwoTargetsRunAndCancellationCannotWriteStaleAssessments() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var waiting: [CheckedContinuation<Void, Never>] = []
        var active = 0
        var maximum = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _, _, _, _ in
            active += 1; maximum = max(maximum, active)
            await withCheckedContinuation { waiting.append($0) }
            active -= 1
            return positive(notes)
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, _ in true })
        for iid in 13...15 {
            coordinator.schedule(target: .init(host: target.host, username: target.username, projectID: 7, iid: iid),
                notes: [note()], assistant: .codex, model: "cheap")
        }
        for _ in 0..<30 { await Task.yield() }
        #expect(active == 2)
        #expect(maximum == 2)
        coordinator.cancel()
        for continuation in waiting { continuation.resume() }
        for _ in 0..<30 { await Task.yield() }
        #expect(!coordinator.isChecking(work: work))
        #expect(AICommentAssessmentStore.assessment(for: note(), host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    @Test(arguments: AutomationAssistant.allCases, [false, true])
    func assessorKeepsFullCLIExecutionAndAReadOnlyUntrustedContentRole(_ assistant: AutomationAssistant, custom: Bool) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "provider")
        try Data("""
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            incoming=sys.stdin.read()
            codex=args[0]=='exec'
            text=(incoming if codex else args[args.index('-p')+1]+' '+incoming).lower()
            full=('--dangerously-bypass-approvals-and-sandbox' in args) if codex else ('--dangerously-skip-permissions' in args and '--tools' in args and 'default' in args)
            role=all(token in text for token in ['read-only','do not publish','untrusted','ai-assisted'])
            role=role and all(token in text for token in ['last 30 days: 2 ai (67%), 1 human (33%)',
                'last 90 days: 3 ai (60%), 2 human (40%)', 'synthetic ai excerpt', 'synthetic human excerpt'])
            custom='look for the team review format' in text
            role=role and custom==\(custom ? "True" : "False") and ('probabilistic' in text) != custom
            high=('model_reasoning_effort=\"high\"' in args) if codex else (args[args.index('--effort')+1]=='high')
            full=full and high
            result={'notes':[{'noteID':10,'classification':'ai_assisted' if full and role else 'uncertain','confidence':'very_high' if full and role else 'uncertain','evidence':'Grounded content assessment without relying on the account name.'}]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let history = AICommentOriginAssessment.AuthorHistory(
            last30Days: .init(ai: 2, human: 1), last90Days: .init(ai: 3, human: 2))
        let result = try await AICommentOriginAssessor.run(target: target, notes: [note()], assistant: assistant,
            model: "cheap", criteriaOverride: custom ? "Look for the team review format." : nil,
            authorContexts: [10: .init(history: history, aiExample: "Synthetic AI excerpt", humanExample: "Synthetic human excerpt")],
            executable: executable)
        #expect(result.notes.first?.classification == .aiAssisted)
        #expect(result.notes.first?.confidence == .veryHigh)
    }

    @Test(arguments: AutomationAssistant.allCases, [VerificationThinking.low, .medium])
    func assessorUsesSelectedLowerThinking(_ assistant: AutomationAssistant, _ thinking: VerificationThinking) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "provider")
        let argumentsURL = directory.appending(path: "arguments.json")
        try Data("""
            #!/usr/bin/python3
            import json,sys
            args=sys.argv[1:]
            sys.stdin.read()
            json.dump(args,open(\(String(reflecting: argumentsURL.path)),'w'))
            result={'notes':[{'noteID':10,'classification':'uncertain','confidence':'uncertain','evidence':'The source evidence does not establish AI origin.'}]}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        _ = try await AICommentOriginAssessor.run(target: target, notes: [note()], assistant: assistant,
            model: "cheap", thinking: thinking, executable: executable)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: argumentsURL))
        if assistant == .codex {
            #expect(arguments.contains("model_reasoning_effort=\"\(thinking.rawValue)\""))
        } else {
            let index = try #require(arguments.firstIndex(of: "--effort"))
            #expect(arguments[index + 1] == thinking.rawValue)
        }
    }

    @Test(arguments: [AICommentOriginAssessment.Classification.uncertain, .manualLikely, .aiAssisted])
    func confirmedVerdictsSurviveAChangeInThinking(_ classification: AICommentOriginAssessment.Classification) async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var seen: [VerificationThinking] = []
        let selected = Selection(VerificationThinking.low)
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, thinking, _, _ in
            seen.append(thinking)
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: classification,
                confidence: classification == .aiAssisted ? .high : .uncertain, evidence: "A completed assessment for this exact source.") })
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, thinking in thinking == selected.value })
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap", thinking: .low)
        await settle(coordinator)
        selected.value = .high
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap", thinking: .high)
        await settle(coordinator)
        #expect(seen == [.low])
    }

    @Test func changingThinkingDiscardsAnInFlightOriginAssessment() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let selected = Selection(VerificationThinking.low)
        var continuation: CheckedContinuation<Void, Never>?
        var seen: [VerificationThinking] = []
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, thinking, _, _ in
            seen.append(thinking)
            if thinking == .low { await withCheckedContinuation { continuation = $0 }; return positive(incoming) }
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: .manualLikely,
                confidence: .high, evidence: "The current assessment supports a manual source.") })
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _, thinking in selected.value == thinking })
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap", thinking: .low)
        for _ in 0..<300 { if continuation != nil { break }; await Task.yield() }
        let release = try #require(continuation)
        selected.value = .high
        coordinator.schedule(target: target, notes: [note()], assistant: .codex, model: "cheap", thinking: .high)
        release.resume()
        await settle(coordinator)
        #expect(seen == [.low, .high])
        let result = try #require(AICommentAssessmentStore.result(for: note(), host: target.host, projectID: 7, iid: 13, in: directory))
        #expect(result.thinking == .high)
        #expect(result.classification == "manual_likely")
        #expect(try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .low, in: directory) == nil)
    }

    @Test func pendingVerdictsRetainEachThinkingContext() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let uncertain = AICommentOriginAssessment.Note(noteID: 10, classification: .uncertain,
            confidence: .uncertain, evidence: "The completed low-effort assessment remains uncertain.")
        try AICommentAssessmentStore.preservePendingVerdict(uncertain, for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .low, in: directory)
        #expect(try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .high, in: directory) == nil)
        try AICommentAssessmentStore.preservePendingVerdict(positive([note()]).notes[0], for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .high, in: directory)
        let restored = try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .low, in: directory)
        #expect(restored?.classification == .uncertain)
        #expect(restored?.evidence == uncertain.evidence)
    }

    @Test func legacyPendingVerdictRemainsBoundToItsOriginalMediumEffort() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try AICommentAssessmentStore.preservePendingVerdict(.init(noteID: 10, classification: .manualLikely,
            confidence: .high, evidence: "A legacy completed verdict must not solicit another opinion."),
            for: note(), target: target, assistant: .codex, model: "cheap", thinking: .medium, in: directory)
        let pendingDirectory = directory.appending(path: ".pending-origin-verdicts")
        let path = try #require(FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil).first)
        let payload = try #require(try EvidenceSeal.open(Data(contentsOf: path),
            context: AICommentAssessmentStore.pendingSealContext(for: path)))
        var journal = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var context = try #require(journal["context"] as? [String: Any])
        context.removeValue(forKey: "thinking")
        journal["context"] = context
        let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
        let legacyPath = pendingDirectory.appending(path: AICommentAssessmentStore.digest(String(decoding: contextData, as: UTF8.self)) + ".json")
        try JSONSerialization.data(withJSONObject: journal).write(to: legacyPath)
        try FileManager.default.removeItem(at: path)
        #expect(try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .medium, in: directory)?.classification == .manualLikely)
        #expect(try AICommentAssessmentStore.pendingVerdict(for: note(), target: target,
            assistant: .codex, model: "cheap", thinking: .high, in: directory) == nil)
    }

    @Test func anUnsealedWorkerPositiveNeitherAuthorizesNorSurvivesTheAppsOwnAssessment() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let notes = [note(), note(11, body: "A second source with uncertain origin")]
        var release: CheckedContinuation<Void, Never>?
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _, _, _, _ in
            await withCheckedContinuation { release = $0 }
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: .uncertain,
                confidence: .uncertain, evidence: "The source text does not establish AI assistance.") })
        }, fetchCurrent: { _ in notes }, isCurrent: { _, _, _, _ in true })
        coordinator.schedule(target: target, notes: notes, assistant: .codex, model: "cheap")
        for _ in 0..<300 { if release != nil { break }; await Task.yield() }
        let continuation = try #require(release)
        let workerRecord = AICommentAssessment(version: 1, host: target.host, projectID: 7, iid: 13, noteID: 10,
            bodySHA256: AICommentAssessmentStore.digest(notes[0].body!), confidence: "very_high", evidence: "Worker assessed this exact source body.")
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(workerRecord).write(to: path, options: .atomic)
        // A plain record written outside the app is visible as a hint but never counts as AI.
        #expect(AICommentAssessmentStore.result(for: notes[0], host: target.host, projectID: 7, iid: 13, in: directory) != nil)
        #expect(AICommentAssessmentStore.assessment(for: notes[0], host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        continuation.resume()
        await settle(coordinator)
        for note in notes {
            let stored = try #require(AICommentAssessmentStore.stored(for: note, host: target.host, projectID: 7, iid: 13, in: directory))
            #expect(stored.sealed && stored.record.classification == "uncertain")
            #expect(AICommentAssessmentStore.assessment(for: note, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        }
    }

    @Test func onlyAnAppSealedRecordForTheSameMergeRequestAndNoteQualifies() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let record = AICommentAssessment(version: 2, host: target.host, projectID: 7, iid: 13, noteID: 10,
            bodySHA256: AICommentAssessmentStore.digest(source.body!), confidence: "very_high", evidence: "Exact AI provenance.")
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try JSONEncoder().encode(record)
        // A seal made for another MR's note cannot be moved onto this one.
        let otherPath = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 14, noteID: 10, in: directory)
        try EvidenceSeal.seal(payload, context: AICommentAssessmentStore.sealContext(for: otherPath)).write(to: path)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        try EvidenceSeal.seal(payload, context: AICommentAssessmentStore.sealContext(for: path)).write(to: path)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: directory) != nil)
    }

    @Test func unsealedPendingAIResultCannotAuthorizePublication() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let verdict = try #require(positive([source]).notes.first)
        try AICommentAssessmentStore.preservePendingVerdict(verdict, for: source, target: target,
            assistant: .codex, model: "cheap", purpose: .publication, in: directory)
        let path = try #require(FileManager.default.contentsOfDirectory(
            at: directory.appending(path: ".pending-origin-verdicts"), includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: path)
        let legacyPayload = try #require(EvidenceSeal.open(data, context: AICommentAssessmentStore.pendingSealContext(for: path)))
        try legacyPayload.write(to: path)
        #expect(try AICommentAssessmentStore.pendingVerdict(for: source, target: target, assistant: .codex,
            model: "cheap", purpose: .publication, in: directory) == nil)
    }

    @Test func sealedAssessmentCannotChangeCriteriaDirectories() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source], assistant: .codex,
            model: "cheap", in: directory)
        let refined = AICommentAssessmentStore.scopedDirectory(directory, criteriaOverride: "Apply more selective criteria")
        let from = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        let to = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: refined)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: from, to: to)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: refined) == nil)
    }

    @Test func unsealedOverridesCanOnlyNarrowPublication() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let key = AICommentOriginOverrideStore.Key(host: target.host, projectID: 7, iid: 13, noteID: 10)
        func record(_ classification: AICommentOriginOverride.Classification) -> AICommentOriginOverride {
            .init(version: 1, host: target.host, username: target.username, projectID: 7, iid: 13, noteID: 10,
                  authorID: source.author!.id, bodySHA256: AICommentAssessmentStore.digest(source.body!),
                  classification: classification, createdAt: .distantPast, activatesAt: .distantPast)
        }
        let path = AICommentOriginOverrideStore.fileURL(key, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record(.ai)).write(to: path)
        #expect(AICommentOriginOverrideStore.stored(key, in: directory) == nil)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
        try encoder.encode(record(.human)).write(to: path)
        #expect(AICommentOriginOverrideStore.stored(key, in: directory)?.classification == .human)
        try AICommentOriginOverrideStore.save(record(.ai), in: directory)
        #expect(AICommentOriginOverrideStore.stored(key, in: directory)?.classification == .ai)
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
    }
}
