import Foundation
import Testing
@testable import MergeTether

struct AICommentProvenanceTests: Sendable {
    @Test func legacyDisplayOriginsRemainExactAndNeverPopulateTheNewInstallationDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appending(path: "legacy"), current = root.appending(path: "current")
        let generated = draft(11), runID = UUID()
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: runID, headSHA: String(repeating: "a", count: 40), in: legacy)
        let publication = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: [], in: legacy))
        let after = try discussions(#"[{"id":20,"body":"Generated reply","author":{"id":9,"username":"me"}}]"#)
        try AICommentProvenanceStore.recordPublished(publication, after: after, in: legacy)
        #expect(AICommentProvenanceStore.generation(for: generated, context: context, in: current, legacyDirectory: legacy) == runID)
        let snapshot = AICommentProvenanceStore.snapshot(context: context, in: current, legacyDirectory: legacy)
        #expect(snapshot.contains(after[0].notes[0], discussionID: "thread"))
        var edited = after[0].notes[0]; edited.body = "Later user edit"
        #expect(!snapshot.contains(edited, discussionID: "thread"))
        let other = AICommentProvenanceStore.Context(host: context.host, username: "other", userID: 19, projectID: 1, iid: 2)
        #expect(!AICommentProvenanceStore.snapshot(context: other, in: current, legacyDirectory: legacy)
            .contains(after[0].notes[0], discussionID: "thread"))
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

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

    @Test(arguments: ["host", "userID", "project", "mr"])
    func generationEvidenceNeverCrossesAccountOrMergeRequest(_ changed: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        let other = AICommentProvenanceStore.Context(host: changed == "host" ? "other.test" : context.host,
            username: context.username, userID: changed == "userID" ? 99 : context.userID,
            projectID: changed == "project" ? 99 : context.projectID, iid: changed == "mr" ? 99 : context.iid)
        #expect(AICommentProvenanceStore.generation(for: generated, context: other, in: directory) == nil)
    }

    @Test func generatedDraftKeepsItsOriginAfterTheAccountIsRenamed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11), runID = UUID()
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!))],
            baseline: [], current: [generated], context: context, runID: runID, headSHA: String(repeating: "a", count: 40), in: directory)
        let renamed = AICommentProvenanceStore.Context(host: context.host, username: "renamed",
            userID: context.userID, projectID: context.projectID, iid: context.iid)
        #expect(AICommentProvenanceStore.generation(for: generated, context: renamed, in: directory) == runID)
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


    @Test(arguments: [false, true])
    func extraContextIsStoredLocallyForTheExactDraftAndFollowsItsPublishedNote(_ proposedSolution: Bool) throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11), plain = draft(12, body: "Plain reply")
        let markdown = "## Background\n- The parser drops `nil` here."
        // when
        try AICommentProvenanceStore.recordGenerated([
            .init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!), extraContext: "  \(markdown)\n",
                proposedSolution: proposedSolution ? true : nil),
            .init(id: 12, bodySHA256: AICommentAssessmentStore.digest(plain.note!), extraContext: " ", proposedSolution: true)
        ], baseline: [], current: [generated, plain], context: context, runID: UUID(),
            headSHA: String(repeating: "a", count: 40), in: directory)
        // then
        let drafts = AICommentProvenanceStore.extraContexts(context: context, in: directory)
        #expect(drafts.forDraft(generated)?.markdown == markdown)
        #expect(drafts.forDraft(generated)?.proposedSolution == proposedSolution)
        #expect(drafts.forDraft(plain) == nil)
        #expect(drafts.forDraft(draft(11, body: "User edit")) == nil)
        let other = AICommentProvenanceStore.Context(host: context.host, username: "other", userID: 19, projectID: 1, iid: 2)
        #expect(AICommentProvenanceStore.extraContexts(context: other, in: directory).isEmpty)

        let publication = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: [], in: directory))
        let after = try discussions(#"[{"id":20,"body":"Generated reply","author":{"id":9,"username":"me"}}]"#)
        try AICommentProvenanceStore.recordPublished(publication, after: after, in: directory)
        let snapshot = AICommentProvenanceStore.snapshot(context: context, in: directory)
        let published = AICommentProvenanceStore.extraContexts(context: context, snapshot: snapshot, in: directory)
        #expect(published.forNote(20) == drafts.forDraft(generated))
        #expect(published.forNote(21) == nil)

        // A later rewrite without context removes the stale explanation.
        let rewritten = draft(11, body: "Rewritten reply")
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(rewritten.note!))],
            baseline: [generated], current: [rewritten], context: context, runID: UUID(),
            headSHA: String(repeating: "a", count: 40), in: directory)
        let afterRewrite = AICommentProvenanceStore.extraContexts(context: context, snapshot: snapshot, in: directory)
        #expect(afterRewrite.forDraft(rewritten) == nil && afterRewrite.forNote(20) == nil)
    }

    @Test func oversizedExtraContextIsClippedAndBlankContextIsDropped() {
        let long = String(repeating: "ą", count: AICommentProvenanceStore.extraContextLimit + 50)
        #expect(AICommentProvenanceStore.normalizedExtraContext(long)?.count == AICommentProvenanceStore.extraContextLimit)
        #expect(AICommentProvenanceStore.normalizedExtraContext(" \n ") == nil)
        #expect(AICommentProvenanceStore.normalizedExtraContext(nil) == nil)
    }

    @MainActor @Test(arguments: [false, true])
    func detailsShowExtraContextOnlyForTheMatchingPublishedNote(_ edited: Bool) async throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = draft(11)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(generated.note!),
            extraContext: "Why this matters", proposedSolution: true)], baseline: [], current: [generated], context: context, runID: UUID(),
            headSHA: String(repeating: "a", count: 40), in: directory)
        let assessmentDirectory = directory.appending(path: "assessments")
        let body = edited ? "Edited reply" : "Generated reply"
        if edited {
            let publication = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: [], in: directory))
            let original = try discussions(#"[{"id":20,"body":"Generated reply","author":{"id":9,"username":"me"}}]"#)
            try AICommentProvenanceStore.recordPublished(publication, after: original, in: directory)
            try AICommentOriginOverrideStore.save(.init(version: 1, host: context.host, username: context.username,
                projectID: 1, iid: 2, noteID: 20, authorID: 9, bodySHA256: AICommentAssessmentStore.digest(body),
                classification: .human, createdAt: .now, activatesAt: .now), in: assessmentDirectory)
        }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: context.host, username: "me")
        gitlab.handler = { call in
            if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":9,"username":"me"}"#) }
            if call.endpoint.contains("/discussions") {
                return InMemoryGitLab.output(#"[{"id":"thread","notes":[{"id":5,"body":"Reviewer note","author":{"id":5,"username":"reviewer"}},{"id":20,"body":"\#(body)","author":{"id":9,"username":"me"}}]}]"#)
            }
            return try gitlab.unexpected(call)
        }
        let store = MRDiscussionStore(assessmentDirectory: assessmentDirectory, provenanceDirectory: directory)
        // when
        await store.refresh(target: .init(host: context.host, username: "me", projectID: 1, iid: 2,
            url: URL(string: "https://gitlab.example.test/g/p/-/merge_requests/2")!), glab: glab)
        // then
        #expect(store.extraContexts.forNote(20)?.markdown == (edited ? nil : "Why this matters"))
        #expect(store.extraContexts.forNote(20)?.proposedSolution == (edited ? nil : true))
        if edited { #expect(store.origins[20] == .manual(.human)) }
        #expect(store.extraContexts.forNote(5) == nil)
        #expect(store.extraContexts.forDraft(generated)?.markdown == "Why this matters")
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    private func recordReply(_ id: Int = 11, body: String = "Generated reply", in directory: URL) throws -> GitLabDraftNote {
        // GitLab returns diff-thread replies with an all-null position object.
        let generated = GitLabDraftNote(id: id, authorID: 9, note: body, discussionID: "thread",
            position: .init(newPath: nil, newLine: nil, oldPath: nil, oldLine: nil))
        try AICommentProvenanceStore.recordGenerated([.init(id: id, bodySHA256: AICommentAssessmentStore.digest(body))],
            baseline: [], current: [generated], context: context, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        return generated
    }
    private let diffThread = #"{"id":1,"body":"Reviewer note","author":{"id":5,"username":"reviewer"},"position":{"new_path":"A.swift","new_line":3}}"#

    @Test func aReplyInADiffThreadBindsDespiteTheEmptyDraftPosition() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = try recordReply(in: directory)
        let before = try discussions("[\(diffThread)]")
        let attempt = try #require(AICommentProvenanceStore.capturePublication([generated], context: context, before: before, in: directory))
        let after = try discussions("[\(diffThread),{\"id\":2,\"body\":\"Generated reply\",\"author\":{\"id\":9,\"username\":\"me\"},\"position\":{\"new_path\":\"A.swift\",\"new_line\":3}}]")
        try AICommentProvenanceStore.recordPublished(attempt, after: after, in: directory)
        #expect(AICommentProvenanceStore.isGenerated(after[0].notes[1], discussionID: "thread", context: context, in: directory))
    }

    @Test(arguments: ["exact", "duplicate", "otherAuthor", "otherThread", "edited", "newThreadReply"])
    func reconciliationLinksOnlyTheSingleExactPublishedNote(_ scenario: String) throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        if scenario == "newThreadReply" {
            try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest("Generated reply"))],
                baseline: [], current: [draft(11, thread: nil)], context: context, runID: UUID(),
                headSHA: String(repeating: "a", count: 40), in: directory)
        } else {
            _ = try recordReply(in: directory)
        }
        let body = scenario == "edited" ? "Edited reply" : "Generated reply"
        let author = scenario == "otherAuthor" ? 5 : 9
        let note = "{\"id\":2,\"body\":\"\(body)\",\"author\":{\"id\":\(author),\"username\":\"me\"}}"
        var threads = try discussions(scenario == "duplicate" ? "[\(diffThread),\(note),\(note.replacingOccurrences(of: ":2,", with: ":3,"))]" : "[\(diffThread),\(note)]")
        if scenario == "otherThread" { threads = [.init(id: "other-thread", notes: threads[0].notes)] }
        // when
        let snapshot = AICommentProvenanceStore.reconcile(threads, context: context, in: directory)
        // then
        let linked = scenario == "exact"
        #expect(snapshot.contains(threads[0].notes[1], discussionID: threads[0].id) == linked)
        #expect(AICommentProvenanceStore.isGenerated(threads[0].notes[1], discussionID: threads[0].id, context: context, in: directory) == linked)
        #expect(!snapshot.contains(threads[0].notes[0], discussionID: threads[0].id))
    }

    @Test func removingOneMergeRequestKeepsOtherOrigins() throws {
        // given
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = AICommentProvenanceStore.Context(host: context.host, username: "me", userID: 9, projectID: 1, iid: 3)
        let generated = try recordReply(in: directory)
        try AICommentProvenanceStore.recordGenerated([.init(id: 12, bodySHA256: AICommentAssessmentStore.digest("Generated reply"))],
            baseline: [], current: [draft(12)], context: other, runID: UUID(), headSHA: String(repeating: "a", count: 40), in: directory)
        // when
        AICommentProvenanceStore.removeMergeRequest(context, in: directory)
        // then
        #expect(AICommentProvenanceStore.generation(for: generated, context: context, in: directory) == nil)
        #expect(AICommentProvenanceStore.generation(for: draft(12), context: other, in: directory) != nil)
    }
}
