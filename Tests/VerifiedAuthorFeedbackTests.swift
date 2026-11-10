import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct VerifiedAuthorFeedbackTests {
    @Test(arguments: [ReReviewAssessment.Note.State.uncertain, .addressed])
    func aSourceBoundCodeQuestionGetsOnlyOneScopedReviewerRecovery(_ state: ReReviewAssessment.Note.State) async throws {
        // given
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let question = ReReviewAssessment.CodeReviewRequest(sourceNoteID: 20, sourceQuote: "rename X",
                kind: state == .uncertain ? .feedbackVerification : .potentialDefect,
                summary: "Check a possible failure in the related code path.",
                question: "Does the related warning identify the caller through its logger context?")
            let context = AuthorFeedbackResidual(assessedRunID: original.id,
                notes: [.init(noteID: 20, state: state, reason: "The original comment state remains independent of this code question.")],
                codeReviewRequests: [question])
            // when
            try await fixture.prepare(residual: context)
            try await fixture.waitForJob()
            // then
            #expect(fixture.settings.assistantHandoffs.count == 2)
            let successor = try #require(fixture.settings.assistantHandoffs.first { $0.id != original.id })
            #expect(successor.retryOf == original.id && successor.feedbackRecoveryRootID == original.id)
            #expect(successor.feedbackNoteIDs == [20])
            #expect(successor.prompt.contains(question.question))
            #expect(successor.prompt.contains("The original comment state remains independent of this code question."))
            #expect(successor.prompt.contains("First independently confirm or disprove each question"))
            #expect(successor.prompt.contains("Do not change code merely to agree with the verifier"))
            #expect(successor.prompt.contains("NOT a requirement made by the source comment's author"))
            #expect(successor.prompt.contains("Do not create a new discussion or draft reply solely"))
            fixture.settings.save()
            let reloaded = SettingsManager(defaults: fixture.defaults)
            var next = context
            next.assessedRunID = successor.id
            try await fixture.prepare(using: reloaded, residual: next)
            try await fixture.waitForJob()
            #expect(reloaded.assistantHandoffs.count == 2)
        }
    }

    @Test(arguments: [false, true])
    func theFirstReviewerReceivesPrivateQuestionsWithTheOriginalAssessmentAndPushPolicy(_ push: Bool) async throws {
        // given
        try await withFixture { fixture in
            fixture.settings.automation.allowFollowUpPush = push
            let question = ReReviewAssessment.CodeReviewRequest(sourceNoteID: 20, sourceQuote: "rename X",
                kind: .feedbackVerification, summary: "Check the related warning context.",
                question: "Does the warning retain caller identity from the request filter?")
            let context = AuthorFeedbackResidual(notes: [.init(noteID: 20, state: .uncertain,
                reason: "Tracing the request filter requires deeper code analysis.")], codeReviewRequests: [question])
            // when
            try await fixture.prepare(residual: context)
            try await fixture.waitForJob()
            // then
            let job = try #require(fixture.settings.assistantHandoffs.first)
            #expect(fixture.settings.assistantHandoffs.count == 1 && job.feedbackRecoveryRootID == nil)
            #expect(job.prompt.contains(question.question))
            #expect(job.prompt.contains("Tracing the request filter requires deeper code analysis."))
            #expect(job.prompt.contains("hypotheses, not confirmed findings"))
            #expect(job.followUpPushAllowed == push && !job.allowsPush)
            #expect(job.workflow == .followUp && job.key.username == "me")
        }
    }

    @Test(arguments: ["quote", "note", "kind", "head", "context", "body", "owner", "decision", "push", "failed"])
    func aCodeQuestionCannotBypassScopeOrRecoveryProof(_ changed: String) async throws {
        // given
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let question = ReReviewAssessment.CodeReviewRequest(sourceNoteID: changed == "note" ? 99 : 20,
                sourceQuote: changed == "quote" ? "An invented requirement" : "rename X",
                kind: changed == "kind" ? .feedbackVerification : .potentialDefect,
                summary: "Check the related code path.", question: "Can the changed path expose caller data?")
            if changed == "head" { try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40))) }
            if changed == "body" { try fixture.write("discussions.json", Fixture.discussions.replacingOccurrences(of: "rename X", with: "rename X and cover retries")) }
            if changed == "owner" { try fixture.write("request.json", Fixture.request.replacingOccurrences(of: "\"username\":\"me\"", with: "\"username\":\"someone-else\"")) }
            if changed == "decision" {
                let source = try #require(JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                    from: Data(Fixture.discussions.utf8)).first?.notes.first)
                fixture.settings.feedbackSuggestionDecisions.ignore(source, concernSummary: "Decline the exact suggestion",
                    concernReason: "Keep the existing contract", for: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
            }
            if changed == "push" { fixture.settings.automation.allowFollowUpPush = false }
            if changed == "failed" { fixture.settings.assistantHandoffs[0].execution?.state = .failed }
            let context = AuthorFeedbackResidual(assessedRunID: original.id,
                notes: [.init(noteID: 20, state: .addressed, reason: "The original correction is verified.")],
                semanticContextFingerprint: changed == "context" ? "obsolete-context" : nil,
                codeReviewRequests: [question])
            // when
            try await fixture.prepare(residual: context)
            try await fixture.waitForJob()
            // then
            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test(arguments: [AssistantJobExecution.State.succeeded, .blocked])
    func decisionChangesDoNotReplayHandledNotesThroughUnverifiedEntryPoints(_ state: AssistantJobExecution.State) async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            try await fixture.prepare()
            try await fixture.waitForJob()
            fixture.settings.assistantHandoffs[0].execution?.state = state
            let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
            let another = GitLabMergeRequestDiscussion.Note(id: 21,
                author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                resolvable: false, resolved: false, resolvedBy: nil, body: "A separate suggestion")
            _ = fixture.settings.feedbackSuggestionDecisions.ignore(another, concernSummary: "Separate suggestion",
                concernReason: "This is unrelated to the already handled note.", for: target)
            #expect(AssistantAutomationRunner.unhandledFeedback([20, 21], work: fixture.work,
                username: "me", settings: fixture.settings) == [21])
            #expect(AssistantAutomationRunner.attachFeedbackTodo(nil, noteIDs: [20], work: fixture.work,
                username: "me", settings: fixture.settings))
            try await fixture.service.prepareFeedback(work: fixture.work, noteIDs: [20], username: "me",
                settings: fixture.settings, glab: fixture.glab, manual: false, shouldProceed: { true })
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test func restoringAUserConcernStartsOneFreshContextWithoutReplayingTheOldAttemptBudget() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)
            let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: Data(Fixture.discussions.utf8))
            let note = try #require(discussions.first?.notes.first)
            let stored = fixture.settings.feedbackSuggestionDecisions.ignore(note,
                concernSummary: "Rename X", concernReason: "The exact rename suggestion is declined.", for: target)
            let decision = try #require(stored)
            _ = fixture.settings.feedbackSuggestionDecisions.remove(decision.id, for: target)
            fixture.settings.save()

            try await fixture.prepare()
            try await fixture.waitForJob()

            #expect(fixture.settings.assistantHandoffs.count == 2)
            let context = fixture.settings.feedbackSuggestionDecisions.revision(for: target)
            #expect(!context.isEmpty)
            #expect(fixture.settings.assistantHandoffs.last?.feedbackDecisionRevision == context)
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
        }
    }

    @Test(arguments: ["beforeRead", "duringStack"])
    func residualEvidenceCannotOutliveTheAssessedTitleAndDescription(_ edit: String) async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let changed = Fixture.request.replacingOccurrences(of: "Example MR", with: "Changed business requirement")
            try fixture.write(edit == "beforeRead" ? "request.json" : "changed-request.json", changed)

            try await fixture.prepare(residual: .init(assessedRunID: original.id, notes: [
                .init(noteID: 20, state: .blocking, reason: "A defect remains under the originally assessed requirement")
            ]))
            try await fixture.waitForJob()

            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test func prunedRetryAncestryCannotInventANewAutomaticRecoveryBudget() async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let notes = [ReReviewAssessment.Note(noteID: 20, state: .blocking, reason: "A concrete residual defect")]
            try await fixture.prepare(residual: .init(assessedRunID: original.id, notes: notes))
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
            let legacyRetry = AssistantAutomationRunner.Handoff(id: UUID(), key: original.key,
                title: "Legacy manual retry", prompt: "Handle feedback", createdAt: Date().addingTimeInterval(1),
                allowsPush: false, feedbackNoteIDs: [20], verifiedFeedbackNotes: original.verifiedFeedbackNotes,
                followUpPushAllowed: true, execution: .init(state: .succeeded, finishedAt: Date().addingTimeInterval(2)),
                taskPrompt: "Handle feedback", mergeRequestURL: original.mergeRequestURL,
                workflow: .followUp, manual: true, expectedHeadSHA: Fixture.sha, retryOf: UUID())
            fixture.settings.assistantHandoffs = [legacyRetry]
            fixture.settings.save()
            let reloaded = SettingsManager(defaults: fixture.defaults)

            try await fixture.prepare(using: reloaded, residual: .init(assessedRunID: legacyRetry.id, notes: notes))
            try await fixture.waitForJob()

            #expect(reloaded.assistantHandoffs.count == 1)
        }
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked, .interrupted, .cancelled, .queued, .running], [true, false])
    func aLaterStoppedOrActiveAttemptCannotBeReplayedThroughAnOlderSuccess(state: AssistantJobExecution.State,
                                                                         sameNote: Bool) async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let noteID = sameNote ? 20 : 21
            fixture.settings.assistantHandoffs.append(.init(id: UUID(), key: original.key,
                title: "A newer attempt", prompt: "Handle the selected feedback", createdAt: original.createdAt.addingTimeInterval(1),
                allowsPush: false, feedbackNoteIDs: [noteID],
                verifiedFeedbackNotes: sameNote ? original.verifiedFeedbackNotes : [21: "another-reviewer-revision"],
                followUpPushAllowed: true,
                execution: .init(state: state, finishedAt: state.isActive ? nil : Date().addingTimeInterval(1)),
                taskPrompt: "Handle feedback", mergeRequestURL: original.mergeRequestURL,
                workflow: .followUp, expectedHeadSHA: Fixture.sha))

            try await fixture.prepare(residual: .init(assessedRunID: original.id, notes: [
                .init(noteID: 20, state: .blocking, reason: "The originally assigned defect remains")
            ]))
            try await fixture.waitForJob()

            #expect(fixture.settings.assistantHandoffs.count == (sameNote || state.isActive ? 2 : 3))
        }
    }

    @Test(arguments: ["valid", "missing", "wrongRun", "wrongHead", "wrongBranch", "wrongUser"])
    func deliveredChangesRequireMatchingRemoteContentProofForResidualRecovery(_ proofState: String) async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let deliveredHead = String(repeating: "b", count: 40)
            try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: deliveredHead))
            if proofState != "missing" {
                let proof = FollowUpVerification(version: 1, sealed: false, verificationID: UUID(),
                    runID: proofState == "wrongRun" ? UUID() : original.id,
                    host: Fixture.host, projectID: 1, iid: 2, username: "me", userID: proofState == "wrongUser" ? 99 : 3,
                    headSHA: proofState == "wrongHead" ? Fixture.sha : deliveredHead,
                    sourceProjectID: 1, sourceBranch: proofState == "wrongBranch" ? "other-branch" : "feature",
                    files: [.init(path: "src/Details.swift", sha256: String(repeating: "c", count: 64))], drafts: [])
                let url = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: fixture.work,
                    username: "me", in: fixture.directory)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(proof).write(to: url)
            }

            try await fixture.prepare(expectedHeadSHA: deliveredHead,
                residual: .init(assessedRunID: original.id, notes: [
                    .init(noteID: 20, state: .blocking, reason: "A related defect remains in the verified delivered source")
                ]))
            try await fixture.waitForJob()

            #expect(fixture.settings.assistantHandoffs.count == (proofState == "valid" ? 2 : 1))
            if proofState == "valid" { #expect(fixture.settings.assistantHandoffs.last?.expectedHeadSHA == deliveredHead) }
        }
    }

    @Test func freshConcreteResidualGetsOneSuccessorPerOriginalNoteLineageAcrossRestart() async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            let residual = AuthorFeedbackResidual(assessedRunID: original.id,
                notes: [.init(noteID: 20, state: .blocking, reason: "The observed defect remains after rejecting the proposed remedy")])

            try await fixture.prepare(residual: residual)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
            guard let successor = fixture.settings.assistantHandoffs.first(where: { $0.id != original.id }) else { return }
            #expect(successor.retryOf == original.id)
            #expect(successor.feedbackNoteIDs == [20])
            #expect(successor.prompt.contains("The observed defect remains after rejecting the proposed remedy"))
            #expect(successor.prompt.contains("Reconcile prior remote work and existing published replies before changing code or drafting"))
            #expect(successor.prompt.contains("reported possible remaining author work"))
            #expect(successor.prompt.contains("Determine whether each claim is a current in-scope author obligation or a prerequisite for a later lifecycle step"))
            #expect(!successor.prompt.contains("identified concrete remaining author work"))
            let stillBlocking = AuthorFeedbackResidual(assessedRunID: successor.id, notes: residual.notes)

            try await fixture.prepare(residual: stillBlocking)
            #expect(fixture.settings.assistantHandoffs.count == 2)
            fixture.settings.save()
            let reloaded = SettingsManager(defaults: fixture.defaults)
            try await fixture.prepare(using: reloaded, residual: stillBlocking)
            #expect(reloaded.assistantHandoffs.count == 2)
            reloaded.assistantHandoffs = [original]
            reloaded.save()
            let pruned = SettingsManager(defaults: fixture.defaults)
            try await fixture.prepare(using: pruned, residual: residual)
            #expect(pruned.assistantHandoffs.count == 1)
        }
    }

    @Test(arguments: ["unknownRun", "wrongHead", "failedRun", "uncertain", "disabledPush", "missingReason"])
    func residualRecoveryRequiresConcreteCurrentCompletedWork(_ missing: String) async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            try await fixture.prepare()
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            if missing == "wrongHead" { fixture.settings.assistantHandoffs[0].expectedHeadSHA = "other-head" }
            if missing == "failedRun" { fixture.settings.assistantHandoffs[0].execution?.state = .failed }
            if missing == "disabledPush" { fixture.settings.automation.allowFollowUpPush = false }
            let residual = AuthorFeedbackResidual(assessedRunID: missing == "unknownRun" ? UUID() : original.id,
                notes: [.init(noteID: 20, state: missing == "uncertain" ? .uncertain : .blocking,
                    reason: missing == "missingReason" ? "" : "An independently observed defect remains")])

            try await fixture.prepare(residual: residual)
            try await fixture.waitForJob()

            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test func recoveringOneNoteDoesNotConsumeItsSiblingsBudgetOrReplayTheFirst() async throws {
        try await withFixture { fixture in
            fixture.resultStatus = .succeeded
            fixture.settings.automation.allowFollowUpPush = true
            let sibling = ",{\"id\":21,\"author\":{\"id\":7,\"username\":\"alice\"},\"system\":false,\"body\":\"Also correct a second defect\",\"resolvable\":false}"
            let snapshot = Fixture.discussions.replacingOccurrences(of: "]}]", with: "\(sibling)]}]")
            try fixture.write("discussions.json", snapshot)
            try await fixture.prepare(noteIDs: [20, 21], snapshot: snapshot)
            try await fixture.waitForJob()
            let original = try #require(fixture.settings.assistantHandoffs.first)
            try await fixture.prepare(noteIDs: [20], snapshot: snapshot,
                residual: .init(assessedRunID: original.id, notes: [.init(noteID: 20, state: .blocking, reason: "First residual defect")]))
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
            guard let first = fixture.settings.assistantHandoffs.last, first.id != original.id else { return }

            try await fixture.prepare(noteIDs: [20, 21], snapshot: snapshot,
                residual: .init(assessedRunID: first.id, notes: [
                    .init(noteID: 20, state: .blocking, reason: "First residual defect"),
                    .init(noteID: 21, state: .blocking, reason: "Second residual defect")
                ]))
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 3)
            #expect(fixture.settings.assistantHandoffs.last?.feedbackNoteIDs == [21])
            #expect(fixture.settings.assistantHandoffs.last?.retryOf == original.id)
        }
    }

    @Test func verifiedGeneralConditionIsIncludedAndAutomaticDispatchDoesNotRepeat() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            let handoff = try #require(fixture.settings.assistantHandoffs.first)
            #expect(handoff.feedbackNoteIDs == [20])
            #expect(handoff.expectedHeadSHA == Fixture.sha)
            #expect(handoff.workflow == .followUp)
            #expect(handoff.taskPrompt?.contains("Focus on GitLab note IDs: 20.") == true)
            #expect(handoff.taskPrompt?.contains("conditions attached to an advance approval") == true)
            #expect(handoff.taskPrompt?.contains("Decide whether each request is justified") == true)
            #expect(handoff.taskPrompt?.contains("Correlate summaries with their underlying findings and substantive author replies across all discussions") == true)
            #expect(handoff.taskPrompt?.contains("A correction delivered for another comment still needs a reply in each actionable feedback thread") == true)
            #expect(handoff.taskPrompt?.contains("A summary's distinct unanswered request still requires work or an evidence-based answer") == true)
            #expect(handoff.prompt.contains("Separate the observed defect from the reviewer's proposed remedy"))
            #expect(handoff.prompt.contains("Research accessible authoritative contracts, relevant callers and tests"))
            #expect(handoff.prompt.contains("Rejecting an unsupported remedy does not address an independently supported defect"))
            #expect(handoff.prompt.contains("identify the exact missing external fact, the evidence checked and why it prevents the remaining work"))
            #expect(handoff.prompt.contains("Do not return blocked solely because approval for a later deployment or organizational step is absent"))
            #expect(handoff.prompt.contains("Return succeeded when the assigned correction or explanation is complete and any required reply is already published"))
            #expect(handoff.followUpPushAllowed == false)
            try await fixture.waitForJob()
            try await fixture.prepare()
            #expect(fixture.settings.assistantHandoffs.count == 1)
        }
    }

    @Test func clearingJobHistoryAndReloadingSettingsDoesNotReplayAttemptedFeedback() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            fixture.settings.assistantHandoffs.removeAll()
            fixture.settings.save()
            let reloaded = SettingsManager(defaults: fixture.defaults)
            #expect(reloaded.assistantHandoffs.isEmpty)

            try await fixture.prepare(using: reloaded)
            try await fixture.waitForJob()
            #expect(reloaded.assistantHandoffs.isEmpty)

            try await fixture.prepare(manual: true, using: reloaded)
            try await fixture.waitForJob()
            #expect(reloaded.assistantHandoffs.count == 1)
            #expect(reloaded.assistantHandoffs.first?.manual == true)
            #expect(reloaded.assistantHandoffs.first?.feedbackNoteIDs == [20])
        }
    }

    @Test func boundedBatchesDoNotLoseTheThirteenthConditionAndAllowManualRetry() async throws {
        try await withFixture { fixture in
            let noteIDs = Array(100...112)
            let notes = noteIDs.map { id in
                """
                    {"id":\(id),"author":{"id":7,"username":"alice"},"system":false,
                     "body":"Approved, but also address condition \(id)","resolvable":false}
                    """
            }.joined(separator: ",")
            let snapshot = "[{\"id\":\"general-conditions\",\"notes\":[\(notes)]}]"
            try fixture.write("discussions.json", snapshot)

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)
            #expect(fixture.settings.assistantHandoffs.first?.feedbackNoteIDs == Array(100...111))

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)
            #expect(fixture.settings.assistantHandoffs.contains { $0.feedbackNoteIDs == [112] })

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot)
            #expect(fixture.settings.assistantHandoffs.count == 2)

            try await fixture.prepare(noteIDs: noteIDs, snapshot: snapshot, manual: true)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 3)
            #expect(fixture.settings.assistantHandoffs.filter { $0.manual == true }.map(\.feedbackNoteIDs) == [Array(100...111)])
        }
    }

    @Test func unchangedReviewerConcernDoesNotReplayAfterOurReplyOrNewHeadButNewFeedbackCanRun() async throws {
        try await withFixture { fixture in
            try await fixture.prepare()
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let reply = """
                ,{"id":21,"author":{"id":3,"username":"me"},"system":false,
                  "body":"I have addressed the request","resolvable":false}
                """
            let withReply = Fixture.discussions.replacingOccurrences(of: "]}]", with: "\(reply)]}]")
            try fixture.write("discussions.json", withReply)
            try await fixture.prepare(snapshot: withReply)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let newHead = String(repeating: "b", count: 40)
            try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: newHead))
            try await fixture.prepare(snapshot: withReply, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 1)

            let editedConcern = withReply.replacingOccurrences(of: "rename X", with: "rename Y")
            try fixture.write("discussions.json", editedConcern)
            try await fixture.prepare(snapshot: editedConcern, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 2)

            let newConcern = """
                ,{"id":22,"author":{"id":7,"username":"alice"},"system":false,
                  "body":"One additional correction","resolvable":false}
                """
            let withNewConcern = editedConcern.replacingOccurrences(of: "]}]", with: "\(newConcern)]}]")
            try fixture.write("discussions.json", withNewConcern)
            try await fixture.prepare(noteIDs: [20, 22], snapshot: withNewConcern, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 3)
            #expect(fixture.settings.assistantHandoffs.contains { $0.feedbackNoteIDs == [22] })

            try await fixture.prepare(snapshot: withNewConcern, manual: true, expectedHeadSHA: newHead)
            try await fixture.waitForJob()
            #expect(fixture.settings.assistantHandoffs.count == 4)
            #expect(fixture.settings.assistantHandoffs.filter { $0.manual == true }.map(\.feedbackNoteIDs) == [[20]])
        }
    }

    @Test(arguments: ["head", "comment"])
    func changedEvidenceDuringStackLookupPreventsDispatch(_ changed: String) async throws {
        try await withFixture { fixture in
            if changed == "head" {
                try fixture.write("changed-request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            } else {
                try fixture.write("changed-discussions.json", Fixture.discussions.replacingOccurrences(of: "rename X", with: "rename Y"))
            }
            try await fixture.prepare()
            #expect(fixture.gitlab.has("stack-read"))
            #expect(fixture.settings.assistantHandoffs.isEmpty)
            #expect(!fixture.executed)
        }
    }

    @Test(arguments: ["head", "comment"])
    func alreadyStaleVerifierSnapshotDoesNotPrepareAJob(_ changed: String) async throws {
        try await withFixture { fixture in
            if changed == "head" {
                try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            } else {
                try fixture.write("discussions.json", Fixture.discussions.replacingOccurrences(of: "rename X", with: "rename Y"))
            }
            try await fixture.prepare()
            #expect(fixture.settings.assistantHandoffs.isEmpty)
            #expect(!fixture.gitlab.has("stack-read"))
            #expect(!fixture.executed)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await body(fixture)
    }

    @MainActor
    private final class Fixture {
        static let host = "gitlab.example.test"
        static let sha = String(repeating: "a", count: 40)
        static let request = """
            {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},
             "title":"Example MR","web_url":"https://\(host)/group/repo/-/merge_requests/2",
             "state":"opened","draft":false,"sha":"\(sha)","source_branch":"feature",
             "target_branch":"main","source_project_id":1,"labels":[]}
            """
        static let discussions = """
            [{"id":"general-condition","notes":[{"id":20,"author":{"id":7,"username":"alice"},
             "system":false,"body":"Approved, but please also rename X","resolvable":false,
             "created_at":"2026-01-01T12:00:00Z"}]}]
            """
        let directory: URL
        let defaults: UserDefaults
        let suite = "VerifiedAuthorFeedbackTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        let gitlab = InMemoryGitLab()
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 1, iid: 2)
        var executed = false
        var resultStatus: AssistantJobResult.Status = .blocked
        lazy var coordinator = AssistantJobCoordinator(execute: { [self] _, _ in
            executed = true
            return .init(result: .init(status: resultStatus, summary: "Synthetic job"), output: "")
        })
        lazy var service = TodoAutomationService(canAutomate: { _ in true }, jobCoordinator: coordinator,
            followUpDirectory: directory)

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.assistant = .codex
            settings.automation.authorFeedback.runner = .assistant
            settings.automation.authorFeedback.isEnabled = true
            settings.automation.allowFollowUpPush = false
            glab = gitlab.service(host: Self.host, username: "me")
            try write("request.json", Self.request)
            try write("discussions.json", Self.discussions)
            gitlab.handler = { [gitlab] request in
                switch request.endpoint {
                case "/projects/1/merge_requests/2": return try gitlab.response("request.json")
                case let path where path.contains("/discussions?"): return try gitlab.response("discussions.json")
                case let path where path.hasPrefix("/projects/1/merge_requests?"):
                    gitlab.write("stack-read")
                    if gitlab.has("changed-request.json") { try gitlab.copy("changed-request.json", "request.json") }
                    if gitlab.has("changed-discussions.json") { try gitlab.copy("changed-discussions.json", "discussions.json") }
                    return InMemoryGitLab.output("[]")
                case "/projects/1": return InMemoryGitLab.output(#"{"default_branch":"main"}"#)
                default: return try gitlab.unexpected(request)
                }
            }
        }

        func prepare(noteIDs: [Int] = [20], snapshot: String? = nil, manual: Bool = false, expectedHeadSHA: String? = nil,
                     using settingsOverride: SettingsManager? = nil, residual: AuthorFeedbackResidual? = nil) async throws {
            let discussion = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data((snapshot ?? Self.discussions).utf8))
            var boundResidual = residual
            if boundResidual?.semanticContextFingerprint == nil {
                let assessed = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Self.request.utf8))
                boundResidual?.semanticContextFingerprint = assessed.semanticContextFingerprint
            }
            try await service.prepareFeedback(work: work, noteIDs: noteIDs, username: "me", settings: settingsOverride ?? settings,
                glab: glab, manual: manual, verifiedFingerprint: ReviewVerdict.fingerprint(discussion),
                expectedHeadSHA: expectedHeadSHA ?? Self.sha, verifiedResidual: boundResidual, shouldProceed: { true })
        }

        func waitForJob() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while coordinator.isWorking(on: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!coordinator.isWorking(on: work))
        }

        func write(_ name: String, _ content: String) throws { gitlab.write(name, content) }
        func cleanUp() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
