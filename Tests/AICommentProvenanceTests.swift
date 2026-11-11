import Foundation
import Testing
@testable import GitLabTodos

struct AICommentProvenanceTests: Sendable {
    private let context = AICommentProvenanceStore.Context(host: "gitlab.example.test", username: "me", userID: 9, projectID: 1, iid: 2)
    private func draft(_ id: Int, body: String = "Generated reply", thread: String? = "thread") -> GitLabDraftNote {
        .init(id: id, authorID: 9, note: body, discussionID: thread, position: nil)
    }
    private func discussions(_ notes: String) throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("[{\"id\":\"thread\",\"notes\":\(notes)}]".utf8))
    }
    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }

    @Test func onlyDeclaredNewOrRewrittenExactDraftsGetGenerationEvidence() throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = draft(10, body: "User draft"), generated = draft(11), unrelated = draft(12)
        let runID = UUID()
        // when
        try AICommentProvenanceStore.recordGenerated([
            .init(id: 10, bodySHA256: AICommentAssessmentStore.digest(existing.note!)),
            .init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))
        ], baseline: [existing], current: [existing, generated, unrelated], context: context, runID: runID, headSHA: String(repeating: "a", count: 40), in: directory)
        // then
        #expect(AICommentProvenanceStore.generation(for: generated, context: context, in: directory) == runID)
        #expect(AICommentProvenanceStore.generation(for: existing, context: context, in: directory) == nil)
        #expect(AICommentProvenanceStore.generation(for: unrelated, context: context, in: directory) == nil)
        #expect(AICommentProvenanceStore.generation(for: draft(11, body: "User edit"), context: context, in: directory) == nil)
    }

    @Test func anExplicitRewriteRecordsOnlyItsExactResultAndNotTheOriginalHumanDraft() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = draft(11, body: "Human text"), rewritten = draft(11, body: "AI rewrite")
        let runID = UUID()
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(rewritten.note!))],
            baseline: [original], current: [rewritten], context: context, runID: runID, headSHA: String(repeating: "a", count: 40), in: directory)
        #expect(AICommentProvenanceStore.generation(for: rewritten, context: context, in: directory) == runID)
        #expect(AICommentProvenanceStore.generation(for: original, context: context, in: directory) == nil)
    }

    @Test(arguments: ["duplicateClaim", "wrongHash", "missing", "duplicateLive", "incompleteBaseline", "invalidHead"])
    func incompleteOrAmbiguousGenerationDeclarationsProduceNoOrigin(_ scenario: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        let claim = AICommentProvenanceStore.DraftClaim(id: 11,
            bodySHA256: scenario == "wrongHash" ? String(repeating: "b", count: 64) : AICommentAssessmentStore.digest(generated.note!))
        let baseline = scenario == "incompleteBaseline" ? [GitLabDraftNote(id: nil, authorID: 9, note: nil, discussionID: nil, position: nil)] : []
        let current = scenario == "missing" ? [] : scenario == "duplicateLive" ? [generated, generated] : [generated]
        try AICommentProvenanceStore.recordGenerated(scenario == "duplicateClaim" ? [claim, claim] : [claim],
            baseline: baseline, current: current, context: context, runID: UUID(),
            headSHA: scenario == "invalidHead" ? "missing" : String(repeating: "a", count: 40), in: directory)
        #expect(AICommentProvenanceStore.generation(for: generated, context: context, in: directory) == nil)
    }

    @Test func aSuccessfulUnambiguousPublicationBindsOneExactNewNoteAcrossRestart() throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        let before = try discussions(#"[{"id":1,"body":"Generated reply","author":{"id":9,"username":"me"}}]"#)
        let attempt = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: before, in: directory))
        let after = try discussions(#"[{"id":1,"body":"Generated reply","author":{"id":9,"username":"me"}},{"id":2,"body":"Generated reply","author":{"id":9,"username":"me"}}]"#)
        // when
        try AICommentProvenanceStore.recordPublished(attempt, after: after, in: directory)
        // then
        #expect(!AICommentProvenanceStore.isGenerated(after[0].notes[0], discussionID: "thread", context: context, in: directory))
        #expect(AICommentProvenanceStore.isGenerated(after[0].notes[1], discussionID: "thread", context: context, in: directory))
        var edited = after[0].notes[1]; edited.body = "Edited later"
        #expect(!AICommentProvenanceStore.isGenerated(edited, discussionID: "thread", context: context, in: directory))
        var replacedAuthor = after[0].notes[1]
        replacedAuthor = .init(id: replacedAuthor.id, author: .init(id: 99, username: "me", name: nil), system: false,
            resolvable: nil, resolved: nil, resolvedBy: nil, body: replacedAuthor.body)
        #expect(!AICommentProvenanceStore.isGenerated(replacedAuthor, discussionID: "thread", context: context, in: directory))
    }

    @Test(arguments: ["host", "username", "userID", "project", "mr"])
    func generationEvidenceNeverCrossesAccountOrMergeRequest(_ changed: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        let other = AICommentProvenanceStore.Context(host: changed == "host" ? "other.test" : context.host,
            username: changed == "username" ? "other" : context.username, userID: changed == "userID" ? 99 : context.userID,
            projectID: changed == "project" ? 99 : context.projectID, iid: changed == "mr" ? 99 : context.iid)
        #expect(AICommentProvenanceStore.generation(for: generated, context: other, in: directory) == nil)
    }

    @Test(arguments: ["absent", "duplicate", "changed", "wrong-thread", "other-author", "system"])
    func ambiguousOrMismatchedPublicationDoesNotManufactureAIOrigin(_ scenario: String) throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        let attempt = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: [], in: directory))
        let body = scenario == "changed" ? "Normalized different body" : "Generated reply"
        let author = scenario == "other-author" ? 99 : 9
        let note = "{\"id\":2,\"body\":\"\(body)\",\"system\":\(scenario == "system"),\"author\":{\"id\":\(author),\"username\":\"me\"}}"
        var after = try discussions(scenario == "absent" ? "[]" : scenario == "duplicate" ? "[\(note),\(note.replacingOccurrences(of: ":2,", with: ":3,"))]" : "[\(note)]")
        if scenario == "wrong-thread" { after = [.init(id: "other-thread", notes: after[0].notes)] }
        // when
        try AICommentProvenanceStore.recordPublished(attempt, after: after, in: directory)
        // then
        for note in after.flatMap(\.notes) { #expect(!AICommentProvenanceStore.isGenerated(note, discussionID: "thread", context: context, in: directory)) }
    }
    @Test func aTrustedSealedFollowUpProvidesDraftAuthorshipWithoutReclassifyingContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try MRDependencyPresentationTests().request(2, project: 1, author: 9)
        let generated = draft(11)
        let runID = UUID()
        let proof = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: runID,
            host: context.host, projectID: 1, iid: 2, username: "me", userID: 9, headSHA: request.sha!,
            sourceProjectID: 1, sourceBranch: request.sourceBranch,
            files: [.init(path: "Sources/File.swift", sha256: String(repeating: "b", count: 64))],
            drafts: [.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))])
        try AICommentProvenanceStore.rememberSealed(generated, proof: proof, context: context, request: request, in: directory)
        #expect(AICommentProvenanceStore.generation(for: generated, context: context, in: directory) == runID)
        #expect(AICommentProvenanceStore.generation(for: draft(11, body: "Human edit"), context: context, in: directory) == nil)
        #expect(AICommentProvenanceStore.capturePublication([draft(12)], context: context, before: [], in: directory) == nil)
    }

    @Test func independentConcurrentRecordsAreNotLostAndTheLoadedSnapshotIsImmutable() async throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = AICommentProvenanceStore.snapshot(context: context, in: directory)
        // when
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...12 {
                group.addTask {
                    let generated = draft(index, body: "AI reply \(index)")
                    try AICommentProvenanceStore.recordGenerated([.init(id: index, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
                        baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
                    let attempt = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: [], in: directory))
                    let after = try discussions("[{\"id\":\(100 + index),\"body\":\"AI reply \(index)\",\"author\":{\"id\":9,\"username\":\"me\"}}]")
                    try AICommentProvenanceStore.recordPublished(attempt, after: after, in: directory)
                }
            }
            try await group.waitForAll()
        }
        // then
        let loaded = AICommentProvenanceStore.snapshot(context: context, in: directory)
        for index in 1...12 {
            let note = try discussions("[{\"id\":\(100 + index),\"body\":\"AI reply \(index)\",\"author\":{\"id\":9,\"username\":\"me\"}}]")[0].notes[0]
            #expect(loaded.contains(note, discussionID: "thread"))
            #expect(!empty.contains(note, discussionID: "thread"))
            #expect(!loaded.contains(note, discussionID: "other-thread"))
        }
    }

    @MainActor @Test(arguments: ["current", "body", "account", "roundtrip", "run", "runHead", "head", "baseline", "readFailure"])
    func workerDeclarationsRequireTheSameLiveAccountRunHeadAndExactDraft(_ scenario: String) async throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "GeneratedDrafts.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: context.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Review", prompt: "Review", createdAt: Date(), allowsPush: false,
            execution: .init(state: .running), workflow: .review, expectedHeadSHA: request.sha)
        var currentRun = handoff
        if scenario == "runHead" { currentRun.expectedHeadSHA = String(repeating: "b", count: 40) }
        settings.assistantHandoffs = scenario == "run" ? [] : [currentRun]
        let generated = draft(11)
        let result = AssistantJobResult(status: .succeeded, summary: "Saved generated reply",
            generatedDrafts: [.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))])
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: context.host, username: "me")
        gitlab.handler = { call in
            if scenario == "readFailure" { return InMemoryGitLab.output(code: 1) }
            if call.endpoint == "/user" {
                if scenario == "roundtrip" { glab.currentUsername = "other"; glab.currentUsername = "me" }
                return InMemoryGitLab.output("{\"id\":\(scenario == "account" ? 99 : 9),\"username\":\"me\"}")
            }
            if call.endpoint == "/projects/1/merge_requests/2" {
                let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                return InMemoryGitLab.output(scenario == "head" ? body.replacingOccurrences(of: request.sha!, with: String(repeating: "b", count: 40)) : body)
            }
            if call.endpoint.contains("/draft_notes?") {
                return InMemoryGitLab.output("[{\"id\":11,\"author_id\":9,\"note\":\"\(scenario == "body" ? "Human edit" : "Generated reply")\",\"discussion_id\":\"thread\"}]")
            }
            return try gitlab.unexpected(call)
        }
        // when
        await AssistantJobExecutor.recordGeneratedDrafts(result, baseline: scenario == "baseline" ? nil : [],
            user: .init(id: 9, username: "me"), request: request, handoff: handoff, settings: settings, glab: glab, directory: directory)
        // then
        #expect((AICommentProvenanceStore.generation(for: generated, context: context, in: directory) != nil) == (scenario == "current"))
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

}
