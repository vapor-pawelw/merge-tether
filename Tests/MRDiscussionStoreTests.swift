import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRDiscussionStoreTests {
    @Test func persistedLocalIdentityIsVisibleBeforeABlockedProfileLookupAndSurvivesItsFailure() async throws {
        struct LookupFailure: Error {}
        let gate = InMemoryGitLab(); defer { gate.close() }
        let notes = try threads(), requested = target, glab = glab()
        glab.updateLocalAutomationAuthors([7], host: requested.host, username: requested.username)
        var reads = 0
        let store = MRDiscussionStore(load: { _ in reads += 1; return notes }, verifyAuthorKind: { _, _ in
            try await gate.waitFor("release")
            throw LookupFailure()
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { gate.write("release"); store.cancel() }
        let refreshing = Task { await store.refresh(target: requested, glab: glab) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(store.hasLoaded && !store.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(store.hasLoaded && !store.isLoading)
        #expect(store.authorKinds[7] == .automation && reads == 1)
        #expect(store.discussions.first?.notes.first?.body == "Published comment" && store.origins.isEmpty)
        gate.write("release")
        await refreshing.value; await store.authorKindTask?.value
        #expect(store.authorKinds[7] == .automation && !store.hasError && reads == 1)
    }

    @Test func optionalAuthorLookupDoesNotHoldTheReadableConversation() async throws {
        let gate = InMemoryGitLab(); defer { gate.close() }
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in
            gate.write("identity-entered")
            try await gate.waitFor("release")
            return .automation
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        let refreshing = Task { await store.refresh(target: target, glab: glab) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.has("identity-entered"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(gate.has("identity-entered"))
        #expect(store.hasLoaded && !store.isLoading && store.discussions.first?.notes.first?.body == "Published comment")
        gate.write("release")
        await refreshing.value; await store.authorKindTask?.value
        #expect(store.authorKinds[7] == .automation)
    }

    @Test func laterVerifiedAuthorMetadataUpdatesAnOpenDiscussionWithoutReadingItAgain() async throws {
        let gitlab = InMemoryGitLab(); defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        let notes = try threads()
        var sourceReads = 0
        let store = MRDiscussionStore(load: { _ in sourceReads += 1; return notes },
            verifyAuthorKind: { _, _ in .unknown }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        #expect(store.authorKinds[7] == .unknown)
        let original = store.discussions.flatMap(\.notes).map(\.body)
        gitlab.handler = { request in
            #expect(request.endpoint == "/users/7")
            return InMemoryGitLab.output(#"{"id":7,"bot":true}"#)
        }
        _ = try await glab.feedbackAccountKind(userID: 7, host: target.host)
        #expect(store.authorKinds[7] == .automation)
        #expect(sourceReads == 1 && store.discussions.flatMap(\.notes).map(\.body) == original)
        #expect(store.origins.isEmpty)
    }

    @Test func authorMetadataIsBoundedAndReusedWithoutOriginReloadLookups() async throws {
        let notes: [GitLabMergeRequestDiscussion] = [.init(id: "thread", notes: (1...70).map { id in
            .init(id: id, author: .init(id: id + 100, username: "author\(id)", name: nil), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: "Published note")
        })]
        var reads: [Int] = []
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { id, host in
            #expect(host == self.target.host)
            reads.append(id)
            return .automation
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        #expect(store.hasLoaded && !store.hasError)
        #expect(reads.count == 64 && Set(reads).count == 64 && store.authorKinds.count == 64)
        await store.reloadOrigins(glab: glab)
        #expect(reads.count == 64)
        #expect(store.origins.isEmpty)
    }

    @Test func failedAuthorMetadataDoesNotFailReadableDiscussionsOrInventABot() async throws {
        struct Failure: Error {}
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in throw Failure() },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        await store.refresh(target: target, glab: glab())
        await store.authorKindTask?.value
        #expect(store.hasLoaded && !store.hasError && store.discussions.count == 1)
        #expect(store.authorKinds[7] == .unknown)
        #expect(store.origins.isEmpty)
    }

    @Test func accountRoundTripDuringAuthorLookupCannotPublishThatIdentity() async throws {
        let notes = try threads()
        let glab = glab()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in
            glab.currentUsername = "other"; glab.currentUsername = "me"
            return .automation
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        #expect(store.authorKinds.isEmpty && store.discussions.isEmpty && !store.hasLoaded)
    }

    @Test func freshDisplayAssessmentCanReplaceAStaleActionSlotUsingOnlyCachedConversationMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let action = root.appending(path: "action"), display = root.appending(path: "display"), legacy = root.appending(path: "legacy")
        let notes = try threads(), note = try #require(notes.first?.notes.first)
        let previous = try threads("Previous body")
        let previousNote = try #require(previous.first?.notes.first)
        var stale = assessment(note: previousNote, classification: "ai_assisted", confidence: "high")
        stale.provider = AutomationAssistant.codex.rawValue; stale.model = "cheap"
        try save(stale, in: action)
        var older = assessment(note: note, classification: "ai_assisted", confidence: "high")
        older.provider = AutomationAssistant.codex.rawValue; older.model = "cheap"
        try save(older, in: legacy)
        var reads = 0
        let store = MRDiscussionStore(load: { _ in reads += 1; return notes }, assessmentDirectory: action,
            legacyAssessmentDirectory: legacy, displayAssessmentDirectory: display)
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.origins.isEmpty)
        try AICommentAssessmentStore.persist(.init(notes: [.init(noteID: 3, classification: .manualLikely,
            confidence: .high, evidence: "Current displayed source")]),
            target: .init(host: target.host, username: target.username, projectID: 1, iid: 2), notes: [note],
            assistant: .codex, model: "cheap", purpose: .display, in: display)
        await store.reloadOrigins(glab: glab)
        #expect(reads == 1)
        #expect(store.discussions.flatMap(\.notes).map(\.body) == notes.flatMap(\.notes).map(\.body))
        #expect(store.origins[3] == .humanLikely(evidence: "Current displayed source"))
        #expect(!AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: action))
        #expect(!AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: display))
    }

    @Test(arguments: [("ai_assisted", "high", "ai"), ("ai_assisted", "uncertain", "uncertain"),
                      ("manual_likely", "high", "human"), ("manual_likely", "uncertain", "uncertain"),
                      ("uncertain", "high", "uncertain")])
    func legacyAssessmentRestoresPerMessageDisplayWithoutBecomingCurrentActionEvidence(
        classification: String, confidence: String, expected: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appending(path: "current"), legacy = root.appending(path: "legacy")
        let notes = try threads(), note = try #require(notes.first?.notes.first)
        var record = assessment(note: note, classification: classification, confidence: confidence)
        record.provider = AutomationAssistant.codex.rawValue
        record.model = "recorded-model"
        try save(record, in: legacy)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: current, legacyAssessmentDirectory: legacy)
        await store.refresh(target: target, glab: glab())
        let expectedOrigin: MRDiscussionSnapshot.Origin = switch expected {
        case "ai": .assessed(evidence: record.evidence)
        case "human": .humanLikely(evidence: record.evidence)
        default: .uncertain(evidence: record.evidence)
        }
        #expect(store.origins[3] == expectedOrigin)
        #expect(!AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: current))
        let draft = GitLabDraftNote(id: 4, authorID: 9, note: "Reply", discussionID: "thread", position: nil)
        #expect(!AICommentAssessmentStore.eligible(draft, discussions: notes, userID: 9,
            duoUserIDs: [], host: target.host, projectID: 1, iid: 2, in: current))
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: AICommentAssessmentStore.fileURL(
            host: target.host, projectID: 1, iid: 2, noteID: 3, in: legacy).path))
        let isolated = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: current)
        await isolated.refresh(target: target, glab: glab())
        #expect(isolated.origins.isEmpty)
    }

    @Test(arguments: ["body", "author", "missingAuthor", "account", "missingAccount", "host", "project", "mr", "note",
                      "criteria", "missingCriteria", "provider", "missingProvider", "model", "version"])
    func legacyDisplayFallbackRetainsExactAssessmentBindings(_ mismatch: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appending(path: "current"), legacy = root.appending(path: "legacy")
        let notes = try threads(), note = try #require(notes.first?.notes.first)
        let record = AICommentAssessment(version: mismatch == "version" ? 1 : 2,
            host: mismatch == "host" ? "other.test" : target.host, projectID: mismatch == "project" ? 99 : 1,
            iid: mismatch == "mr" ? 99 : 2, noteID: mismatch == "note" ? 99 : 3,
            bodySHA256: AICommentAssessmentStore.digest(mismatch == "body" ? "Edited" : note.body!),
            confidence: "high", evidence: "Recorded per-message evidence", classification: "ai_assisted",
            provider: mismatch == "missingProvider" ? nil : mismatch == "provider" ? "unsupported" : AutomationAssistant.codex.rawValue,
            model: mismatch == "model" ? " " : "recorded-model",
            criteriaVersion: mismatch == "missingCriteria" ? nil : AICommentOriginAssessor.criteriaVersion + (mismatch == "criteria" ? -1 : 0),
            username: mismatch == "missingAccount" ? nil : mismatch == "account" ? "other" : target.username,
            authorID: mismatch == "missingAuthor" ? nil : mismatch == "author" ? 99 : note.author?.id)
        try save(record, in: legacy)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: current, legacyAssessmentDirectory: legacy)
        await store.refresh(target: target, glab: glab())
        #expect(store.origins[3] == nil)
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test(arguments: [false, true])
    func currentAssessmentSlotTakesPrecedenceOverLegacyDisplay(_ invalid: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appending(path: "current"), legacy = root.appending(path: "legacy")
        let notes = try threads(), note = try #require(notes.first?.notes.first)
        var older = assessment(note: note, classification: "ai_assisted", confidence: "high")
        older.provider = AutomationAssistant.codex.rawValue; older.model = "recorded-model"
        try save(older, in: legacy)
        let replacement = assessment(note: note, classification: "manual_likely", confidence: "high")
        try save(replacement, in: current)
        if invalid {
            try Data("invalid current replacement".utf8).write(to: AICommentAssessmentStore.fileURL(
                host: target.host, projectID: 1, iid: 2, noteID: 3, in: current))
        }
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: current, legacyAssessmentDirectory: legacy)
        await store.refresh(target: target, glab: glab())
        #expect(store.origins[3] == (invalid ? nil : .humanLikely(evidence: replacement.evidence)))
    }

    private final class Flag { var value = false }
    private let target = MRDiscussionTarget(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2,
        url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
    private func glab() -> GlabService {
        let glab = GlabService()
        glab.resolvedHost = target.host; glab.currentUsername = target.username
        return glab
    }
    private func threads(_ body: String = "Published comment") throws -> [GitLabMergeRequestDiscussion] {
        [GitLabMergeRequestDiscussion(id: "thread", notes: [
            .init(id: 3, author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: body)
        ])]
    }

    @Test func loadsFullDiscussionAndKeepsItClickableAfterRefreshFailure() async throws {
        struct Failure: Error {}
        let fail = Flag()
        let expected = try threads()
        let store = MRDiscussionStore(load: { _ in if fail.value { throw Failure() }; return expected },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.discussions.first?.notes.first?.body == "Published comment")
        #expect(store.hasLoaded && !store.hasError && !store.isLoading)
        fail.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.hasError && store.hasLoaded)
        #expect(store.discussions.first?.id == "thread")
    }

    @Test func anOldAccountCannotStartAReadOrExposeAnInflightResponse() async throws {
        var continuation: CheckedContinuation<[GitLabMergeRequestDiscussion], Never>?
        let store = MRDiscussionStore(load: { _ in await withCheckedContinuation { continuation = $0 } })
        let glab = glab()
        let task = Task { await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let resume = try #require(continuation)
        glab.currentUsername = "other"
        resume.resume(returning: try threads())
        await task.value
        #expect(store.discussions.isEmpty && store.target == nil)
        var reads = 0
        let another = MRDiscussionStore(load: { _ in reads += 1; return [] })
        await another.refresh(target: target, glab: glab)
        #expect(reads == 0 && another.discussions.isEmpty)
    }

    @Test func anOlderTargetResponseCannotOverwriteTheNewConversation() async throws {
        let newer = MRDiscussionTarget(host: target.host, username: target.username, projectID: 1, iid: 4,
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/4")!)
        var continuation: CheckedContinuation<[GitLabMergeRequestDiscussion], Never>?
        let current = try threads("Current conversation")
        let store = MRDiscussionStore(load: { request in
            if request.iid == 2 { return await withCheckedContinuation { continuation = $0 } }
            return current
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        let task = Task { await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let resume = try #require(continuation)
        await store.refresh(target: newer, glab: glab)
        resume.resume(returning: try threads("Stale conversation"))
        await task.value
        #expect(store.target == newer)
        #expect(store.discussions.first?.notes.first?.body == "Current conversation")
    }

    @Test func anAssistantUsernameAloneDoesNotProveAIOrigin() async throws {
        let notes = [GitLabMergeRequestDiscussion(id: "assistant", notes: [
            .init(id: 8, author: .init(id: 9, username: "GitLabDuo", name: "GitLab Duo"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: "AI finding")
        ])]
        let verified = Flag()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAssistant: { _, _ in verified.value },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[8] == nil)
        verified.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[8] == .verifiedAssistant)
    }

    @Test(arguments: [
        ("ai_assisted", "high", "ai"), ("ai_assisted", "very_high", "ai"),
        ("manual_likely", "high", "human"), ("manual_likely", "very_high", "human"),
        ("uncertain", "high", "uncertain"), ("uncertain", "uncertain", "uncertain"),
        ("ai_assisted", "uncertain", "uncertain"), ("manual_likely", "uncertain", "uncertain")
    ])
    func displaysOnlyTheRecordedClassificationWithoutChangingAIEligibility(classification: String, confidence: String, expected: String) async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads()
        let note = try #require(notes.first?.notes.first)
        let record = assessment(note: note, classification: classification, confidence: confidence)
        try save(record, in: directory)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: directory)
        // when
        await store.refresh(target: target, glab: glab())
        // then
        let origin = try #require(store.origins[3])
        switch expected {
        case "ai": #expect(origin == .assessed(evidence: record.evidence))
        case "human": #expect(origin == .humanLikely(evidence: record.evidence))
        default: #expect(origin == .uncertain(evidence: record.evidence))
        }
        #expect(AICommentAssessmentStore.isAI(note, host: target.host, projectID: 1, iid: 2, in: directory)
            == (classification == "ai_assisted" && confidence != "uncertain"))
    }

    @Test(arguments: ["body", "author", "account", "host", "project", "mr", "note", "criteria"])
    func staleOrMismatchedManualEvidenceNeverBecomesAHumanBadge(mismatch: String) async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads()
        let note = try #require(notes.first?.notes.first)
        let record = AICommentAssessment(version: 2, host: mismatch == "host" ? "other.example.test" : target.host,
            projectID: mismatch == "project" ? 9 : 1, iid: mismatch == "mr" ? 9 : 2, noteID: mismatch == "note" ? 9 : 3,
            bodySHA256: AICommentAssessmentStore.digest(mismatch == "body" ? "Edited" : note.body!), confidence: "high",
            evidence: "Spontaneous personal composition", classification: "manual_likely",
            criteriaVersion: mismatch == "criteria" ? AICommentOriginAssessor.criteriaVersion - 1 : AICommentOriginAssessor.criteriaVersion,
            username: mismatch == "account" ? "other" : target.username, authorID: mismatch == "author" ? 99 : note.author?.id)
        try save(record, in: directory)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: directory)
        // when
        await store.refresh(target: target, glab: glab())
        // then
        #expect(store.hasLoaded)
        #expect(store.origins.isEmpty)
    }

    private func assessment(note: GitLabMergeRequestDiscussion.Note, classification: String, confidence: String) -> AICommentAssessment {
        .init(version: 2, host: target.host, projectID: 1, iid: 2, noteID: 3,
              bodySHA256: AICommentAssessmentStore.digest(note.body!), confidence: confidence,
              evidence: "Recorded origin evidence", classification: classification,
              criteriaVersion: AICommentOriginAssessor.criteriaVersion, username: target.username, authorID: note.author?.id)
    }

    private func save(_ record: AICommentAssessment, in directory: URL) throws {
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 1, iid: 2, noteID: 3, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: path)
    }

    @Test func provenAppReplyCompletesAnAIThreadWithoutClassifyingManualPostsFromTheSameAccount() async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origins = directory.appending(path: "origins")
        let assessments = directory.appending(path: "assessments")
        let context = AICommentProvenanceStore.Context(host: target.host, username: target.username, userID: 9, projectID: 1, iid: 2)
        let before = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"body":"Source AI","author":{"id":7,"username":"reviewer"}}]}]"#.utf8))
        var live = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":1,"body":"Source AI","author":{"id":7,"username":"reviewer"}},{"id":2,"body":"Generated reply","author":{"id":9,"username":"me"}}]}]"#.utf8))
        let draft = GitLabDraftNote(id: 11, authorID: 9, note: "Generated reply", discussionID: "thread", position: nil)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(draft.note!))],
            baseline: [], current: [draft], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: origins)
        let publication = try #require(AICommentProvenanceStore.capturePublication([draft], context: context, before: before, in: origins))
        try AICommentProvenanceStore.recordPublished(publication, after: live, in: origins)
        let record = AICommentAssessment(version: 2, host: target.host, projectID: 1, iid: 2, noteID: 1,
            bodySHA256: AICommentAssessmentStore.digest("Source AI"), confidence: "high", evidence: "Current source evidence")
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 1, iid: 2, noteID: 1, in: assessments)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: path)
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        var authenticatedID = 9
        gitlab.handler = { call in
            if call.endpoint == "/user" { return InMemoryGitLab.output("{\"id\":\(authenticatedID),\"username\":\"me\"}") }
            if call.endpoint.contains("/discussions?") { return InMemoryGitLab.output(String(decoding: try JSONEncoder().encode(live), as: UTF8.self)) }
            return try gitlab.unexpected(call)
        }
        let store = MRDiscussionStore(assessmentDirectory: assessments, provenanceDirectory: origins)
        // when
        await store.refresh(target: target, glab: glab)
        // then
        #expect(store.origins[2] == .appGenerated)
        #expect(MRDiscussionSnapshot(discussions: store.discussions, drafts: [], origins: store.origins).threads.first?.originBadge == .ai)
        #expect(!AICommentAssessmentStore.isAI(live[0].notes[1], host: target.host, projectID: 1, iid: 2, in: assessments))
        let manual = GitLabMergeRequestDiscussion.Note(id: 3, author: .init(id: 9, username: "me", name: nil), system: false,
            resolvable: nil, resolved: nil, resolvedBy: nil, body: "Manual GitLab reply")
        live = [.init(id: "thread", notes: live[0].notes + [manual])]
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[3] == nil)
        #expect(MRDiscussionSnapshot(discussions: store.discussions, drafts: [], origins: store.origins).threads.first?.originBadge == nil)
        var edited = live[0].notes[1]; edited.body = "Manual edit"
        live = [.init(id: "thread", notes: [live[0].notes[0], edited])]
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[2] == nil)
        edited.body = "Generated reply"; live = [.init(id: "thread", notes: [edited])]
        authenticatedID = 99
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[2] == nil)
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func accountRoundTripInvalidatesAnInflightDiscussionResponse() async throws {
        var continuation: CheckedContinuation<[GitLabMergeRequestDiscussion], Never>?
        let store = MRDiscussionStore(load: { _ in await withCheckedContinuation { continuation = $0 } })
        let glab = glab()
        let task = Task { await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where continuation == nil { await Task.yield() }
        let resume = try #require(continuation)
        glab.currentUsername = "other"; glab.currentUsername = target.username
        resume.resume(returning: try threads())
        await task.value
        #expect(store.discussions.isEmpty && store.origins.isEmpty && store.target == nil)
    }

    @Test func liveAccountMismatchClearsPreviouslyCachedDiscussion() async throws {
        let changedAccount = Flag()
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in
            if changedAccount.value { throw MRDiscussionStore.IdentityError.accountChanged }
            return notes
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(!store.discussions.isEmpty)
        changedAccount.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.discussions.isEmpty && store.origins.isEmpty)
        #expect(store.hasError && !store.hasLoaded)
    }

    @Test func expiredAuthenticationKeepsPreviouslyLoadedDiscussionReadable() async throws {
        let expired = Flag()
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in
            if expired.value { throw GlabError.notAuthenticated }
            return notes
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        expired.value = true
        await store.refresh(target: target, glab: glab)
        #expect(store.hasError && store.hasLoaded)
        #expect(store.discussions.first?.notes.first?.body == "Published comment")
    }
}
