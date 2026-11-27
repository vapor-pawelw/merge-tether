import Foundation
import Testing
@testable import MergeTether

@MainActor
struct MRDiscussionStoreTests {
    @Test(arguments: ["missing", "uncertain", "human", "staleHuman"])
    func verifiedBotDefaultsToMachineWithoutWritingAIAuthorshipEvidence(_ variant: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads(), source = try #require(notes.first?.notes.first)
        if variant != "missing" {
            var record = assessment(note: source, classification: variant == "uncertain" ? "uncertain" : "manual_likely",
                confidence: variant == "uncertain" ? "uncertain" : "high")
            if variant == "staleHuman" { record.criteriaVersion = AICommentOriginAssessor.criteriaVersion - 1 }
            try save(record, in: directory)
        }
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 1, iid: 2, noteID: 3, in: directory)
        let originalRecord = try? Data(contentsOf: path)
        let glab = glab()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in .automation }, assessmentDirectory: directory)
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        #expect(store.authorKinds[7] == .automation)
        let originalOrigin = store.origins[3]
        #expect(projectedOrigin(in: store)?.badge == .ai)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 1, iid: 2, in: directory))
        #expect((try? Data(contentsOf: path)) == originalRecord)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .regular, host: target.host,
            username: target.username, accountRevision: glab.accountRevision)
        let restored: MRDiscussionSnapshot.Origin? = switch variant {
        case "uncertain": .uncertain(evidence: "Recorded origin evidence")
        case "human", "staleHuman": .humanLikely(evidence: "Recorded origin evidence")
        default: nil
        }
        #expect(projectedOrigin(in: store) == restored)
        #expect(store.origins[3] == originalOrigin && store.origins[3] == restored)
        #expect((try? Data(contentsOf: path)) == originalRecord)
    }

    @Test(arguments: ["missing", "uncertain", "human"])
    func removingLocalBotDesignationRestoresTheOriginalContentOrigin(_ variant: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads(), source = try #require(notes.first?.notes.first)
        if variant != "missing" {
            try save(assessment(note: source, classification: variant == "human" ? "manual_likely" : "uncertain",
                confidence: variant == "human" ? "high" : "uncertain"), in: directory)
        }
        var reads = 0
        let glab = glab()
        let store = MRDiscussionStore(load: { _ in reads += 1; return notes }, assessmentDirectory: directory)
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        let original = store.origins[3]
        glab.notifyFeedbackAccountKind(userID: 7, kind: .regular, host: target.host,
            username: target.username, accountRevision: glab.accountRevision)
        glab.updateLocalAutomationAuthors([7], host: target.host, username: target.username)
        #expect(store.authorKinds[7] == .automation && projectedOrigin(in: store)?.badge == .ai)
        await store.reloadOrigins(glab: glab)
        #expect(projectedOrigin(in: store)?.badge == .ai && store.origins[3] == original)
        glab.updateLocalAutomationAuthors([], host: target.host, username: target.username)
        #expect(store.authorKinds[7] == .regular && projectedOrigin(in: store) == original && store.origins[3] == original)
        #expect(reads == 1)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 1, iid: 2, in: directory))
    }

    @Test(arguments: [AICommentOriginOverride.Classification.human, .uncertain])
    func fixedBotBadgeDoesNotEraseTheManualOriginRestoredAfterUnmarking(_ classification: AICommentOriginOverride.Classification) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads(), source = try #require(notes.first?.notes.first)
        try AICommentOriginOverrideStore.save(.init(version: 1, host: target.host, username: target.username,
            projectID: 1, iid: 2, noteID: 3, authorID: 7, bodySHA256: AICommentAssessmentStore.digest(source.body!),
            classification: classification, createdAt: .distantPast, activatesAt: .distantPast), in: directory)
        let glab = glab()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in .automation }, assessmentDirectory: directory)
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        let expected: MRDiscussionSnapshot.Origin = .manual(classification == .human ? .human : .uncertain)
        #expect(store.authorKinds[7] == .automation && projectedOrigin(in: store)?.badge == .ai && store.origins[3] == expected)
        glab.updateLocalAutomationAuthors([7], host: target.host, username: target.username)
        await store.reloadOrigins(glab: glab)
        #expect(projectedOrigin(in: store)?.badge == .ai && store.origins[3] == expected)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .regular, host: target.host,
            username: target.username, accountRevision: glab.accountRevision)
        #expect(projectedOrigin(in: store)?.badge == .ai && store.origins[3] == expected)
        glab.updateLocalAutomationAuthors([], host: target.host, username: target.username)
        #expect(store.authorKinds[7] == .regular && projectedOrigin(in: store) == expected && store.origins[3] == expected)
    }

    @Test func lateContentAssessmentDoesNotReplaceMachineUntilBotIdentityIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let action = root.appending(path: "action"), display = root.appending(path: "display")
        let notes = try threads(), source = try #require(notes.first?.notes.first)
        let glab = glab()
        let store = MRDiscussionStore(load: { _ in notes }, verifyAuthorKind: { _, _ in .automation },
            assessmentDirectory: action, displayAssessmentDirectory: display)
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        await store.authorKindTask?.value
        #expect(projectedOrigin(in: store)?.badge == .ai)
        try AICommentAssessmentStore.persist(.init(notes: [.init(noteID: 3, classification: .manualLikely,
            confidence: .high, evidence: "New content-only assessment")]),
            target: .init(host: target.host, username: target.username, projectID: 1, iid: 2), notes: [source],
            assistant: .codex, model: "cheap", purpose: .display, in: display)
        await store.reloadOrigins(glab: glab)
        #expect(projectedOrigin(in: store)?.badge == .ai)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .regular, host: target.host,
            username: target.username, accountRevision: glab.accountRevision)
        #expect(projectedOrigin(in: store) == .humanLikely(evidence: "New content-only assessment"))
        #expect(store.origins[3] == .humanLikely(evidence: "New content-only assessment"))
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 1, iid: 2, in: action))
    }

    @Test func staleBotMetadataCannotClassifyAnotherAccountsConversation() async throws {
        let notes = try threads(), glab = glab()
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        let previousRevision = glab.accountRevision
        glab.currentUsername = "other"
        let other = MRDiscussionTarget(host: target.host, username: "other", projectID: 1, iid: 2, url: target.url)
        await store.refresh(target: other, glab: glab)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .automation, host: target.host,
            username: target.username, accountRevision: previousRevision)
        #expect(store.target == other && store.authorKinds[7] != .automation && projectedOrigin(in: store) == nil)
        glab.notifyFeedbackAccountKind(userID: 7, kind: .automation, host: target.host,
            username: "other", accountRevision: glab.accountRevision)
        #expect(store.authorKinds[7] == .automation && projectedOrigin(in: store)?.badge == .ai)
    }

    @Test func explicitGenerationFooterReplacesUncertainDisplayWithoutCreatingActionEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = try threads("# Test quality report\n\nTests passed.\n\n*Generated by SoftNet AI Test Review powered by Claude*")
        let source = try #require(notes.first?.notes.first)
        try save(assessment(note: source, classification: "uncertain", confidence: "uncertain"), in: directory)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: directory)
        await store.refresh(target: target, glab: glab())
        #expect(store.origins[3]?.badge == .ai)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 1, iid: 2, in: directory))
        try AICommentOriginOverrideStore.save(.init(version: 1, host: target.host, username: target.username,
            projectID: 1, iid: 2, noteID: 3, authorID: source.author!.id,
            bodySHA256: AICommentAssessmentStore.digest(source.body!), classification: .human,
            createdAt: .distantPast, activatesAt: .distantPast), in: directory)
        await store.reloadOrigins(glab: glab())
        #expect(store.origins[3] == .manual(.human))
    }

    @Test(arguments: [
        "> *Generated by SoftNet AI Test Review powered by Claude*",
        "```markdown\n*Generated by SoftNet AI Test Review powered by Claude*\n```",
        "~~~markdown\n*Generated by SoftNet AI Test Review powered by Claude*\n~~~",
        "    Generated by SoftNet AI Test Review powered by Claude",
        "The footer says: Generated by SoftNet AI Test Review powered by Claude",
        "Generated by SoftNet AI Test Review powered by Claude\n\nThis is a quoted example, not this review.",
        "Generated by the test runner",
        "*Generated by SoftNet AI Test Review powered by Claude*\n<!-- example -->",
        "<!--\nGenerated by SoftNet AI Test Review powered by Claude\n-->"
    ])
    func quotationsExamplesAndUnrelatedAutomationDoNotDeclareAIOrigin(_ body: String) async throws {
        let notes = try threads(body)
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        await store.refresh(target: target, glab: glab())
        #expect(store.origins[3] == nil)
    }

    @Test func authenticatedProfileSuppliesDraftIdentityWithoutAnOwnPublishedNote() async throws {
        let gitlab = InMemoryGitLab(); defer { gitlab.close() }
        let glab = gitlab.service(host: target.host, username: target.username)
        let notes = try threads()
        gitlab.handler = { call in
            if call.endpoint == "/user" {
                return InMemoryGitLab.output(#"{"id":9,"username":"me","name":"My Display Name","avatar_url":"https://gitlab.example.test/me.png"}"#)
            }
            if call.endpoint.contains("/discussions?") {
                return InMemoryGitLab.output(String(decoding: try JSONEncoder().encode(notes), as: UTF8.self))
            }
            return try gitlab.unexpected(call)
        }
        let store = MRDiscussionStore(verifyAuthorKind: { _, _ in .regular },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        await store.refresh(target: target, glab: glab)
        #expect(store.hasLoaded && !store.hasError)
        #expect(store.currentUser?.displayName == "My Display Name")
        #expect(store.currentUser?.handle == "@me")
        #expect(store.currentUser?.avatarURL == URL(string: "https://gitlab.example.test/me.png"))
        #expect(!store.discussions.flatMap(\.notes).contains { $0.author?.username == "me" })
        #expect(gitlab.requests.filter { $0.endpoint == "/user" }.count == 1)

        glab.currentUsername = "other"
        await store.refresh(target: target, glab: glab)
        #expect(store.currentUser == nil && store.discussions.isEmpty)
    }

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
        #expect(projectedOrigin(in: store)?.badge == .ai)
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
        #expect(store.origins.isEmpty && projectedOrigin(in: store)?.badge == .ai)
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
        let projection = MRDiscussionSnapshot(discussions: store.discussions, drafts: [], origins: store.origins, authorKinds: store.authorKinds)
        #expect(projection.threads.first?.origins.count == 64)
        #expect(projection.threads.first?.origins.values.allSatisfy { $0.badge == .ai } == true)
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
        #expect(store.authorKinds.isEmpty && store.discussions.isEmpty && store.origins.isEmpty && !store.hasLoaded)
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

    private func projectedOrigin(in store: MRDiscussionStore, noteID: Int = 3) -> MRDiscussionSnapshot.Origin? {
        MRDiscussionSnapshot(discussions: store.discussions, drafts: [], origins: store.origins,
            authorKinds: store.authorKinds).threads.lazy.compactMap { $0.origins[noteID] }.first
    }

    private final class Flag { var value = false }

    /// Discussion reads answered in call order; listed calls wait for `release`.
    @MainActor private final class DiscussionReads {
        private var gated: Set<Int>
        private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
        private(set) var count = 0
        init(gated: Set<Int>) { self.gated = gated }
        func read() async throws -> [GitLabMergeRequestDiscussion] {
            count += 1
            let call = count
            if gated.contains(call) { await withCheckedContinuation { pending[call] = $0 } }
            return try MRDiscussionStoreTests.notes("read \(call)")
        }
        func waitFor(_ call: Int) async throws {
            for _ in 0..<1000 where pending[call] == nil { await Task.yield() }
            try #require(pending[call] != nil)
        }
        func release(_ call: Int) { gated.remove(call); pending.removeValue(forKey: call)?.resume() }
    }

    /// Local origin reads answered in call order; listed calls wait for `release`.
    @MainActor private final class OriginReads {
        typealias Result = ([Int: MRDiscussionSnapshot.Origin], AICommentProvenanceStore.ExtraContexts)
        private let gated: Set<Int>
        private var pending: [Int: CheckedContinuation<Result, Never>] = [:]
        private(set) var count = 0
        init(gated: Set<Int>) { self.gated = gated }
        func read() async -> Result {
            count += 1
            let call = count
            guard gated.contains(call) else { return ([3: .assessed(evidence: "read \(call)")], .empty) }
            return await withCheckedContinuation { pending[call] = $0 }
        }
        func waitFor(_ call: Int) async throws {
            for _ in 0..<1000 where pending[call] == nil { await Task.yield() }
            try #require(pending[call] != nil)
        }
        func release(_ call: Int, _ evidence: String) {
            pending.removeValue(forKey: call)?.resume(returning: ([3: .assessed(evidence: evidence)], .empty))
        }
    }

    fileprivate static func notes(_ body: String) throws -> [GitLabMergeRequestDiscussion] {
        [GitLabMergeRequestDiscussion(id: "thread", notes: [
            .init(id: 3, author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                  resolvable: true, resolved: false, resolvedBy: nil, body: body)
        ])]
    }
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
    func mismatchedCommentsAreIgnoredAndEarlierCriteriaKeepTheirVerdict(mismatch: String) async throws {
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
        #expect(store.origins[3] == (mismatch == "criteria" ? .humanLikely(evidence: record.evidence) : nil))
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
        try SealedAssessmentFile.write(record, to: path)
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

    @Test func aRefreshDuringAnInflightReadRunsOneFollowUpThatItsCallerAwaits() async throws {
        let reads = DiscussionReads(gated: [1])
        let store = MRDiscussionStore(load: { _ in try await reads.read() },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        let first = Task { await store.refresh(target: target, glab: glab) }
        try await reads.waitFor(1)
        let queued = Flag()
        let second = Task { queued.value = true; await store.refresh(target: target, glab: glab); return store.latestBody }
        for _ in 0..<1000 where !queued.value { await Task.yield() }
        try #require(queued.value)
        reads.release(1)
        await first.value
        #expect(await second.value == "read 2")
        #expect(reads.count == 2 && !store.isLoading && store.followUpTask == nil)
    }

    @Test func severalRefreshesDuringOneReadShareOneFollowUp() async throws {
        let reads = DiscussionReads(gated: [1, 2])
        let store = MRDiscussionStore(load: { _ in try await reads.read() },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        let first = Task { await store.refresh(target: target, glab: glab) }
        try await reads.waitFor(1)
        let queued = Flag()
        var waiting: [Task<String?, Never>] = []
        for _ in 0..<3 {
            queued.value = false
            waiting.append(Task { queued.value = true; await store.refresh(target: target, glab: glab); return store.latestBody })
            for _ in 0..<1000 where !queued.value { await Task.yield() }
            try #require(queued.value)
        }
        reads.release(1)
        await first.value
        try await reads.waitFor(2)
        #expect(store.isLoading)
        reads.release(2)
        for task in waiting { #expect(await task.value == "read 2") }
        await store.followUpTask?.value
        #expect(reads.count == 2 && !store.isLoading)
    }

    @Test(arguments: ["cancel", "clear", "target", "account"])
    func cancellationOrAnotherConversationPreventsTheQueuedFollowUp(_ variant: String) async throws {
        let newer = MRDiscussionTarget(host: target.host, username: target.username, projectID: 1, iid: 4,
            url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/4")!)
        let reads = DiscussionReads(gated: [1])
        var newerReads = 0
        let store = MRDiscussionStore(load: { request in
            if request.iid == newer.iid { newerReads += 1; return try MRDiscussionStoreTests.notes("Other conversation") }
            return try await reads.read()
        }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"))
        defer { store.cancel() }
        let glab = glab()
        let first = Task { await store.refresh(target: target, glab: glab) }
        try await reads.waitFor(1)
        let queued = Flag()
        let second = Task { queued.value = true; await store.refresh(target: target, glab: glab) }
        for _ in 0..<1000 where !queued.value { await Task.yield() }
        try #require(queued.value)
        switch variant {
        case "cancel": store.cancel()
        case "clear": store.clear()
        case "target": await store.refresh(target: newer, glab: glab)
        default: glab.currentUsername = "other"; glab.currentUsername = target.username
        }
        if variant != "account" { await second.value }
        reads.release(1)
        await first.value
        await second.value
        await store.followUpTask?.value
        #expect(reads.count == 1 && !store.isLoading && store.followUpTask == nil)
        if variant == "target" {
            #expect(store.target == newer && newerReads == 1 && store.latestBody == "Other conversation")
        } else {
            #expect(store.discussions.isEmpty)
        }
    }

    @Test func anOlderOriginReloadFinishingLastCannotOverwriteTheNewerOne() async throws {
        let origins = OriginReads(gated: [2, 3])
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"),
            loadOrigins: { _, _ in await origins.read() })
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[3] == .assessed(evidence: "read 1"))
        let older = Task { await store.reloadOrigins(glab: glab) }
        try await origins.waitFor(2)
        let newer = Task { await store.reloadOrigins(glab: glab) }
        try await origins.waitFor(3)
        origins.release(3, "newer")
        await newer.value
        #expect(store.origins[3] == .assessed(evidence: "newer"))
        origins.release(2, "older")
        await older.value
        #expect(store.origins[3] == .assessed(evidence: "newer"))
    }

    @Test func aScheduledOriginReloadCancelsTheOneItReplaces() async throws {
        let origins = OriginReads(gated: [2, 3])
        let notes = try threads()
        let store = MRDiscussionStore(load: { _ in notes }, assessmentDirectory: URL(fileURLWithPath: "/nonexistent"),
            loadOrigins: { _, _ in await origins.read() })
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        store.scheduleOriginReload(glab: glab)
        let older = try #require(store.originReloadTask)
        try await origins.waitFor(2)
        store.scheduleOriginReload(glab: glab)
        let newer = try #require(store.originReloadTask)
        try await origins.waitFor(3)
        origins.release(2, "older")
        await older.value
        #expect(store.origins[3] == .assessed(evidence: "read 1"))
        origins.release(3, "newer")
        await newer.value
        #expect(store.origins[3] == .assessed(evidence: "newer"))
        store.scheduleOriginReload(glab: glab)
        let cancelled = try #require(store.originReloadTask)
        store.cancel()
        await cancelled.value
        #expect(store.originReloadTask == nil && origins.count == 3 && store.origins[3] == .assessed(evidence: "newer"))
    }

    @Test func aCompletedReadSupersedesAnOriginReloadThatStartedBeforeIt() async throws {
        let origins = OriginReads(gated: [2])
        let reads = DiscussionReads(gated: [])
        let store = MRDiscussionStore(load: { _ in try await reads.read() },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"), loadOrigins: { _, _ in await origins.read() })
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        let stale = Task { await store.reloadOrigins(glab: glab) }
        try await origins.waitFor(2)
        await store.refresh(target: target, glab: glab)
        #expect(store.origins[3] == .assessed(evidence: "read 3") && store.latestBody == "read 2")
        origins.release(2, "stale")
        await stale.value
        await store.originReloadTask?.value
        #expect(store.origins[3] == .assessed(evidence: "read 3") && origins.count == 3)
    }

    @Test func anOriginReloadDuringAReadIsRepeatedAgainstTheNewDiscussions() async throws {
        let origins = OriginReads(gated: [2, 3])
        let reads = DiscussionReads(gated: [])
        let store = MRDiscussionStore(load: { _ in try await reads.read() },
            assessmentDirectory: URL(fileURLWithPath: "/nonexistent"), loadOrigins: { _, _ in await origins.read() })
        defer { store.cancel() }
        let glab = glab()
        await store.refresh(target: target, glab: glab)
        let refresh = Task { await store.refresh(target: target, glab: glab) }
        try await origins.waitFor(2)
        let reload = Task { await store.reloadOrigins(glab: glab) }
        try await origins.waitFor(3)
        origins.release(3, "previous discussions")
        await reload.value
        origins.release(2, "before the override")
        await refresh.value
        await store.originReloadTask?.value
        #expect(origins.count == 4 && store.origins[3] == .assessed(evidence: "read 4"))
        #expect(store.latestBody == "read 2")
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

private extension MRDiscussionStore {
    var latestBody: String? { discussions.first?.notes.first?.body }
}
