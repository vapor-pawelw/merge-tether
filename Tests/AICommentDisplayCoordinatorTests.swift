import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor struct AICommentDisplayCoordinatorTests {
    @Test func independentPersistedOriginObserversCoexistAndCanBeRemoved() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        let coordinator = f.coordinator()
        var first = 0, second = 0
        let firstID = coordinator.observePersistedOrigins { _ in first += 1 }
        let secondID = coordinator.observePersistedOrigins { _ in second += 1 }
        defer { coordinator.removeOriginObserver(secondID) }
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        let deadline = ContinuousClock.now + .seconds(3)
        while second < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(first == 1 && second == 1)
        coordinator.removeOriginObserver(firstID)
        f.notes += [note(2)]
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        let next = ContinuousClock.now + .seconds(3)
        while second < 2, ContinuousClock.now < next { try await Task.sleep(for: .milliseconds(1)) }
        #expect(first == 1 && second == 2)
    }

    @Test func freshDisplayOriginNotificationAndReopenedDetailsIgnoreAStaleNonAIActionClassification() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        let source = f.notes[0]
        let old = AICommentAssessment(version: 2, host: "gitlab.example.test", projectID: 7, iid: 13, noteID: 1,
            bodySHA256: AICommentAssessmentStore.digest(source.body!), confidence: "high", evidence: "Older criteria", classification: "manual_likely",
            provider: "codex", model: "cheap", criteriaVersion: AICommentOriginAssessor.criteriaVersion - 1, username: "me", authorID: 7)
        let path = AICommentAssessmentStore.fileURL(host: "gitlab.example.test", projectID: 7, iid: 13, noteID: 1, in: f.actionDirectory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: path)
        let coordinator = f.coordinator()
        var events: [AICommentDisplayCoordinator.PersistedOrigins] = []
        let observer = coordinator.observePersistedOrigins { events.append($0) }
        defer { coordinator.removeOriginObserver(observer) }
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        let deadline = ContinuousClock.now + .seconds(3)
        while events.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(events.first?.origins.first?.classification == .aiAssisted)
        let store = MRDiscussionStore(load: { _ in [.init(id: "thread", notes: f.notes)] },
            assessmentDirectory: f.actionDirectory, displayAssessmentDirectory: f.displayDirectory)
        await store.refresh(target: .init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13, url: f.request.webURL), glab: f.glab)
        #expect(store.origins[1] == .assessed(evidence: "Synthetic source evidence"))
        #expect(!AICommentAssessmentStore.isAI(source, host: "gitlab.example.test", projectID: 7, iid: 13, in: f.actionDirectory))
        #expect(!AICommentAssessmentStore.isAI(source, host: "gitlab.example.test", projectID: 7, iid: 13, in: f.displayDirectory))
    }

    private actor CacheGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private let holdCall: Int
        private var calls = 0
        private var released = false
        private(set) var entered = false
        init(holdCall: Int) { self.holdCall = holdCall }
        func read(_ notes: [GitLabMergeRequestDiscussion.Note]) async -> [GitLabMergeRequestDiscussion.Note] {
            if notes.first?.body == "Old source" {
                calls += 1
                if calls == holdCall {
                    entered = true
                    if !released { await withCheckedContinuation { continuation = $0 } }
                    return []
                }
            }
            return notes
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let gitlab = InMemoryGitLab()
        let suite = "AICommentDisplayCoordinatorTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        var request: GitLabMergeRequest
        var notes: [GitLabMergeRequestDiscussion.Note] = []
        var batches: [[Int]] = []
        var bodies: [[String]] = []
        var ready = true
        var publicationBusy = false
        var afterAssessment: (() -> Void)?

        init() throws {
            settings = SettingsManager(defaults: UserDefaults(suiteName: suite)!)
            settings.automation.applyPreset(.trusted, for: .codex)
            settings.automation.publicationMode = .manual
            settings.automation.scope.mode = .all
            glab = gitlab.service(host: "gitlab.example.test", username: "me")
            request = try MRDependencyPresentationTests().request(13, project: 7, author: 9)
            gitlab.handler = { [self] call in
                if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":9,"username":"me"}"#) }
                if call.method == "GET", call.endpoint == "/users/7" {
                    return InMemoryGitLab.output(#"{"id":7,"username":"user7","bot":false,"user_type":"human"}"#)
                }
                if call.method == "GET", call.endpoint == "/users/9" {
                    return InMemoryGitLab.output(#"{"id":9,"username":"me","bot":false,"user_type":"human"}"#)
                }
                if call.endpoint.contains("/discussions?") {
                    return InMemoryGitLab.output(String(decoding: try JSONEncoder().encode([
                        GitLabMergeRequestDiscussion(id: "thread", notes: notes)
                    ]), as: UTF8.self))
                }
                if call.endpoint == "/projects/7/merge_requests/13" {
                    return InMemoryGitLab.output(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
                }
                return try gitlab.unexpected(call)
            }
        }
        var actionDirectory: URL { root.appending(path: "action") }
        var displayDirectory: URL { root.appending(path: "display") }
        var work: AssistantAutomationRunner.MergeRequestWork { .init(host: "gitlab.example.test", projectID: 7, iid: 13) }
        func coordinator(cacheRead: AICommentDisplayCoordinator.CacheRead? = nil) -> AICommentDisplayCoordinator {
            AICommentDisplayCoordinator(glab: glab, settings: settings, assessmentDirectory: actionDirectory,
                displayDirectory: displayDirectory, canAutomate: { [self] _ in ready },
                publicationIsChecking: { [self] _ in publicationBusy }, assess: { [self] _, notes, _, _, _ in
                    batches.append(notes.compactMap(\.id))
                    bodies.append(notes.compactMap(\.body))
                    afterAssessment?()
                    return .init(notes: notes.map { .init(noteID: $0.id!, classification: .aiAssisted,
                        confidence: .high, evidence: "Synthetic source evidence") })
                }, cacheRead: cacheRead)
        }
        func close() {
            afterAssessment = nil
            gitlab.close()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func note(_ id: Int, author: Int = 7, system: Bool = false, body: String = "Published message") -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: .init(id: author, username: author == 9 ? "me" : "user\(author)", name: "User"), system: system,
              resolvable: nil, resolved: nil, resolvedBy: nil, body: body)
    }

    private func settle(_ coordinator: AICommentDisplayCoordinator, _ fixture: Fixture) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.isChecking(work: fixture.work), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!coordinator.isChecking(work: fixture.work))
    }

    @Test func displayClassifiesRootsOwnRepliesAndGeneralMessagesWithoutDraftsAndReusesEveryCurrentResult() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1), note(2, author: 9), note(3, author: 8), note(4, system: true), note(5)]
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes, knownNoteIDs: [5])
        await coordinator.schedule(request: f.request, notes: f.notes, knownNoteIDs: [5])
        try await settle(coordinator, f)
        #expect(f.batches.flatMap { $0 }.sorted() == [1, 2, 3])
        let revision = coordinator.revision
        await coordinator.schedule(request: f.request, notes: f.notes, knownNoteIDs: [5])
        try await settle(coordinator, f)
        #expect(f.batches.count == 1 && coordinator.revision == revision)
        #expect(!FileManager.default.fileExists(atPath: f.actionDirectory.path))
        #expect(!AICommentAssessmentStore.isAI(f.notes[0], host: "gitlab.example.test", projectID: 7, iid: 13, in: f.displayDirectory))
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func moreThanOneBatchCompletesWithoutDroppingLaterMessages() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = (1...205).map { note($0) }
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches.flatMap { $0 }.sorted() == Array(1...205))
        #expect(f.batches.allSatisfy { $0.count <= 100 })
    }

    @Test(arguments: [AICommentOriginAssessment.Classification.aiAssisted, .manualLikely, .uncertain])
    func everyUnchangedEvaluatedClassificationIsReused(_ classification: AICommentOriginAssessment.Classification) async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        try AICommentAssessmentStore.persist(.init(notes: [.init(noteID: 1, classification: classification,
            confidence: .high, evidence: "An already evaluated unchanged message")]),
            target: .init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13), notes: f.notes,
            assistant: .codex, model: "recorded-model", purpose: .display, in: f.displayDirectory)
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches.isEmpty)
        f.notes = [note(1, body: "An edited message")]
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches == [[1]])
    }

    @Test func messageBodiesAlsoBoundTheBatchInputSize() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = (1...5).map { note($0, body: String(repeating: "a", count: 40_000)) }
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches.flatMap { $0 }.sorted() == Array(1...5))
        #expect(f.batches.allSatisfy { $0.count <= 3 })
    }

    @Test(arguments: ["manual", "scope", "draft", "cli", "persistence", "account", "private"])
    func displayUsesExistingAutomaticWorkPrerequisitesButDoesNotRequirePublicActions(_ gate: String) async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        switch gate {
        case "manual": f.settings.automation.applyPreset(.manual, for: .codex)
        case "scope": f.settings.automation.scope.mode = .selected
        case "draft": f.request = try MRDependencyPresentationTests().request(13, project: 7, author: 9, draft: true)
        case "cli": f.ready = false
        case "persistence": f.settings.recordPersistenceFailure("automation")
        case "account": f.glab.currentUsername = nil
        case "private": f.settings.automation.allowAutomaticPublicActions = false
        default: break
        }
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches.isEmpty == (gate != "private"))
    }

    @Test func publicationClassificationFinishesFirstThenDisplayUsesItsCachedResult() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1), note(2)]
        f.publicationBusy = true
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        #expect(f.batches.isEmpty)
        try AICommentAssessmentStore.persist(.init(notes: [.init(noteID: 1, classification: .aiAssisted,
            confidence: .high, evidence: "Existing publication assessment")]),
            target: .init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13),
            notes: [f.notes[0]], assistant: .codex, model: "cheap", in: f.actionDirectory)
        f.publicationBusy = false
        coordinator.resume()
        try await settle(coordinator, f)
        #expect(f.batches.flatMap { $0 } == [2])
    }

    @Test(arguments: [1, 2])
    func aLateEmptyCacheScanCannotEraseANewerViewedMessageQueue(_ holdCall: Int) async throws {
        let f = try Fixture(); defer { f.close() }
        let gate = CacheGate(holdCall: holdCall)
        let coordinator = f.coordinator(cacheRead: { notes, _, _, _ in await gate.read(notes) })
        let old = [note(1, body: "Old source")]
        let first = Task { await coordinator.schedule(request: f.request, notes: old) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
        let entered = await gate.entered
        #expect(entered)
        f.notes = [note(2, body: "New source")]
        await coordinator.schedule(request: f.request, notes: f.notes)
        await gate.release()
        await first.value
        try await settle(coordinator, f)
        #expect(f.batches == [[2]] && f.bodies == [["New source"]])
    }

    @Test func cancellingANoncooperativeLiveReadCannotResurrectContextOrStartTheProvider() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        let original = f.gitlab.handler
        var release: CheckedContinuation<Void, Never>?
        var entered = false
        var released = false
        f.gitlab.handler = { call in
            if call.endpoint == "/projects/7/merge_requests/13" {
                entered = true
                if !released { await withCheckedContinuation { release = $0 } }
            }
            return try await original!(call)
        }
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        #expect(entered)
        coordinator.cancel()
        released = true
        release?.resume()
        try await settle(coordinator, f)
        for _ in 0..<20 { await Task.yield() }
        #expect(f.batches.isEmpty)
        #expect(!coordinator.isChecking(work: f.work))
    }

    @Test(arguments: ["details", "thread"])
    func truncatedRemoteDetailsClassifyEveryCompleteSourceMessageAndDoNotTrustOldKnownIDs(_ truncation: String) async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1, body: "Complete current source"), note(2, author: 9, body: "Complete author reply"), note(3)]
        var thread = RemoteDetailThread(id: "thread", state: .general, notes: [
            .init(id: "1", author: "Reviewer", body: "Clipped old source", origin: .human, authorID: 7)
        ])
        thread.truncated = truncation == "thread"
        let details = RemoteMRDetails(checkedAt: .now, threads: [thread], truncated: truncation == "details")
        let coordinator = f.coordinator()
        let pending = RemoteMRDetailSupplement.scheduleDisplayOrigins(in: details, request: f.request,
            glab: f.glab, coordinator: coordinator, accountRevision: f.glab.accountRevision)
        let task = try #require(pending)
        await task.value
        try await settle(coordinator, f)
        #expect(f.batches.flatMap { $0 } == [1, 2, 3])
        #expect(f.bodies.flatMap { $0 } == ["Complete current source", "Complete author reply", "Published message"])
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func truncatedRemoteOriginReadRemainsBoundToTheDeliveredHead() async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        let delivered = f.request
        let encoded = try JSONEncoder().encode(f.request)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var fields = try #require(decoded as? [String: Any])
        fields["sha"] = String(repeating: "b", count: 40)
        f.request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        let coordinator = f.coordinator()
        let pending = RemoteMRDetailSupplement.scheduleDisplayOrigins(in: .init(checkedAt: .now, truncated: true), request: delivered,
            glab: f.glab, coordinator: coordinator, accountRevision: f.glab.accountRevision)
        let task = try #require(pending)
        await task.value
        #expect(f.batches.isEmpty)
    }

    @Test(arguments: ["body", "account", "persistence"])
    func changedSourceOrAuthorityCannotPersistACompletedDisplayOpinion(_ change: String) async throws {
        let f = try Fixture(); defer { f.close() }
        f.notes = [note(1)]
        f.afterAssessment = {
            switch change {
            case "body": f.notes = [note(1, body: "Edited source")]
            case "account": f.glab.currentUsername = "other"
            default: f.settings.recordPersistenceFailure("automation")
            }
        }
        let coordinator = f.coordinator()
        await coordinator.schedule(request: f.request, notes: f.notes)
        try await settle(coordinator, f)
        #expect(f.batches.count == 1)
        #expect(AICommentAssessmentStore.result(for: note(1), host: "gitlab.example.test", projectID: 7, iid: 13,
            in: f.displayDirectory) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.actionDirectory.path))
    }
}
