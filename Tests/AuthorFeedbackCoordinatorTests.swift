import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AuthorFeedbackCoordinatorTests {
    @Test func privateWorkStillVerifiesFeedbackButCannotReactOrResolveWithOtherwisePermissiveFlags() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.allowAutomaticPublicActions = false
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved && fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
            #expect(fixture.settings.automaticWritesAllowed && !fixture.settings.automaticPublicWritesAllowed)
        }
    }
    @Test(arguments: ["before", "duringVerification"])
    func persistenceHoldKeepsSemanticReadsButCannotResolveAcceptedFeedback(_ phase: String) async throws {
        try await withFixture { fixture in
            if phase == "before" { fixture.settings.recordPersistenceFailure("reReviewReceipts") }
            let coordinator = fixture.coordinator(duringVerification: {
                if phase == "duringVerification" { fixture.settings.recordPersistenceFailure("reReviewReceipts") }
            })
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved && fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
            #expect(!fixture.settings.automaticActionsAllowed)
        }
    }

    @Test func aPrivateTechnicalQuestionIsForwardedWithoutChangingTheAddressedComment() async throws {
        // given
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"The original correction is verified."}],"codeReviewRequests":[{"sourceNoteID":10,"sourceQuote":"Fix A","kind":"potentialDefect","summary":"Check a possible failure in the related error path.","question":"Does the changed error path expose caller data in its warning context?"}]}"#.utf8))
            let coordinator = fixture.coordinator(assessment: assessment)
            var selected: Set<Int> = []
            var context: AuthorFeedbackResidual?
            coordinator.onNeedsWork = { _, ids, _, supplied in selected = ids; context = supplied }
            // when
            try await fixture.run(coordinator)
            // then
            #expect(selected == [10])
            #expect(context != nil)
            #expect(context?.assessedRunID == nil)
            #expect(context?.notes.first?.state == .addressed)
            #expect(context?.codeReviewRequests.first?.question == assessment.reviewRequests.first?.question)
            #expect(coordinator.status(projectID: 1, iid: 2)?.followUpNoteIDs == [10])
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == true)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.allSatisfy { $0.state != .needsChanges } == true)
            #expect(assessment.notes.first?.state == .addressed)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let fingerprint = try #require(ReviewVerdict.fingerprint(try fixture.discussions()))
            #expect(coordinator.reviewContext(for: request, fingerprint: fingerprint)?.codeReviewRequests == assessment.reviewRequests)
            #expect(!fixture.resolved && fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.blocking, .addressed])
    func personalNoReplyPreferencePreservesTechnicalWorkWithoutPreparingAReply(_ state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { f in
            f.settings.automation.authorFeedback.isEnabled = true
            f.settings.automation.autoResolveAcceptedFeedback = true
            f.settings.reviewParticipationPreferences.exclude(.init(host: Fixture.host, entityID: 7, label: "@alice"), username: "me")
            try f.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix overflow","resolvable":true,"resolved":false}]}]"#)
            let coordinator = f.coordinator(assessment: .init(notes: [.init(noteID: 10, state: state, reason: "Technical overflow concern.")]))
            var dispatched: Set<Int> = []
            coordinator.onNeedsWork = { _, ids, _, _ in dispatched.formUnion(ids) }
            try await f.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.replyNoteIDs.isEmpty)
            #expect(dispatched == (state == .blocking ? [10] : []))
            #expect(f.inputs.first?.excludedReplyAuthorIDs == [7])
            #expect(f.reactionPosts == 0 && f.resolutionPosts == 0)
        }
    }

    @Test(arguments: [false, true])
    func sharedPublishedReplyStillDispatchesTheReplyOwedInTheOriginalThread(_ approved: Bool) async throws {
        try await withFixture { fixture in
            // given
            fixture.settings.automation.authorFeedback.isEnabled = true
            if !approved { try fixture.write("approvals.json", #"{"approved_by":[]}"#) }
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"resolvable":true,"resolved":false,"body":"Fix shared access."}]},{"id":"thread-b","notes":[{"id":11,"author":{"id":3,"username":"me"},"system":false,"body":"The verified shared correction also answers note 10."}]}]"#)
            let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(#"{"notes":[{"noteID":10,"state":"addressed","reason":"The current correction and published shared answer fully address this concern.","publishedReplyNoteID":11}]}"#.utf8))
            let coordinator = fixture.coordinator(assessment: assessment)
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, ids, _, _ in requested.formUnion(ids) }
            // when
            try await fixture.run(coordinator)
            // then
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete && status.addressedNoteIDs.isEmpty)
            #expect(status.replyNoteIDs == [10] && status.followUpNoteIDs == [10] && requested == [10])
            #expect(status.needsAttention)
            #expect(status.acceptedReviewerIDs == (approved ? [7] : []))
            #expect(fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [false, true])
    func addressingAnotherConcernInAnIgnoredSourceStillRequiresItsPublishedReply(_ withReply: Bool) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.authorFeedback.isEnabled = true
            let source = try #require(fixture.discussions().first?.notes.first)
            let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
            let entry = IgnoredFeedbackSuggestion(id: UUID(), target: target, sourceNoteID: source.id!, sourceAuthorID: source.author!.id,
                sourceBody: source.body!, sourceRevision: UserAttentionSnapshot.digest("\(source.author!.id)\n" + source.body!),
                concernSummary: "Decline only the optional assumption.", concernReason: "Another correction is still required.", createdAt: Date())
            fixture.settings.feedbackSuggestionDecisions = try JSONDecoder().decode(FeedbackSuggestionDecisions.self,
                from: JSONEncoder().encode(["decisions": [entry]]))
            if !withReply {
                let discussion = GitLabMergeRequestDiscussion(id: "thread-a", notes: [source])
                try fixture.write("discussions.json", String(decoding: JSONEncoder().encode([discussion]), as: UTF8.self))
            }
            let coordinator = fixture.coordinator(assessment: .init(notes: [.init(noteID: 10, state: .addressed,
                reason: "A different concern in this note is fixed; the optional assumption was user-declined.", ignoredDecisionIDs: [entry.id])]))

            try await fixture.run(coordinator)

            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete)
            #expect(status.replyNoteIDs == (withReply ? [] : [10]))
            #expect(!fixture.resolved && fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: ["ignoredOnly", "sameNoteRemaining", "siblingRemaining", "restoredDuringVerification", "addedDuringVerification", "editedSource"])
    func preciseUserDecisionsDoNotBecomeSuccessfulFixesOrHideRemainingWork(_ scenario: String) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.authorFeedback.isEnabled = true
            let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
            let source = try #require(fixture.discussions().first?.notes.first)
            let entry = IgnoredFeedbackSuggestion(id: UUID(), target: target, sourceNoteID: source.id!, sourceAuthorID: source.author!.id,
                sourceBody: source.body!, sourceRevision: UserAttentionSnapshot.digest("\(source.author!.id)\n" + source.body!),
                concernSummary: "Decline only this optional assumption.", concernReason: "Other requested corrections remain required.", createdAt: Date())
            if scenario != "addedDuringVerification" {
                fixture.settings.feedbackSuggestionDecisions = try JSONDecoder().decode(FeedbackSuggestionDecisions.self,
                    from: JSONEncoder().encode(["decisions": [entry]]))
            }
            if scenario == "editedSource" {
                try fixture.write("discussions.json", "[" + Fixture.thread.replacingOccurrences(of: "Fix A", with: "A newly edited request") + "]")
            }
            var notes = [ReReviewAssessment.Note(noteID: 10,
                state: ["sameNoteRemaining", "addedDuringVerification"].contains(scenario) ? .blocking : .ignoredByUser,
                reason: scenario == "sameNoteRemaining" ? "Another obligation in this same comment remains." : "Only the precise declined concern remains.",
                ignoredDecisionIDs: scenario == "addedDuringVerification" ? nil : [entry.id])]
            if scenario == "siblingRemaining" {
                try fixture.write("discussions.json", "[" + Fixture.thread + "," + Fixture.condition.replacingOccurrences(of: "\"id\":7", with: "\"id\":8") + "]")
                notes.append(.init(noteID: 20, state: .blocking, reason: "A separate comment still requires correction."))
            }
            let coordinator = fixture.coordinator(assessment: .init(notes: notes), duringVerification: {
                if scenario == "restoredDuringVerification" { fixture.settings.feedbackSuggestionDecisions.remove(entry.id, for: target) }
                if scenario == "addedDuringVerification" {
                    fixture.settings.feedbackSuggestionDecisions.ignore(source, concernSummary: entry.concernSummary,
                        concernReason: entry.concernReason, for: target)
                }
            })
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, ids, _, _ in requested.formUnion(ids) }

            if ["restoredDuringVerification", "addedDuringVerification"].contains(scenario) {
                try fixture.start(coordinator)
                try await fixture.waitForVerification()
                try await Task.sleep(for: .milliseconds(100))
            } else {
                try await fixture.run(coordinator)
            }

            let status = coordinator.status(projectID: 1, iid: 2)
            if ["restoredDuringVerification", "addedDuringVerification"].contains(scenario) {
                #expect(status?.phase != .complete)
                #expect(requested.isEmpty)
            } else if scenario == "editedSource" {
                #expect(status?.ignoredNoteIDs.isEmpty != false)
                #expect(status?.phase != .complete)
                #expect(fixture.inputs.count == 3)
                #expect(fixture.retryDelays == [.seconds(2), .seconds(8)])
            } else {
                #expect(requested == (scenario == "sameNoteRemaining" ? [10] : scenario == "siblingRemaining" ? [20] : []))
                #expect(status?.ignoredNoteIDs == (scenario == "sameNoteRemaining" ? [] : [10]))
                #expect(status?.addressedNoteIDs.contains(10) == false)
                #expect(fixture.inputs.first?.ignoredSuggestions.map(\.id) == [entry.id])
            }
            #expect(!fixture.resolved && fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [false, true])
    func onlyASourceBoundPureOptOutCanRetireAnAdministrativeBlockedAttemptWithoutReplying(_ pureOptOut: Bool) async throws {
        try await withFixture { f in
            f.settings.automation.autoResolveAcceptedFeedback = true
            f.settings.automation.authorFeedback.isEnabled = true
            let quote = "Do not invite me to reviews"
            try f.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"\#(quote)","resolvable":false,"resolved":false}]}]"#)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Administrative feedback", prompt: "Handle selected feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: .blocked, finishedAt: Date(timeIntervalSince1970: 2),
                    summary: "No code change is needed; participant already removed their review request.",
                    blocker: "Administrative acknowledgement has no source/test files."),
                workflow: .followUp, expectedHeadSHA: request.sha)
            f.settings.assistantHandoffs = [job]
            let coordinator = f.coordinator(assessment: .init(notes: [.init(noteID: 10, state: .informational,
                reason: "No technical work remains.", informationalAcknowledgementSafe: false, informationalPurpose: .other,
                reviewerOptOut: pureOptOut ? .init(sourceQuote: quote) : nil)], completedBlockedRunIDs: [job.id]))
            var dispatched = false
            coordinator.onNeedsWork = { _, _, _, _ in dispatched = true }
            try await f.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.reconciles(job, request: request, discussionFingerprint: ReviewVerdict.fingerprint(try f.discussions())) == pureOptOut)
            #expect(status.replyNoteIDs.isEmpty && !dispatched)
            #expect(f.settings.assistantHandoffs.first?.execution?.state == .blocked)
            #expect(f.reactionPosts == 0 && f.resolutionPosts == 0)
        }
    }

    @Test func changedBlockedStepRequiresANewAssessmentAtTheSameHeadAndDiscussions() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Feedback", prompt: "Handle selected feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: .blocked, finishedAt: Date(timeIntervalSince1970: 2),
                    summary: "Selected feedback is complete.", blocker: "Later release confirmation is absent."),
                workflow: .followUp, expectedHeadSHA: request.sha)
            fixture.settings.assistantHandoffs = [job]
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { input, _, _ in
                    fixture.inputs.append(input)
                    return .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current correction verified")],
                        completedBlockedRunIDs: fixture.inputs.count == 1 ? [job.id] : nil)
                })
            try await fixture.run(coordinator)
            fixture.settings.assistantHandoffs[0].execution?.blocker = "A required current-task verification command failed."

            try fixture.start(coordinator)

            let deadline = ContinuousClock.now + .seconds(5)
            while fixture.inputs.count < 2 || coordinator.status(projectID: 1, iid: 2)?.phase == .checking,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.inputs.count == 2)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let current = try #require(fixture.settings.assistantHandoffs.first)
            #expect(!status.reconciles(current, request: request,
                discussionFingerprint: ReviewVerdict.fingerprint(try fixture.discussions())))
        }
    }

    @Test(arguments: ["exact", "missingProof", "wrongRun", "changedHead", "changedContext", "changedDiscussions", "changedBlocker", "missingReply", "unverifiedTool", "nonfeedback", "wrongAccount"])
    func blockedFeedbackRequiresFreshExactRunCompletionProof(_ scenario: String) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            if scenario == "missingReply" {
                try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix A and explain it.","resolvable":true,"resolved":false}]}]"#)
            }
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: scenario == "wrongAccount" ? "other" : "me",
                workspace: "", access: .gitLabRead), title: "Feedback correction", prompt: "Handle selected feedback",
                createdAt: Date(timeIntervalSince1970: 1), allowsPush: false, feedbackNoteIDs: [10],
                followUpPushAllowed: true, execution: .init(state: .blocked, finishedAt: Date(timeIntervalSince1970: 2),
                    summary: "The current correction and published explanation are complete.",
                    blocker: scenario == "unverifiedTool" ? "Required verification tool is unavailable." : "Confirm a later release dependency with its owner."),
                taskPrompt: "Handle selected feedback", mergeRequestURL: request.webURL,
                workflow: scenario == "nonfeedback" ? .review : .followUp, expectedHeadSHA: request.sha)
            fixture.settings.assistantHandoffs = [job]
            let proof: [UUID]? = ["missingProof", "unverifiedTool"].contains(scenario) ? nil : [scenario == "wrongRun" ? UUID() : job.id]
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .addressed, reason: "The current correction and published answer satisfy the assigned feedback.")
            ], completedBlockedRunIDs: proof), duringVerification: {
                if scenario == "changedBlocker" { fixture.settings.assistantHandoffs[0].execution?.blocker = "A newly failed required verification step." }
            })
            var dispatched = false
            coordinator.onNeedsWork = { _, _, _, _ in dispatched = true }

            try await fixture.run(coordinator)

            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let checkedRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(
                (scenario == "changedHead" ? Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40))
                 : scenario == "changedContext" ? Fixture.request.replacingOccurrences(of: "Example MR", with: "Changed requirement")
                 : Fixture.request).utf8))
            let fingerprint = scenario == "changedDiscussions" ? "different-discussions" : ReviewVerdict.fingerprint(try fixture.discussions())
            #expect(status.reconciles(job, request: checkedRequest, discussionFingerprint: fingerprint) == (scenario == "exact"))
            if scenario == "exact" {
                let context = try #require(fixture.inputs.last?.blockedFollowUps.first)
                #expect(context.runID == job.id && context.selectedFeedbackIDs == [10])
                #expect(context.blocker == job.execution?.blocker)
                #expect(status.findings.first?.state == .waitingAcceptance)
                #expect(!dispatched)
                #expect(!AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                    currentRequest: request, feedbackStatus: status, discussionFingerprint: fingerprint))
            }
            #expect(fixture.settings.assistantHandoffs[0].execution?.state == .blocked)
            #expect(fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test func aDefaultDraftDoesNotStartPaidFeedbackVerification() async throws {
        try await withFixture { fixture in
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            let coordinator = fixture.coordinator()
            try fixture.start(coordinator, requestJSON: draft)
            await Task.yield()
            #expect(!fixture.verified && fixture.inputs.isEmpty)
            #expect(coordinator.status(projectID: 1, iid: 2) == nil)
            #expect(!fixture.resolved && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [false, true])
    func forceOnDraftCanRequestScopedFixesAndForceOffRevokesThem(_ revoke: Bool) async throws {
        try await withFixture { fixture in
            let target = MRAutomationScope.Target(host: Fixture.host, username: "me", projectID: 1, iid: 2)
            fixture.settings.automation.scope.setManualChoice(.forceOn, for: target)
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "A scoped correction is still required")
            ]), duringVerification: {
                if revoke { fixture.settings.automation.scope.setManualChoice(.paused, for: target) }
            })
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { request, notes, _, _ in
                #expect(request.draft == true)
                requested = notes
            }
            try await fixture.run(coordinator, requestJSON: draft)
            #expect(fixture.verified)
            #expect(requested == (revoke ? [] : [10]))
            #expect(!fixture.resolved)
        }
    }

    @Test(arguments: [0, 1])
    func forceOnDraftResolvesAcceptedFeedbackOnlyWithoutPendingReplies(_ pendingDrafts: Int) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.scope.setManualChoice(.forceOn,
                for: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            if pendingDrafts > 0 {
                try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"Private reply awaiting publication"}]"#)
            }
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator, requestJSON: draft, drafts: pendingDrafts)
            #expect(fixture.verified)
            #expect(fixture.resolved == (pendingDrafts == 0))
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == (pendingDrafts == 0 ? .complete : .waitingPublication))
        }
    }

    @Test func approvedReviewerCannotWaiveAPublishedReplyBeforeStoppedAttemptReconciliation() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix A and explain the result.","resolvable":true,"resolved":false,"created_at":"2026-01-01T10:00:00Z"}]}]"#)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Stopped feedback", prompt: "Handle feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: .interrupted, finishedAt: Date(timeIntervalSince1970: 2)), workflow: .followUp,
                expectedHeadSHA: request.sha)
            fixture.settings.assistantHandoffs = [job]
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let fingerprint = ReviewVerdict.fingerprint(try fixture.discussions())
            #expect(status.findings.first?.state == .needsReply)
            #expect(!status.reconciles(job, request: request, discussionFingerprint: fingerprint))
            #expect(AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                currentRequest: request, feedbackStatus: status, discussionFingerprint: fingerprint))
            #expect(fixture.settings.assistantHandoffs[0].execution?.state == .interrupted)
            #expect(fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [false, true])
    func completedFollowUpReadFailureKeepsCooldownWithoutItsSuccessfulAssessmentCache(priorAssessment: Bool) async throws {
        try await withFixture { fixture in
            let state = RetryState()
            state.recovered = priorAssessment
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { _, _, _ in
                    state.calls += 1
                    if state.recovered { return .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current evidence verified")]) }
                    throw ReReviewVerifier.VerificationError.failed
                }, retryWait: { _ in await Task.yield() }, now: { state.now })
            if priorAssessment { try await fixture.run(coordinator) }
            let baseline = state.calls
            state.recovered = false
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            fixture.settings.assistantHandoffs.append(.init(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Completed feedback", prompt: "Handle feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: .succeeded, finishedAt: Date(timeIntervalSince1970: 2)), workflow: .followUp,
                expectedHeadSHA: request.sha))
            try await fixture.run(coordinator)
            #expect(state.calls == baseline + 3)
            try await fixture.run(coordinator)
            #expect(state.calls == baseline + 3)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .failed)
            state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
            state.recovered = true
            try await fixture.run(coordinator)
            #expect(state.calls == baseline + 4)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
        }
    }

    @Test func successfulNoChangeFollowUpRequiresANewAssessmentBeforeItsResidualWorkCanBeReused() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "The observed defect is independently unresolved")
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.inputs.count == 1)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            fixture.settings.assistantHandoffs.append(.init(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Completed feedback", prompt: "Handle feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: .succeeded, finishedAt: Date(timeIntervalSince1970: 2), summary: "No source change"),
                taskPrompt: "Handle feedback", mergeRequestURL: request.webURL, workflow: .followUp,
                expectedHeadSHA: request.sha))

            try await fixture.run(coordinator)
            let deadline = ContinuousClock.now + .seconds(5)
            while fixture.inputs.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.inputs.count == 2)
            #expect(fixture.inputs.last?.completedFollowUp?.runID == fixture.settings.assistantHandoffs.last?.id)
            #expect(fixture.inputs.last?.completedFollowUp?.summary == "No source change")
            try await fixture.run(coordinator)
            #expect(fixture.inputs.count == 2)
            #expect(fixture.resolutionPosts == 0)
        }
    }

    @Test(arguments: [AssistantJobExecution.State.interrupted, .cancelled, .failed])
    func freshFeedbackPostconditionsRetireOnlyTheStoppedAttemptAttention(state: AssistantJobExecution.State) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: Fixture.host, projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Stopped feedback", prompt: "Handle feedback", createdAt: Date(timeIntervalSince1970: 1),
                allowsPush: false, feedbackNoteIDs: [10], followUpPushAllowed: true,
                execution: .init(state: state, finishedAt: Date(timeIntervalSince1970: 2), error: "Original attempt"),
                taskPrompt: "Handle feedback", mergeRequestURL: request.webURL, workflow: .followUp,
                expectedHeadSHA: request.sha)
            fixture.settings.assistantHandoffs = [job]
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
                url: request.webURL, authorFeedbackStatus: status,
                observedDiscussionFingerprint: ReviewVerdict.fingerprint(try fixture.discussions()),
                mergeRequest: request, isAuthored: true)
            let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
            #expect(!row.stoppedJobNeedsAttention)
            #expect(!row.needsAttention)
            #expect(MRHumanAction(row: row, assistantReady: true) == nil)
            let group = try #require(AssistantTaskGroup.groups(from: [job], host: Fixture.host, username: "me").first)
            #expect(group.manualHandoff(currentItem: item) == nil)
            #expect(!AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                currentRequest: request, feedbackStatus: status, discussionFingerprint: item.observedDiscussionFingerprint))
            #expect(AssistantJobExecution.hasUnfinishedWork(in: [job], for: job.key.work, username: "me",
                currentRequest: request, feedbackStatus: status, discussionFingerprint: "changed conversation"))
            #expect(fixture.settings.assistantHandoffs[0].execution?.state == state)
            #expect(!fixture.resolved)

            item.hasConflict = true
            let conflict = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
            #expect(conflict.needsAttention)
            #expect(MRHumanAction(row: conflict, assistantReady: true)?.kind == .intent)

            item.hasConflict = false
            item.observedDiscussionFingerprint = "changed conversation"
            let stale = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
            #expect(stale.stoppedJobNeedsAttention)
            #expect(group.manualHandoff(currentItem: item)?.id == job.id)
        }
    }

    @Test(arguments: VerificationThinking.allCases)
    func passesTheSelectedThinkingToFeedbackVerification(_ thinking: VerificationThinking) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.verificationThinking = thinking
            try await fixture.run(fixture.coordinator())
            #expect(fixture.inputs.map(\.thinking) == [thinking])
        }
    }

    @MainActor private final class RetryState {
        var calls = 0
        var now = Date()
        var recovered = false
        weak var coordinator: AuthorFeedbackCoordinator?
    }

    @Test func transientVerificationFailureRetriesBeforeFeedbackActions() async throws {
        try await withFixture { fixture in
            var calls = 0
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { _, _, _ in
                    calls += 1
                    if calls == 1 { throw ReReviewVerifier.VerificationError.failed }
                    return .init(notes: [.init(noteID: 10, state: .addressed, reason: "The current fix is verified")])
                }, retryWait: { _ in await Task.yield() })
            try await fixture.run(coordinator)
            #expect(calls == 2)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(fixture.resolutionPosts == 1)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.uncertain, .blocking])
    func completedSemanticVerdictIsReusedWhenFinalMRReadFails(_ verdict: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            try fixture.write("fail-request-once", "yes")
            let state = RetryState()
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { _, _, _ in
                    state.calls += 1
                    return .init(notes: [.init(noteID: 10, state: verdict, reason: "A completed semantic verdict")])
                }, retryWait: { _ in await Task.yield() })
            try await fixture.run(coordinator)
            #expect(state.calls == 1)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(fixture.resolutionPosts == 0)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let discussions = try fixture.discussions()
            let fingerprint = try #require(ReviewVerdict.fingerprint(discussions))
            #expect(coordinator.assessment(for: request, fingerprint: fingerprint)?.notes.first?.state == verdict)
        }
    }

    @Test func failureAfterResolutionDoesNotReplayTheFeedbackProcess() async throws {
        try await withFixture { fixture in
            try fixture.write("fail-discussions-after-resolution", "yes")
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            try await fixture.run(coordinator)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .failed)
            #expect(coordinator.status(projectID: 1, iid: 2)?.isReadOnlyFailure == false)
            #expect(fixture.inputs.count == 1)
            #expect(fixture.resolutionPosts == 1)
        }
    }

    @Test(arguments: ["cooldown", "dependency"])
    func exhaustedReadOnlyBudgetStaysBoundedAcrossQueuedRefreshes(_ recovery: String) async throws {
        try await withFixture { fixture in
            let state = RetryState()
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { _, _, _ in
                    state.calls += 1
                    if state.recovered { return .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current evidence recovered")]) }
                    throw ReReviewVerifier.VerificationError.failed
                }, retryWait: { _ in
                    let running = try #require(state.coordinator)
                    #expect(running.status(projectID: 1, iid: 2)?.phase == .checking)
                    try fixture.start(running)
                    await Task.yield()
                }, now: { state.now })
            state.coordinator = coordinator
            let running = coordinator
            try await fixture.run(running)
            for _ in 0..<20 { await Task.yield() }
            try await fixture.run(running)
            #expect(state.calls == 3)
            let status = try #require(running.status(projectID: 1, iid: 2))
            #expect(status.phase == .failed && status.isReadOnlyFailure)
            #expect(status.failureReason?.isEmpty == false)
            #expect(fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
            if recovery == "cooldown" { state.now = state.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1) }
            else { running.retryReadOnlyFailures() }
            state.recovered = true
            try await fixture.run(running)
            #expect(state.calls == 4)
            #expect(running.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(fixture.resolutionPosts == 1)
        }
    }

    @Test func accountChangeDuringReadOnlyBackoffPreventsActionsAndFurtherAttempts() async throws {
        try await withFixture { fixture in
            var calls = 0
            let coordinator = AuthorFeedbackCoordinator(settings: fixture.settings, glab: fixture.glab,
                canAutomate: { _ in true }, verify: { _, _, _ in
                    calls += 1
                    throw ReReviewVerifier.VerificationError.failed
                }, retryWait: { _ in fixture.glab.currentUsername = "another-account" })
            try fixture.start(coordinator)
            let deadline = ContinuousClock.now + .seconds(5)
            while fixture.glab.currentUsername == "me", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(calls == 1)
            #expect(fixture.resolutionPosts == 0 && fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.blocking, .uncertain, .addressed])
    func unrelatedPrivateDraftDoesNotSuppressIncomingFeedback(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            // given
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"An uncertain earlier reply"}]"#)
            let incoming = Fixture.condition.replacingOccurrences(of: "\"resolvable\":false", with: "\"resolvable\":true,\"resolved\":false")
            try fixture.write("discussions.json", "[\(Fixture.thread),\(incoming)]")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .uncertain, reason: "Earlier reply still needs evidence"),
                .init(noteID: 20, state: state, reason: "Independent incoming feedback needs a follow-up")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }

            // when
            try await fixture.run(coordinator, drafts: 1)

            // then
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(requested == [20])
            #expect(status.followUpNoteIDs == [20])
            #expect(status.phase == .waitingPublication && status.pendingDraftCount == 1)
            #expect(!fixture.resolved)
            #expect(fixture.gitlab.data("drafts.json")
                == Data(#"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"An uncertain earlier reply"}]"#.utf8))
        }
    }

    @Test(arguments: [7, 8], ["readyMissing", "readyPublished", "draftMissing", "draftPublished", "pendingDraftMissing"])
    func addressedChildKeepsThreadReplyIndicatorAndDispatchesItsExactNote(childAuthorID: Int, scenario: String) async throws {
        try await withFixture { fixture in
            let draft = scenario.hasPrefix("draft")
            let published = scenario.hasSuffix("Published")
            let pendingDrafts = scenario == "pendingDraftMissing" ? 1 : 0
            let readOnly = pendingDrafts > 0
            if draft {
                fixture.settings.automation.scope.setManualChoice(.forceOn,
                    for: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
            }
            let requestJSON = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":\(draft)")
            try fixture.write("request.json", requestJSON)
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            if pendingDrafts > 0 {
                try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"A private reply in the assessed thread"}]"#)
            }
            let authorReply = published ? #",{"id":30,"author":{"id":3,"username":"me"},"system":false,"body":"The scoped correction is verified.","resolvable":true,"resolved":false}"# : ""
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Positive acknowledgement","resolvable":true,"resolved":false},{"id":20,"author":{"id":\#(childAuthorID),"username":"reviewer"},"system":false,"body":"Please also rename X","resolvable":true,"resolved":false}\#(authorReply)]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "The root requests no action"),
                .init(noteID: 20, state: .addressed, reason: "The child correction is verified")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator, requestJSON: requestJSON, drafts: pendingDrafts)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.replyNoteIDs == (published ? [] : [10]))
            let expectedWork: Set<Int> = !readOnly && !published ? [20] : []
            #expect(status.followUpNoteIDs == expectedWork && requested == expectedWork)
            #expect(status.phase == (pendingDrafts > 0 ? .waitingPublication : .complete))
            #expect(status.needsAttention == !published)
            if !readOnly { #expect(status.findings.first?.state == (published ? .waitingAcceptance : .needsReply)) }
            #expect(status.findings.allSatisfy { !$0.canResolve })
            #expect(!fixture.resolved)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
            let discussions = try fixture.discussions()
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
                url: request.webURL, needsDiscussion: true, mergeRequest: request, isAuthored: true,
                feedback: discussions.flatMap(\.notes).filter { $0.author?.id != 3 })
            item.observedDiscussionFingerprint = ReviewVerdict.fingerprint(discussions)
            item.authorFeedbackStatus = status
            let visible = item.presentingVerifiedAuthorFeedback()
            #expect(visible.feedback.contains { $0.id == 20 } == !published)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.informational, .addressed])
    func openRootRequiresAnAuthorReplyOnlyForAddressedActionableFeedback(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Scoped feedback","resolvable":true,"resolved":false}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: state, reason: "Current scoped feedback assessment")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let requiresReply = state == .addressed
            #expect(status.phase == .complete)
            #expect(status.replyNoteIDs == (requiresReply ? [10] : []))
            #expect(status.followUpNoteIDs == (requiresReply ? [10] : []))
            #expect(requested == (requiresReply ? [10] : []))
            #expect(status.findings.first?.state == (requiresReply ? .needsReply : .waitingAcceptance))
            #expect(status.findings.allSatisfy { !$0.canResolve })
            #expect(!fixture.resolved)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
                url: request.webURL, needsDiscussion: true, mergeRequest: request, isAuthored: true,
                feedback: [try #require(fixture.discussions().first?.notes.first)])
            item.observedDiscussionFingerprint = ReviewVerdict.fingerprint(try fixture.discussions())
            item.authorFeedbackStatus = status
            let row = MergeRequestBoardSnapshot.Row(item: item.presentingVerifiedAuthorFeedback(), latestJob: nil, intents: [])
            #expect(row.needsAttention == requiresReply)
            #expect((MRHumanAction(row: row, assistantReady: true)?.action == .handleFeedback) == requiresReply)
        }
    }

    @Test(arguments: ["none", "own", "other", "ownLaterPage", "ghost"])
    func purelyInformationalThreadReceivesOneThumbsUpAndResolvesWithoutApproval(existingReaction: String) async throws {
        try await withFixture { fixture in
            let thread = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The scoped error mapping looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(thread)]")
            try fixture.write("resolved.json", thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            let ownAward = #"[{"id":40,"name":"thumbsup","user":{"id":3,"username":"me"}}]"#
            let otherAward = #"[{"id":41,"name":"thumbsup","user":{"id":8,"username":"other"}}]"#
            if existingReaction == "own" { try fixture.write("awards.json", ownAward) }
            if existingReaction == "other" { try fixture.write("awards.json", otherAward) }
            if existingReaction == "ghost" { try fixture.write("awards.json", #"[{"id":41,"name":"thumbsup","user":null}]"#) }
            if existingReaction == "ownLaterPage" { try fixture.write("awards.json", otherAward + "\n" + ownAward) }
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "A positive acknowledgement with no request or condition", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == (["own", "ownLaterPage"].contains(existingReaction) ? 0 : 1))
            #expect(fixture.resolved)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete)
            #expect(status.acceptedReviewerIDs.isEmpty)
            #expect(status.replyNoteIDs.isEmpty && requested.isEmpty)
            #expect(!status.needsAttention)
        }
    }

    @Test(arguments: ["humanSummary", "humanAIHelp", "botSummary", "botNoFindings", "botCodeShape", "botConcrete", "serviceSummary", "serviceConcrete", "automatedReport", "automatedStatus", "unclearPurpose", "unknownAccount", "failedIdentity", "wrongIdentity", "legacyBotPurpose", "legacyRegularPurpose"])
    func courtesyReactionUsesAccountIdentityAndCommentPurposeIndependentlyOfResolution(_ scenario: String) async throws {
        try await withFixture { fixture in
            let isBot = scenario.hasPrefix("bot") || scenario == "legacyBotPurpose"
            let service = scenario.hasPrefix("service")
            let concrete = scenario.hasSuffix("Concrete")
            let purpose = concrete ? "concreteCodeReviewFeedback" : scenario == "automatedReport" ? "automatedReviewReport"
                : ["automatedStatus", "unclearPurpose"].contains(scenario) ? "other" : "reviewSummary"
            let body = scenario == "humanAIHelp" ? "I used AI to help review this change; it looks good."
                : concrete ? "The null guard in Parser.read now safely rejects the missing header."
                : scenario == "automatedReport" ? "No findings. Generated by Review Runner. Pipeline: https://example.test/pipelines/1"
                : scenario == "automatedStatus" ? "Changelog entry has been automatically generated and committed to your branch."
                : scenario == "botNoFindings" ? "Review complete; no findings."
                : scenario == "botCodeShape" ? "The code is organized clearly and follows the existing module structure."
                : "Review summary: checks passed and the change looks good."
            let thread = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"system":false,"body":"\#(body)","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(thread)]")
            try fixture.write("resolved.json", thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            let identity = scenario == "unknownAccount" ? #"{"id":7,"username":"reviewer"}"#
                : #"{"id":\#(scenario == "wrongIdentity" ? 99 : 7),"username":"reviewer","bot":\#(isBot),"user_type":"\#(service ? "service_account" : "human")"}"#
            try fixture.write("reviewer.json", identity)
            if scenario == "failedIdentity" { try fixture.write("fail-reviewer", "yes") }
            let purposeField = ["legacyBotPurpose", "legacyRegularPurpose"].contains(scenario) ? "" : #","informationalPurpose":"\#(purpose)""#
            let assessment = try JSONDecoder().decode(ReReviewAssessment.self, from: Data(
                #"{"notes":[{"noteID":10,"state":"informational","reason":"No remaining expectation","informationalAcknowledgementSafe":true\#(purposeField)}]}"#.utf8))
            let coordinator = fixture.coordinator(assessment: assessment)

            try await fixture.run(coordinator)

            let reacts = ["humanSummary", "humanAIHelp", "botConcrete", "serviceConcrete"].contains(scenario)
            #expect(fixture.reactionPosts == (reacts ? 1 : 0))
            #expect(fixture.resolved)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete && !status.needsAttention)
        }
    }

    @Test func resolvedInformationalHistoryReceivesNoNewReactionOrLiveAcknowledgementReads() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The mapping looks good.","resolvable":true,"resolved":true}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "A closed historical acknowledgement", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == 0 && fixture.awardReads == 0 && fixture.userReads == 0)
            #expect(fixture.resolutionPosts == 0)
        }
    }

    @Test func acknowledgedSummaryDoesNotRepeatAwardOrLiveAccountReadsAfterANewHead() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", #"[{"id":"summary","notes":[{"id":20,"author":{"id":7,"username":"alice"},"system":false,"body":"Review complete, all good.","resolvable":false}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 20, state: .informational, reason: "A pure review acknowledgement", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            let reads = fixture.awardReads
            let accounts = fixture.userReads
            #expect(fixture.reactionPosts == 1 && reads == 2)
            let updated = Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40))
            try fixture.write("request.json", updated)
            try await fixture.run(coordinator, requestJSON: updated)
            #expect(fixture.reactionPosts == 1)
            #expect(fixture.awardReads == reads && fixture.userReads == accounts)
        }
    }

    @Test func freshInformationalWorkIsBoundedAndLaterCandidatesProgressOnNextProcess() async throws {
        try await withFixture { fixture in
            let ids = Array(20..<40)
            let summaries = ids.map { id in
                #"{"id":"summary-\#(id)","notes":[{"id":\#(id),"author":{"id":7,"username":"alice"},"system":false,"body":"Review section \#(id) looks good.","resolvable":false}]}"#
            }
            try fixture.write("discussions.json", "[" + summaries.joined(separator: ",") + "]")
            let coordinator = fixture.coordinator(assessment: .init(notes: ids.map {
                .init(noteID: $0, state: .informational, reason: "A pure positive review summary", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            }))
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == 4 && fixture.awardReads == 8)
            #expect(fixture.userReads <= 4)
            try fixture.start(coordinator)
            let deadline = ContinuousClock.now + .seconds(15)
            while fixture.awardReads < 16 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(fixture.reactionPosts == 8 && fixture.awardReads == 16)
            #expect(fixture.userReads <= 8)
        }
    }

    @Test func pureInformationalGeneralNoteReceivesReactionWithoutResolution() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", #"[{"id":"summary","notes":[{"id":20,"author":{"id":7,"username":"alice"},"system":false,"body":"Review complete, all good.","resolvable":false}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 20, state: .informational, reason: "A pure review acknowledgement", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == 1)
            #expect(!fixture.resolved)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete && !status.needsAttention)
            #expect(status.acceptedReviewerIDs.isEmpty && status.replyNoteIDs.isEmpty)
        }
    }

    @Test(arguments: ["GET", "POST"])
    func failedReactionCannotSuppressIndependentFeedbackOrReplayOnEveryPoll(_ phase: String) async throws {
        try await withFixture { fixture in
            let praise = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The scoped mapping looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(praise),\(Fixture.condition)]")
            try fixture.write("resolved.json", praise.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try fixture.write(phase == "GET" ? "fail-award-read" : "fail-award", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No remaining expectation in this thread", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary),
                .init(noteID: 20, state: .blocking, reason: "The independent rename still needs work")
            ]))
            var requested: Set<Int> = []
            var dispatches = 0
            coordinator.onNeedsWork = { _, notes, _, _ in requested.formUnion(notes); dispatches += 1 }
            try await fixture.run(coordinator)
            try fixture.start(coordinator)
            let deadline = ContinuousClock.now + .seconds(15)
            while dispatches < 2 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(dispatches == 2)
            #expect(requested == [20])
            #expect(fixture.reactionPosts == (phase == "GET" ? 0 : 1))
            #expect(fixture.awardReads == 1)
            #expect(fixture.resolved)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete && status.followUpNoteIDs == [20])
            #expect(!status.findings.contains { $0.id == 10 && $0.state == .needsVerification })
        }
    }

    @Test(arguments: ["denied", "responseLostButClosed"])
    func informationalResolutionFailureIsReconciledAndRemainsVisibleWhileFenced(_ scenario: String) async throws {
        try await withFixture { fixture in
            let praise = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The scoped mapping looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(praise)]")
            try fixture.write("resolved.json", praise.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try fixture.write(scenario == "denied" ? "deny-resolve" : "lose-resolve-response", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No remaining expectation", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.phase == .complete)
            #expect(fixture.resolutionPosts == 1)
            if scenario == "denied" {
                #expect(!fixture.resolved)
                #expect(status.needsAttention)
                #expect(status.findings.first?.state == .needsVerification)
                #expect(status.findings.first?.reason?.isEmpty == false)
                #expect(!status.addressedNoteIDs.contains(10))
            } else {
                #expect(fixture.resolved)
                #expect(!status.needsAttention && status.findings.isEmpty)
            }
            // The cached content is unchanged. A subsequent poll must not replay the PUT or
            // replace a verified closure failure with a ready-to-resolve finding.
            try fixture.start(coordinator)
            try await Task.sleep(for: .milliseconds(250))
            #expect(fixture.resolutionPosts == 1)
            let refreshed = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(refreshed.needsAttention == (scenario == "denied"))
            #expect(refreshed.findings.first?.state == (scenario == "denied" ? .needsVerification : nil))
            if scenario == "denied" {
                fixture.gitlab.remove("deny-resolve")
                coordinator.invalidate(projectID: 1, iid: 2)
                try await fixture.run(coordinator)
                #expect(fixture.resolutionPosts == 2 && fixture.resolved)
                #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == false)
            }
        }
    }

    @Test(arguments: ["head", "otherThread"])
    func unrelatedRevisionChangesDoNotReplayAFailedResolution(_ change: String) async throws {
        try await withFixture { fixture in
            let praise = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The scoped mapping looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(praise),\(Fixture.condition)]")
            try fixture.write("deny-resolve", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No remaining expectation in this thread", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary),
                .init(noteID: 20, state: .blocking, reason: "The independent rename remains outstanding")
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.resolutionPosts == 1)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.first?.state == .needsVerification)
            let updated = change == "head" ? Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)) : Fixture.request
            try fixture.write("request.json", updated)
            if change == "otherThread" {
                try fixture.write("discussions.json", "[\(praise),\(Fixture.condition.replacingOccurrences(of: "rename X", with: "rename Y"))]")
            }
            try await fixture.run(coordinator, requestJSON: updated)
            #expect(fixture.resolutionPosts == 1)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.first?.state == .needsVerification)
            // A real edit of the target thread permits a newly assessed attempt.
            let editedPraise = praise.replacingOccurrences(of: "mapping looks good.", with: "mapping and scope look good.")
            try fixture.write("discussions.json", "[\(editedPraise),\(Fixture.condition)]")
            try fixture.write("resolved.json", editedPraise.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            fixture.gitlab.remove("deny-resolve")
            try await fixture.run(coordinator, requestJSON: updated)
            #expect(fixture.resolutionPosts == 2 && fixture.resolved)
        }
    }

    @Test func validatedResolutionDoesNotBecomeAFailureWhenItsAdditionalReadFails() async throws {
        try await withFixture { fixture in
            let praise = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The scoped mapping looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(praise)]")
            try fixture.write("resolved.json", praise.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try fixture.write("fail-discussions-after-resolution", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No remaining expectation", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(fixture.resolutionPosts == 1 && fixture.resolved)
            #expect(status.phase == .complete && !status.needsAttention)
            #expect(status.findings.isEmpty)
        }
    }

    @Test func editedThreadAfterAwardLookupCannotReceiveReaction() async throws {
        try await withFixture { fixture in
            let thread = #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Looks good.","resolvable":true,"resolved":false}]}]"#
            try fixture.write("discussions.json", thread)
            try fixture.write("changed-discussions.json", thread.replacingOccurrences(of: "Looks good.", with: "Please also add coverage."))
            try fixture.write("change-after-award-read", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No request or condition", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == 0 && !fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
        }
    }

    @Test(arguments: ["draftMR", "pendingDraft", "disabled", "head", "account", "comment"])
    func informationalAcknowledgementPreservesPolicyAndFreshEvidenceGuards(_ scenario: String) async throws {
        try await withFixture { fixture in
            let thread = #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Looks good.","resolvable":true,"resolved":false}]}]"#
            try fixture.write("discussions.json", thread)
            let request = scenario == "draftMR" ? Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true") : Fixture.request
            try fixture.write("request.json", request)
            let drafts = scenario == "pendingDraft" ? 1 : 0
            if drafts > 0 { try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"note":"Keep my draft"}]"#) }
            if scenario == "disabled" {
                fixture.settings.automation.autoResolveAcceptedFeedback = false
                fixture.settings.automation.authorFeedback.isEnabled = true
            }
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "A positive acknowledgement", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]), duringVerification: {
                do {
                    switch scenario {
                    case "head": try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
                    case "account": try fixture.write("user.json", #"{"id":99,"username":"me"}"#)
                    case "comment": try fixture.write("discussions.json", thread.replacingOccurrences(of: "Looks good.", with: "Please add a test first."))
                    default: break
                    }
                } catch { Issue.record(error) }
            })
            try await fixture.run(coordinator, requestJSON: request, drafts: drafts)
            #expect(fixture.reactionPosts == 0)
            #expect(!fixture.resolved)
        }
    }

    @Test func informationalThreadEditedAfterReactionCannotBeResolved() async throws {
        try await withFixture { fixture in
            let thread = #"{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Looks good.","resolvable":true,"resolved":false}]}"#
            try fixture.write("discussions.json", "[\(thread)]")
            try fixture.write("changed-discussions.json", "[\(thread.replacingOccurrences(of: "Looks good.", with: "Please also add coverage."))]")
            try fixture.write("change-after-award", "yes")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No request or condition", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary)
            ]))
            try await fixture.run(coordinator)
            #expect(fixture.reactionPosts == 1)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.blocking, .uncertain])
    func informationalRootDoesNotHideAnActionableChild(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Positive acknowledgement","resolvable":true,"resolved":false},{"id":20,"author":{"id":8,"username":"bob"},"system":false,"body":"One correction still needs work","resolvable":false}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "No action requested", informationalAcknowledgementSafe: true, informationalPurpose: .reviewSummary),
                .init(noteID: 20, state: state, reason: "Remaining expectation needs work or verification")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.replyNoteIDs.isEmpty)
            #expect(status.followUpNoteIDs == [20] && requested == [20])
            #expect(status.needsAttention)
            #expect(status.findings.first?.state == (state == .blocking ? .needsChanges : .needsVerification))
            #expect(status.findings.allSatisfy { !$0.canResolve })
            #expect(!fixture.resolved)
            #expect(fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: ["missingReply", "publishedReply", "resolved", "informational"])
    func optedInDraftAssessmentKeepsAnOwedReplyVisibleAndDispatchesOnlyMissingWork(scenario: String) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            fixture.settings.automation.scope.setManualChoice(.forceOn,
                for: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            if scenario != "publishedReply" {
                let thread = #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Current feedback","resolvable":true,"resolved":\#(scenario == "resolved")}]}]"#
                try fixture.write("discussions.json", thread)
            }
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: scenario == "informational" ? .informational : .addressed,
                    reason: "Current code and discussion assessed")
            ]))
            var requestedWork: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requestedWork = notes }
            try await fixture.run(coordinator, requestJSON: draft)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(draft.utf8))
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let missingReply = scenario == "missingReply"
            #expect(status.phase == .complete)
            #expect(status.replyNoteIDs == (missingReply ? [10] : []))
            var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
                url: request.webURL, needsDiscussion: true, mergeRequest: request, isAuthored: true,
                feedback: [try #require(fixture.discussions().first?.notes.first)])
            item.observedDiscussionFingerprint = ReviewVerdict.fingerprint(try fixture.discussions())
            item.authorFeedbackStatus = status
            let visible = item.presentingVerifiedAuthorFeedback()
            #expect(visible.feedback.compactMap(\.id) == (missingReply ? [10] : []))
            #expect(visible.needsDiscussion == missingReply)
            #expect(status.needsAttention == missingReply)
            #expect(!fixture.resolved && requestedWork == (missingReply ? [10] : []))
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking])
    func pendingReplyInTheSameThreadPreventsDuplicateDispatchAndResolution(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"A private reply in the assessed thread"}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: state, reason: "Current scoped feedback assessed")
            ]))
            var requestedWork = false
            var notified = false
            coordinator.onNeedsWork = { _, _, _, _ in requestedWork = true }
            coordinator.onRemoteChange = { notified = true }
            try await fixture.run(coordinator, drafts: 1)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let fingerprint = try #require(ReviewVerdict.fingerprint(fixture.discussions()))
            #expect(fixture.verified)
            #expect(coordinator.assessment(for: request, fingerprint: fingerprint)?.notes.first?.state == state)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .waitingPublication)
            #expect(coordinator.status(projectID: 1, iid: 2)?.pendingDraftCount == 1)
            #expect(notified)
            #expect(!fixture.resolved && !requestedWork)
        }
    }

    @Test(arguments: [false, true])
    func unrelatedDraftsDoNotBlockOldFollowUpReconciliationButPrivateRepliesNeverCompleteIt(missingPublishedReply: Bool) async throws {
        try await withFixture { fixture in
            try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"note":"Unrelated private reply"}]"#)
            if missingPublishedReply {
                let thread = #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix A","resolvable":true,"resolved":false}]}]"#
                try fixture.write("discussions.json", thread)
            }
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            fixture.settings.mrActionIntents.append(.init(id: UUID(),
                target: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2), kind: .followUp,
                state: .failed, todoIDs: [], noteIDs: [10], sourceEvents: [], request: request,
                headSHA: String(repeating: "b", count: 40), error: "Earlier attempt", updatedAt: Date()))
            let coordinator = fixture.coordinator()
            let router = MergeRequestTodoRouter(settings: fixture.settings, glab: fixture.glab, canAutomate: { false })
            router.followUpAssessment = { request, discussions in
                guard let fingerprint = ReviewVerdict.fingerprint(discussions) else { return nil }
                return coordinator.assessment(for: request, fingerprint: fingerprint)
            }
            try await fixture.run(coordinator, drafts: 1)
            await router.refreshCompletionEvidence(host: Fixture.host, username: "me")
            #expect(fixture.settings.mrActionIntents[0].state == (missingPublishedReply ? .failed : .completed))
            #expect(fixture.settings.mrActionIntents[0].jobID == nil)
            #expect(!fixture.resolved && fixture.settings.assistantHandoffs.isEmpty)
        }
    }

    @Test(arguments: [ReReviewAssessment.Note.State.addressed, .blocking])
    func optedInDraftWithAPendingReplyIsAssessedReadOnlyForReconciliation(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.scope.setManualChoice(.forceOn,
                for: .init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"Private reply awaiting publication"}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: state, reason: "Current evidence assessed")
            ]))
            var requestedWork = false
            coordinator.onNeedsWork = { _, _, _, _ in requestedWork = true }

            try await fixture.run(coordinator, requestJSON: draft, drafts: 1)

            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(draft.utf8))
            let fingerprint = try #require(ReviewVerdict.fingerprint(fixture.discussions()))
            #expect(fixture.verified)
            #expect(coordinator.assessment(for: request, fingerprint: fingerprint)?.notes.first?.state == state)
            #expect(!fixture.resolved)
            #expect(!requestedWork)
        }
    }

    @Test func checkingIsBoundToTheCurrentHeadDiscussionAndSemanticContext() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Fixture.request.utf8))
            let fingerprint = try #require(ReviewVerdict.fingerprint(fixture.discussions()))
            try fixture.start(coordinator)
            #expect(coordinator.isChecking(for: request, fingerprint: fingerprint))
            #expect(!coordinator.isChecking(for: request, fingerprint: "changed discussions"))
            for changed in [Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)),
                            Fixture.request.replacingOccurrences(of: "Example MR", with: "Changed requirements")] {
                let edited = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(changed.utf8))
                #expect(!coordinator.isChecking(for: edited, fingerprint: fingerprint))
            }
            try await fixture.run(coordinator)
            #expect(!coordinator.isChecking(for: request, fingerprint: fingerprint))
        }
    }

    @Test func completedFeedbackVerificationNotifiesTheMRCompletionConsumer() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let monitor = MergeRequestAttentionMonitor(glab: fixture.glab, settings: fixture.settings,
                reportDirectory: nil, canAutomate: { _ in true }, verifyReReview: { _, _, _ in
                    .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current code and existing reply verified.")])
                })
            var checked = 0
            monitor.onAuthorFeedbackChecked = { checked += 1 }
            monitor.refresh(host: Fixture.host, username: "me", todos: [])
            let coordinator = try #require(monitor.authorFeedbackCoordinator)
            try await fixture.run(coordinator)
            #expect(checked == 1)
        }
    }

    @Test func passesCurrentMergeRequestDescriptionToSemanticVerification() async throws {
        try await withFixture { fixture in
            let request = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: "\"title\":\"Example MR\",\"description\":\"Documented fallback and verification steps\"")
            try fixture.write("request.json", request)
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator, requestJSON: request)
            #expect(fixture.inputs.first?.description == "Documented fallback and verification steps")
            #expect(fixture.inputs.first?.target?.host == Fixture.host)
            #expect(fixture.inputs.first?.target?.projectID == 1)
            #expect(fixture.inputs.first?.target?.iid == 2)
            #expect(fixture.inputs.first?.target?.expectedUsername == "me")
            let snapshot = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
            #expect(fixture.inputs.first?.target?.url == snapshot.webURL)
            #expect(fixture.inputs.first?.semanticContextFingerprint == snapshot.semanticContextFingerprint)
        }
    }

    @Test(arguments: ["title", "description"])
    func sameHeadContextEditInvalidatesCachedSemanticAssessment(_ field: String) async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            #expect(fixture.inputs.count == 1)
            let edited = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: field == "title" ? "\"title\":\"Updated requirements\""
                    : "\"title\":\"Example MR\",\"description\":\"Updated requirements\"")
            try fixture.write("request.json", edited)
            try await fixture.run(coordinator, requestJSON: edited)
            #expect(fixture.inputs.count == 2)
        }
    }

    @Test(arguments: ["title", "description"])
    func contextChangedDuringVerificationCannotAuthorizeAcceptedThreadResolution(_ field: String) async throws {
        try await withFixture { fixture in
            let edited = Fixture.request.replacingOccurrences(of: "\"title\":\"Example MR\"",
                with: field == "title" ? "\"title\":\"New acceptance criteria\""
                    : "\"title\":\"Example MR\",\"description\":\"New acceptance criteria\"")
            let coordinator = fixture.coordinator(duringVerification: {
                do { try fixture.write("request.json", edited) } catch { Issue.record(error) }
            })
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
        }
    }

    @Test func resolvesOnlyTheVerifiedThreadAfterFreshChecks() async throws {
        try await withFixture { fixture in
            let coordinator = fixture.coordinator()
            var refreshed = false
            coordinator.onRemoteChange = { refreshed = true }
            try await fixture.run(coordinator)
            #expect(fixture.resolved)
            #expect(refreshed)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.isEmpty == true)
            #expect(coordinator.status(projectID: 1, iid: 2)?.acceptedReviewerIDs.contains(7) == true)
        }
    }

    @Test func anotherReviewersApprovalDoesNotCloseTheConcern() async throws {
        try await withFixture { fixture in
            try fixture.write("approvals.json", #"{"approved_by":[{"user":{"id":8}}]}"#)
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.findings.first?.state == .waitingAcceptance)
        }
    }

    @Test func disablingAutomaticResolutionStillVerifiesAndPreparesRemainingWork() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "Fix A remains necessary")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested == [10])
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == true)
        }
    }

    @Test func disablingResolutionDoesNotTurnAcceptedFeedbackIntoHumanAttention() async throws {
        try await withFixture { fixture in
            fixture.settings.automation.autoResolveAcceptedFeedback = false
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator()
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested.isEmpty)
            #expect(!status.needsAttention)
            #expect(!status.findings.contains { [.needsChanges, .needsVerification].contains($0.state) })
        }
    }

    @Test func resolvedThreadStillTriggersWorkWhenTheVerifierFindsAnUnfulfilledCondition() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", "[\(Fixture.thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))]")
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .blocking, reason: "The concern was closed but fix A is still absent")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(!fixture.resolved)
            #expect(requested == [10])
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == true)
        }
    }

    @Test func generalOnlyInformationalReviewCompletesAssessmentWithoutRequestingChanges() async throws {
        try await withFixture { fixture in
            let summary = #"[{"id":"summary","notes":[{"id":20,"author":{"id":7,"username":"alice"},"system":false,"body":"Review complete; no changes needed.","resolvable":false}]}]"#
            try fixture.write("discussions.json", summary)
            fixture.settings.automation.authorFeedback.isEnabled = true
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 20, state: .informational, reason: "A review summary without a requested change")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _, _ in requested = notes }
            try await fixture.run(coordinator)
            #expect(fixture.verified)
            #expect(requested.isEmpty)
            #expect(fixture.reactionPosts == 0)
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
            #expect(coordinator.status(projectID: 1, iid: 2)?.needsAttention == false)
        }
    }

    @Test func advanceApprovalKeepsGeneralConditionsOpenAndRequestsFollowUp() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", "[\(Fixture.thread),\(Fixture.condition)]")
            let assessment = ReReviewAssessment(notes: [
                .init(noteID: 10, state: .addressed, reason: "Original fix verified"),
                .init(noteID: 20, state: .blocking, reason: "The requested rename is still missing")
            ])
            let coordinator = fixture.coordinator(assessment: assessment)
            var requested: Set<Int> = []
            let expectedFingerprint = ReviewVerdict.fingerprint(try fixture.discussions())
            coordinator.onNeedsWork = { _, notes, fingerprint, _ in
                #expect(fingerprint == expectedFingerprint)
                requested = notes
            }
            try await fixture.run(coordinator)
            #expect(!fixture.resolved)
            #expect(requested == [20])
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.needsAttention)
            #expect(status.findings.map(\.state) == [.needsChanges, .needsChanges])
        }
    }

    @Test func editedConcernInvalidatesEarlierAcceptanceEvenWithTheSameBody() async throws {
        try await withFixture { fixture in
            let acknowledgement = """
                {"id":"accepted","notes":[{"id":30,"author":{"id":7,"username":"alice"},
                 "system":false,"body":"All the requested fixes look correct","resolvable":false,
                 "created_at":"2026-01-01T12:00:00Z"}]}
                """
            let initialJSON = "[\(Fixture.thread),\(acknowledgement)]"
            let initial = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(initialJSON.utf8))
            try fixture.write("discussions.json", initialJSON.replacingOccurrences(
                of: "\"created_at\":\"2026-01-01T10:00:00Z\"",
                with: "\"created_at\":\"2026-01-01T10:00:00Z\",\"updated_at\":\"2026-01-01T13:00:00Z\""))
            try fixture.write("approvals.json", #"{"approved_by":[]}"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .addressed, reason: "Fix A verified", acceptanceNoteID: 30),
                .init(noteID: 30, state: .informational, reason: "Reviewer accepts fix A")
            ]))
            try await fixture.run(coordinator, initialDiscussions: initial)
            #expect(!fixture.resolved)
        }
    }

    @Test(arguments: ["head", "comment", "draft", "account", "approval"])
    func changedLiveEvidencePreventsResolution(_ changed: String) async throws {
        try await withFixture { fixture in
            switch changed {
            case "head": try fixture.write("request.json", Fixture.request.replacingOccurrences(of: Fixture.sha, with: String(repeating: "b", count: 40)))
            case "comment": try fixture.write("discussions.json", "[\(Fixture.thread.replacingOccurrences(of: "Fix A", with: "Also fix B"))]")
            case "draft": try fixture.write("drafts.json", #"[{"id":30,"author_id":3,"note":"Unpublished reply"}]"#)
            case "account": try fixture.write("user.json", #"{"id":99,"username":"me"}"#)
            default: try fixture.write("withdraw-approval", "yes")
            }
            let coordinator = fixture.coordinator()
            try await fixture.run(coordinator, initialDiscussions: [try JSONDecoder().decode(GitLabMergeRequestDiscussion.self, from: Data(Fixture.thread.utf8))])
            #expect(!fixture.resolved)
        }
    }

    @Test(arguments: ["setting", "scope", "package", "ignored"])
    func disabledPolicyDuringVerificationPreventsResolution(_ changed: String) async throws {
        try await withFixture { fixture in
            let coordinator = fixture.coordinator(duringVerification: {
                switch changed {
                case "setting": fixture.settings.automation.autoResolveAcceptedFeedback = false
                case "scope": fixture.settings.automation.scope.mode = .selected
                case "package": fixture.settings.automation.packageDecision = .disabled
                default: fixture.settings.ignoredMergeRequests.insert(.init(host: Fixture.host, username: "me", projectID: 1, iid: 2))
                }
            })
            // Disabling policy cancels work without publishing a completed assessment.
            try fixture.start(coordinator)
            try await fixture.waitForVerification()
            try await Task.sleep(for: .milliseconds(100))
            #expect(!fixture.resolved)
            #expect(coordinator.status(projectID: 1, iid: 2)?.phase != .complete)
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
             "target_branch":"main","labels":[]}
            """
        static let thread = """
            {"id":"thread-a","notes":[
              {"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"Fix A",
               "resolvable":true,"resolved":false,"created_at":"2026-01-01T10:00:00Z"},
              {"id":11,"author":{"id":3,"username":"me"},"system":false,"body":"Fixed A",
               "resolvable":false,"created_at":"2026-01-01T11:00:00Z"}]}
            """
        static let condition = """
            {"id":"general-condition","notes":[{"id":20,"author":{"id":7,"username":"alice"},
             "system":false,"body":"Approved, but please also rename X","resolvable":false,
             "created_at":"2026-01-01T12:00:00Z"}]}
            """
        let directory: URL
        let defaults: UserDefaults
        let suite = "AuthorFeedbackCoordinatorTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        let gitlab = InMemoryGitLab()
        var verified = false
        var inputs: [ReReviewVerifier.Input] = []
        var retryDelays: [Duration] = []
        var reactionPosts: Int { count("reaction-posts") }
        var awardReads: Int { count("award-reads") }
        var userReads: Int { count("user-reads") }
        var resolutionPosts: Int { count("resolution-posts") }
        private func count(_ name: String) -> Int {
            gitlab.text(name).split(separator: "\n").count
        }
        var resolved: Bool { gitlab.has("resolved") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.packageDecision = .enabled
            settings.automation.autoResolveAcceptedFeedback = true
            glab = gitlab.service(host: Self.host, username: "me")
            try write("request.json", Self.request)
            try write("user.json", #"{"id":3,"username":"me"}"#)
            try write("approvals.json", #"{"approved_by":[{"user":{"id":7,"username":"alice"}}]}"#)
            try write("discussions.json", "[\(Self.thread)]")
            try write("resolved.json", Self.thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try write("drafts.json", "[]")
            try write("awards.json", "[]")
            try write("reviewer.json", #"{"id":7,"username":"alice","bot":false}"#)
            gitlab.handler = { [gitlab] request in
                let endpoint = request.endpoint
                #expect(Array(request.arguments.prefix(4)) == ["api", endpoint, "--hostname", Self.host])
                switch endpoint {
                case let path where path.hasPrefix("/merge_requests?scope=created_by_me"):
                    // The completion callback test does not supply a catalog listing.
                    return InMemoryGitLab.output(code: 100)
                case let path where path.hasPrefix("/merge_requests?scope=all"):
                    return InMemoryGitLab.output(code: 100)
                case let path where path.contains("/reviewers?"): return InMemoryGitLab.output(code: 100)
                case "/users/7":
                    if gitlab.has("fail-reviewer") { return InMemoryGitLab.output(error: "503 unavailable", code: 1) }
                    return try gitlab.response("reviewer.json")
                case "/user":
                    gitlab.append("user-reads", "user\n")
                    return try gitlab.response("user.json")
                case "/projects/1/merge_requests/2":
                    if gitlab.has("fail-request-once") {
                        gitlab.remove("fail-request-once")
                        return InMemoryGitLab.output(error: "503 temporarily unavailable", code: 1)
                    }
                    return try gitlab.response("request.json")
                case let path where path.contains("/award_emoji"):
                    let noteID = path.components(separatedBy: "/award_emoji")[0].split(separator: "/").last!
                    let name = "awards-\(noteID).json"
                    if request.method == "POST" {
                        gitlab.append("reaction-posts", "post\n")
                        if gitlab.has("fail-award") { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                        gitlab.write(name, #"[{"id":40,"name":"thumbsup","user":{"id":3,"username":"me"}}]"#)
                        if gitlab.has("change-after-award") { try gitlab.copy("changed-discussions.json", "discussions.json") }
                        return InMemoryGitLab.output(#"{"id":40,"name":"thumbsup","user":{"id":3,"username":"me"}}"#)
                    }
                    gitlab.append("award-reads", "get\n")
                    if gitlab.has("fail-award-read") { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                    let result = try gitlab.response(gitlab.has(name) ? name : "awards.json")
                    if gitlab.has("change-after-award-read") { try gitlab.copy("changed-discussions.json", "discussions.json") }
                    return result
                case let path where path.hasSuffix("/raw_diffs"):
                    return InMemoryGitLab.output("diff --git a/A b/A")
                case let path where path.hasSuffix("/approvals"):
                    let withdrawn = gitlab.has("approvals-read") && gitlab.has("withdraw-approval")
                    gitlab.write("approvals-read")
                    return withdrawn ? InMemoryGitLab.output(#"{"approved_by":[]}"#) : try gitlab.response("approvals.json")
                case let path where path.contains("/draft_notes"):
                    return try gitlab.response("drafts.json")
                case let path where path.contains("/discussions?"):
                    if gitlab.has("resolved") && gitlab.has("fail-discussions-after-resolution") {
                        return InMemoryGitLab.output(error: "503 unavailable", code: 1)
                    }
                    let json = gitlab.text("discussions.json")
                    return InMemoryGitLab.output(gitlab.has("resolved") ? json.replacingOccurrences(of: #""resolved":false"#, with: #""resolved":true"#) : json)
                case let path where path.hasSuffix("/discussions/thread-a"):
                    #expect(request.arguments == ["api", endpoint, "--hostname", Self.host, "--method", "PUT", "--field", "resolved=true"])
                    gitlab.append("resolution-posts", "put\n")
                    if gitlab.has("deny-resolve") { return InMemoryGitLab.output(error: "403 Forbidden", code: 1) }
                    gitlab.write("resolved")
                    if gitlab.has("lose-resolve-response") { return InMemoryGitLab.output(error: "response lost", code: 1) }
                    return try gitlab.response("resolved.json")
                default: return try gitlab.unexpected(request)
                }
            }
        }

        func coordinator(assessment: ReReviewAssessment? = nil, duringVerification: (() -> Void)? = nil) -> AuthorFeedbackCoordinator {
            AuthorFeedbackCoordinator(settings: settings, glab: glab, canAutomate: { _ in true }, verify: { [self] input, _, _ in
                inputs.append(input)
                duringVerification?()
                verified = true
                return assessment ?? .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current diff fixes A")])
            }, retryWait: { [self] in retryDelays.append($0) })
        }

        func start(_ coordinator: AuthorFeedbackCoordinator, initialDiscussions: [GitLabMergeRequestDiscussion]? = nil,
                   requestJSON: String = Fixture.request, drafts: Int = 0) throws {
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
            coordinator.refresh(request: request, discussions: try initialDiscussions ?? discussions(), drafts: drafts,
                                host: Self.host, user: .init(id: 3, username: "me"))
        }

        func run(_ coordinator: AuthorFeedbackCoordinator, initialDiscussions: [GitLabMergeRequestDiscussion]? = nil,
                 requestJSON: String = Fixture.request, drafts: Int = 0) async throws {
            try start(coordinator, initialDiscussions: initialDiscussions, requestJSON: requestJSON, drafts: drafts)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON.utf8))
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                if !settings.automation.scope.permits(request, host: Self.host, username: "me") { return }
                if let phase = coordinator.status(projectID: 1, iid: 2)?.phase, phase == .complete || phase == .failed || phase == .waitingPublication { return }
                if verified && coordinator.status(projectID: 1, iid: 2) == nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Author feedback coordinator did not finish")
        }

        func waitForVerification() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !verified, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(verified)
        }

        func discussions() throws -> [GitLabMergeRequestDiscussion] {
            var json = gitlab.text("discussions.json")
            if resolved { json = json.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true") }
            return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(json.utf8))
        }

        func write(_ name: String, _ content: String) throws { gitlab.write(name, content) }
        func cleanUp() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
