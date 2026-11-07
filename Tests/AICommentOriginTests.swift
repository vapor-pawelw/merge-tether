import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AICommentOriginTests {
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
        try JSONEncoder().encode(record).write(to: path)
        let expected = variant == "high" || variant == "very_high"
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory) == expected)
        #expect(!AICommentAssessmentStore.isAI(note(body: "Edited source"), host: target.host, projectID: 7, iid: 13, in: directory))
    }

    @Test(arguments: ["manual_likely", "uncertain"])
    func earlierCriteriaResultsAreReassessedOnce(_ classification: String) async throws {
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
        let assess: AICommentOriginCoordinator.Assess = { _, notes, _, _ in
            calls += 1
            return .init(notes: notes.map { .init(noteID: $0.id!, classification: .aiAssisted, confidence: .high,
                evidence: "Precise cross-code references with consistent formatting and polished language.") })
        }
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: assess,
            fetchCurrent: { _ in [source] }, isCurrent: { _, _, _ in true })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
        #expect(AICommentAssessmentStore.isAI(source, host: target.host, projectID: 7, iid: 13, in: directory))
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(saved["criteriaVersion"] as? Int == 4)
        let restarted = AICommentOriginCoordinator(directory: directory, assess: assess,
            fetchCurrent: { _ in [source] }, isCurrent: { _, _, _ in true })
        restarted.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(restarted)
        #expect(calls == 1)
    }

    @Test func legacyEvidenceArraysNormalizeWithoutTreatingHumanAccountAsNegative() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let note = note()
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = ["version": 1, "host": target.host, "projectID": 7, "iid": 13, "noteID": 10,
            "bodySHA256": AICommentAssessmentStore.digest(note.body!), "confidence": "very_high",
            "evidence": ["Generated review structure", "Specific supporting context"]]
        try JSONSerialization.data(withJSONObject: record).write(to: path)
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
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _ in
            calls += 1
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: $0.id == 10 ? .aiAssisted : .uncertain,
                confidence: $0.id == 10 ? .veryHigh : .uncertain, evidence: "Content and context assessment; not based on account name.") })
        }, fetchCurrent: { _ in notes }, isCurrent: { _, _, _ in true })
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

    @Test func changedLiveBodyOrAccountCannotGainARecordAndFailureDoesNotLoop() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = note()
        var calls = 0
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _ in
            calls += 1; return positive(notes)
        }, fetchCurrent: { _ in [note(body: "Changed while assessing")] }, isCurrent: { _, _, _ in true })
        coordinator.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(coordinator)
        #expect(calls == 1)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
        let failed = AICommentOriginCoordinator(directory: directory, assess: { _, _, _, _ in
            calls += 1; throw AICommentOriginAssessor.AssessmentError.failed
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _ in true })
        for _ in 0..<3 {
            failed.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
            await settle(failed)
        }
        #expect(calls == 2)
        var current = true
        let obsolete = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _ in
            current = false; return positive(notes)
        }, fetchCurrent: { _ in [source] }, isCurrent: { _, _, _ in current })
        obsolete.schedule(target: target, notes: [source], assistant: .codex, model: "cheap")
        await settle(obsolete)
        #expect(AICommentAssessmentStore.assessment(for: source, host: target.host, projectID: 7, iid: 13, in: directory) == nil)
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
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, notes, _, _ in
            active += 1; maximum = max(maximum, active)
            await withCheckedContinuation { waiting.append($0) }
            active -= 1
            return positive(notes)
        }, fetchCurrent: { _ in [note()] }, isCurrent: { _, _, _ in true })
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

    @Test(arguments: AutomationAssistant.allCases)
    func assessorKeepsFullCLIExecutionAndAReadOnlyUntrustedContentRole(_ assistant: AutomationAssistant) async throws {
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
            role=all(token in text for token in ['read-only','do not publish','untrusted','probabilistic','ai-assisted'])
            result={'notes':[{'noteID':10,'classification':'ai_assisted' if full and role else 'uncertain','confidence':'very_high' if full and role else 'uncertain','evidence':'Grounded content assessment without relying on the account name.'}]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let result = try await AICommentOriginAssessor.run(target: target, notes: [note()], assistant: assistant,
            model: "cheap", executable: executable)
        #expect(result.notes.first?.classification == .aiAssisted)
        #expect(result.notes.first?.confidence == .veryHigh)
    }

    @Test func lateUncertainAssessmentCannotOverwriteCurrentWorkerPositiveButStillRecordsOtherUnknowns() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let notes = [note(), note(11, body: "A second source with uncertain origin")]
        var release: CheckedContinuation<Void, Never>?
        let coordinator = AICommentOriginCoordinator(directory: directory, assess: { _, incoming, _, _ in
            await withCheckedContinuation { release = $0 }
            return .init(notes: incoming.map { .init(noteID: $0.id!, classification: .uncertain,
                confidence: .uncertain, evidence: "The source text does not establish AI assistance.") })
        }, fetchCurrent: { _ in notes }, isCurrent: { _, _, _ in true })
        coordinator.schedule(target: target, notes: notes, assistant: .codex, model: "cheap")
        for _ in 0..<300 { if release != nil { break }; await Task.yield() }
        let continuation = try #require(release)
        let workerRecord = AICommentAssessment(version: 1, host: target.host, projectID: 7, iid: 13, noteID: 10,
            bodySHA256: AICommentAssessmentStore.digest(notes[0].body!), confidence: "very_high", evidence: "Worker assessed this exact source body.")
        let path = AICommentAssessmentStore.fileURL(host: target.host, projectID: 7, iid: 13, noteID: 10, in: directory)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(workerRecord).write(to: path, options: .atomic)
        continuation.resume()
        await settle(coordinator)
        #expect(AICommentAssessmentStore.assessment(for: notes[0], host: target.host, projectID: 7, iid: 13, in: directory)?.evidence == workerRecord.evidence)
        let other = AICommentAssessmentStore.result(for: notes[1], host: target.host, projectID: 7, iid: 13, in: directory)
        #expect(other?.classification == "uncertain")
        #expect(AICommentAssessmentStore.assessment(for: notes[1], host: target.host, projectID: 7, iid: 13, in: directory) == nil)
    }
}
