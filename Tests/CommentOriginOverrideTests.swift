import Foundation
import Testing
@testable import MergeTether

@MainActor
struct CommentOriginOverrideTests {
    @Test func anOverrideOutranksTheAssessmentAndExpiresWhenTheCommentChanges() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source], assistant: .codex,
                                             model: "m", in: directory)
        #expect(isAI(source, in: directory))
        try AICommentOriginOverrideStore.save(record(for: source, .human), in: directory)
        #expect(!isAI(source, in: directory))
        let edited = note(body: "An edited comment")
        #expect(AICommentOriginOverrideStore.override(for: edited, host: target.host, projectID: 7, iid: 13, in: directory) == nil)

        let humanSource = note(11, body: "Written by hand")
        try AICommentOriginOverrideStore.save(record(for: humanSource, .ai), in: directory)
        #expect(isAI(humanSource, in: directory))
    }

    @Test func anAIOverrideCountsOnlyAfterItsUndoWindow() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note(), start = Date(timeIntervalSince1970: 1_000)
        try AICommentOriginOverrideStore.save(record(for: source, .ai, at: start, activatesAt: start.addingTimeInterval(10)),
                                              in: directory)
        #expect(!AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory,
                                               now: start.addingTimeInterval(9)))
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory,
                                              now: start.addingTimeInterval(10)))
    }

    @Test func aChangeThatWouldPublishDraftsWaitsAndUndoRestoresThePreviousVerdict() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note(), reply = note(11, body: "Another comment")
        try AICommentOriginOverrideStore.save(record(for: reply, .uncertain), in: directory)
        var gains: [Set<Int>] = [], resumed = 0
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, ids in gains.append(ids); return 2 },
            resume: { _ in resumed += 1 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let change = try await center.apply(.ai, to: [source, reply], in: discussions(source, reply), target: target)
        #expect(gains == [[10, 11]] && change.resumingDrafts == 2 && change.resumesAt != nil)
        #expect(center.pending(for: target)?.id == change.id && resumed == 0)
        #expect(!isAI(source, in: directory), "Automation must not act during the undo window")
        #expect(AICommentOriginOverrideStore.override(for: source, host: target.host, projectID: 7, iid: 13, in: directory)?.classification == .ai)

        try center.undo(change.id)
        #expect(center.pending.isEmpty && resumed == 0)
        #expect(AICommentOriginOverrideStore.override(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        #expect(AICommentOriginOverrideStore.override(for: reply, host: target.host, projectID: 7, iid: 13, in: directory)?.classification == .uncertain)
    }

    @Test func theGracePeriodEndingResumesAutomationOnce() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        var resumed: [MRAutomationScope.Target] = []
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, _ in 1 },
            resume: { resumed.append($0) }, sleep: { _ in })
        let change = try await center.apply(.ai, to: [source], in: discussions(source), target: target)
        let deadline = ContinuousClock.now + .seconds(3)
        while !center.pending.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(center.pending.isEmpty && resumed == [target])
        try center.undo(change.id)
        #expect(AICommentOriginOverrideStore.override(for: source, host: target.host, projectID: 7, iid: 13, in: directory) != nil,
                "Undo after the grace period changes nothing")
    }

    @Test func continueNowActivatesTheVerdictImmediately() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        var resumed = 0
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, _ in 1 },
            resume: { _ in resumed += 1 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let change = try await center.apply(.ai, to: [source], in: discussions(source), target: target)
        #expect(!isAI(source, in: directory))
        await center.continueNow(change.id)
        #expect(isAI(source, in: directory) && resumed == 1 && center.pending.isEmpty)
    }

    @Test func aChangeWithoutAutomationEffectAppliesAtOnceAndRecheck() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        try AICommentAssessmentStore.persist(positive([source]), target: target, notes: [source], assistant: .codex,
                                             model: "m", in: directory)
        var gainCalls = 0, resumed = 0
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, _ in gainCalls += 1; return 5 },
            resume: { _ in resumed += 1 })
        let change = try await center.apply(.human, to: [source], in: discussions(source), target: target)
        #expect(change.resumesAt == nil && gainCalls == 0 && resumed == 1 && center.pending.isEmpty)
        #expect(!isAI(source, in: directory))

        try await center.apply(nil, to: [source], in: discussions(source), target: target)
        #expect(isAI(source, in: directory), "Automatic assessment applies again")
    }

    @Test func aCommentThatNoLongerMatchesGitLabIsRejected() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, _ in 0 }, resume: { _ in })
        await #expect(throws: CommentOriginOverrideCenter.ChangeError.unknownComment) {
            try await center.apply(.human, to: [note()], in: discussions(note(body: "Edited on GitLab")), target: target)
        }
        #expect(AICommentOriginOverrideStore.override(for: note(), host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }

    @Test func accountBoundOverridesSurviveRenameAndKeepTheTwoOwnersSeparate() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        let center = CommentOriginOverrideCenter(directory: directory, gain: { _, _, _ in 0 }, resume: { _ in })
        func verdict(_ id: Int, username: String) -> AICommentOriginOverride.Classification? {
            AICommentOriginOverrideStore.override(for: source, host: target.host, projectID: 7, iid: 13,
                username: username, userID: id, legacyUsernames: [], in: directory)?.classification
        }
        try await center.apply(.human, to: [source], in: discussions(source), target: target, userID: 21)
        #expect(verdict(21, username: "renamed") == .human)
        #expect(verdict(22, username: target.username) == nil)

        try await center.apply(.ai, to: [source], in: discussions(source), target: target, userID: 22, legacyUsernames: [])
        #expect(verdict(22, username: target.username) == .ai)
        #expect(verdict(21, username: "renamed") == .human)

        try await center.apply(nil, to: [source], in: discussions(source), target: target, userID: 22, legacyUsernames: [])
        #expect(verdict(22, username: target.username) == nil)
        #expect(verdict(21, username: "renamed") == .human)
    }

    @Test func aManualVerdictOutranksAVerifiedAssistantInTheConversation() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let duo = GitLabMergeRequestDiscussion.Note(id: 3, author: .init(id: 7, username: "GitLabDuo", name: "Duo"), system: false,
                                                    resolvable: true, resolved: false, resolvedBy: nil, body: "Suggestion")
        let requested = MRDiscussionTarget(host: target.host, username: target.username, projectID: 7, iid: 13,
                                           url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/13")!)
        try AICommentOriginOverrideStore.save(record(for: duo, .human), in: directory)
        let store = MRDiscussionStore(load: { _ in [GitLabMergeRequestDiscussion(id: "thread", notes: [duo])] },
                                      verifyAssistant: { _, _ in true }, assessmentDirectory: directory)
        defer { store.cancel() }
        let glab = GlabService(); glab.resolvedHost = target.host; glab.currentUsername = target.username
        await store.refresh(target: requested, glab: glab)
        #expect(store.origins[3] == .manual(.human))
        let snapshot = MRDiscussionSnapshot(discussions: store.discussions, drafts: [], origins: store.origins)
        #expect(snapshot.threads.first?.originBadge == .human)
    }

    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13)

    private func note(_ id: Int = 10, body: String = "A detailed review with a suggested patch") -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: .init(id: 9, username: "person", name: "Person"), system: false,
              resolvable: nil, resolved: nil, resolvedBy: nil, body: body)
    }
    private func discussions(_ notes: GitLabMergeRequestDiscussion.Note...) -> [GitLabMergeRequestDiscussion] {
        [GitLabMergeRequestDiscussion(id: "thread", notes: notes)]
    }
    private func record(for note: GitLabMergeRequestDiscussion.Note, _ classification: AICommentOriginOverride.Classification,
                        at date: Date = Date(timeIntervalSince1970: 1_000), activatesAt: Date? = nil) -> AICommentOriginOverride {
        .init(version: 1, host: target.host, username: target.username, projectID: 7, iid: 13, noteID: note.id!,
              authorID: note.author!.id, bodySHA256: AICommentAssessmentStore.digest(note.body!), classification: classification,
              createdAt: date, activatesAt: activatesAt ?? date)
    }
    private func isAI(_ note: GitLabMergeRequestDiscussion.Note, in directory: URL) -> Bool {
        AICommentAssessmentStore.isAI(note, host: target.host, projectID: 7, iid: 13, in: directory)
    }
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func positive(_ notes: [GitLabMergeRequestDiscussion.Note]) -> AICommentOriginAssessment {
        .init(notes: notes.map { .init(noteID: $0.id!, classification: .aiAssisted, confidence: .veryHigh,
            evidence: "Several specific content and context signals support substantial AI assistance.") })
    }
}
