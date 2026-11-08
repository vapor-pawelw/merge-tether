import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AuthorFeedbackCoordinatorTests {
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }

            // when
            try await fixture.run(coordinator, drafts: 1)

            // then
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(requested == [20])
            #expect(status.followUpNoteIDs == [20])
            #expect(status.phase == .waitingPublication && status.pendingDraftCount == 1)
            #expect(!fixture.resolved)
            #expect(try Data(contentsOf: fixture.directory.appending(path: "drafts.json"))
                == Data(#"[{"id":30,"author_id":3,"discussion_id":"thread-a","note":"An uncertain earlier reply"}]"#.utf8))
        }
    }

    @Test(arguments: [7, 8], ["readyMissing", "readyPublished", "draftMissing", "draftPublished", "pendingDraftMissing"])
    func addressedChildKeepsThreadReplyIndicatorAndDispatchesItsExactNote(childAuthorID: Int, scenario: String) async throws {
        try await withFixture { fixture in
            let draft = scenario.hasPrefix("draft")
            let published = scenario.hasSuffix("Published")
            let pendingDrafts = scenario == "pendingDraftMissing" ? 1 : 0
            let readOnly = draft || pendingDrafts > 0
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator, requestJSON: requestJSON, drafts: pendingDrafts)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.replyNoteIDs == (published ? [] : [10]))
            let expectedWork: Set<Int> = !readOnly && !published ? [20] : []
            #expect(status.followUpNoteIDs == expectedWork && requested == expectedWork)
            #expect(status.phase == (pendingDrafts > 0 ? .waitingPublication : .complete))
            #expect(status.needsAttention == !published)
            if !readOnly { #expect(status.findings.first?.state == .waitingAcceptance) }
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            let requiresReply = state == .addressed
            #expect(status.phase == .complete)
            #expect(status.replyNoteIDs == (requiresReply ? [10] : []))
            #expect(status.followUpNoteIDs == (requiresReply ? [10] : []))
            #expect(requested == (requiresReply ? [10] : []))
            #expect(status.findings.first?.state == .waitingAcceptance)
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
                .init(noteID: 10, state: .informational, reason: "A positive acknowledgement with no request or condition", informationalAcknowledgementSafe: true)
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
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

    @Test func resolvedInformationalHistoryReceivesNoNewReactionOrLiveAcknowledgementReads() async throws {
        try await withFixture { fixture in
            try fixture.write("discussions.json", #"[{"id":"thread-a","notes":[{"id":10,"author":{"id":7,"username":"alice"},"system":false,"body":"The mapping looks good.","resolvable":true,"resolved":true}]}]"#)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: .informational, reason: "A closed historical acknowledgement", informationalAcknowledgementSafe: true)
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
                .init(noteID: 20, state: .informational, reason: "A pure review acknowledgement", informationalAcknowledgementSafe: true)
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
                .init(noteID: $0, state: .informational, reason: "A pure positive review summary", informationalAcknowledgementSafe: true)
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
                .init(noteID: 20, state: .informational, reason: "A pure review acknowledgement", informationalAcknowledgementSafe: true)
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
                .init(noteID: 10, state: .informational, reason: "No remaining expectation in this thread", informationalAcknowledgementSafe: true),
                .init(noteID: 20, state: .blocking, reason: "The independent rename still needs work")
            ]))
            var requested: Set<Int> = []
            var dispatches = 0
            coordinator.onNeedsWork = { _, notes, _ in requested.formUnion(notes); dispatches += 1 }
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
                .init(noteID: 10, state: .informational, reason: "No remaining expectation", informationalAcknowledgementSafe: true)
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
                try FileManager.default.removeItem(at: fixture.directory.appending(path: "deny-resolve"))
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
                .init(noteID: 10, state: .informational, reason: "No remaining expectation in this thread", informationalAcknowledgementSafe: true),
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
            try FileManager.default.removeItem(at: fixture.directory.appending(path: "deny-resolve"))
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
                .init(noteID: 10, state: .informational, reason: "No remaining expectation", informationalAcknowledgementSafe: true)
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
                .init(noteID: 10, state: .informational, reason: "No request or condition", informationalAcknowledgementSafe: true)
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
                .init(noteID: 10, state: .informational, reason: "A positive acknowledgement", informationalAcknowledgementSafe: true)
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
                .init(noteID: 10, state: .informational, reason: "No request or condition", informationalAcknowledgementSafe: true)
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
                .init(noteID: 10, state: .informational, reason: "No action requested", informationalAcknowledgementSafe: true),
                .init(noteID: 20, state: state, reason: "Remaining expectation needs work or verification")
            ]))
            var requested: Set<Int> = []
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
            try await fixture.run(coordinator)
            let status = try #require(coordinator.status(projectID: 1, iid: 2))
            #expect(status.replyNoteIDs.isEmpty)
            #expect(status.followUpNoteIDs == [20] && requested == [20])
            #expect(status.needsAttention)
            #expect(status.findings.first?.state == .needsChanges)
            #expect(status.findings.allSatisfy { !$0.canResolve })
            #expect(!fixture.resolved)
            #expect(fixture.reactionPosts == 0)
        }
    }

    @Test(arguments: ["missingReply", "publishedReply", "resolved", "informational"])
    func draftAssessmentKeepsAnOwedPublishedReplyVisibleWithoutDispatchingWork(scenario: String) async throws {
        try await withFixture { fixture in
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
            var requestedWork = false
            coordinator.onNeedsWork = { _, _, _ in requestedWork = true }
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
            #expect(!fixture.resolved && !requestedWork)
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
            coordinator.onNeedsWork = { _, _, _ in requestedWork = true }
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
    func draftFeedbackIsAssessedReadOnlyForReconciliation(state: ReReviewAssessment.Note.State) async throws {
        try await withFixture { fixture in
            let draft = Fixture.request.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            try fixture.write("request.json", draft)
            let coordinator = fixture.coordinator(assessment: .init(notes: [
                .init(noteID: 10, state: state, reason: "Current evidence assessed")
            ]))
            var requestedWork = false
            coordinator.onNeedsWork = { _, _, _ in requestedWork = true }

            try await fixture.run(coordinator, requestJSON: draft)

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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
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
            coordinator.onNeedsWork = { _, notes, _ in requested = notes }
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
            coordinator.onNeedsWork = { _, notes, fingerprint in
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
        var verified = false
        var inputs: [ReReviewVerifier.Input] = []
        var reactionPosts: Int { count("reaction-posts") }
        var awardReads: Int { count("award-reads") }
        var userReads: Int { count("user-reads") }
        var resolutionPosts: Int { count("resolution-posts") }
        private func count(_ name: String) -> Int {
            (try? String(contentsOf: directory.appending(path: name), encoding: .utf8).split(separator: "\n").count) ?? 0
        }
        var resolved: Bool { FileManager.default.fileExists(atPath: directory.appending(path: "resolved").path) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.packageDecision = .enabled
            settings.automation.autoResolveAcceptedFeedback = true
            glab = GlabService()
            glab.resolvedHost = Self.host
            glab.currentUsername = "me"
            glab.glabPath = directory.appending(path: "glab")
            try write("request.json", Self.request)
            try write("user.json", #"{"id":3,"username":"me"}"#)
            try write("approvals.json", #"{"approved_by":[{"user":{"id":7,"username":"alice"}}]}"#)
            try write("discussions.json", "[\(Self.thread)]")
            try write("resolved.json", Self.thread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
            try write("drafts.json", "[]")
            try write("awards.json", "[]")
            try write("glab", """
                #!/bin/sh
                set -eu
                cd "$(dirname "$0")"
                test "$1" = api
                test "$3" = --hostname
                test "$4" = \(Self.host)
                case "$2" in
                  /user) printf 'user\\n' >> user-reads; cat user.json ;;
                  /projects/1/merge_requests/2)
                    if [ -e fail-request-once ]; then rm fail-request-once; printf '503 temporarily unavailable' >&2; exit 1; fi
                    cat request.json ;;
                  */award_emoji*)
                    note_path="${2%/award_emoji*}"
                    note_id="${note_path##*/}"
                    award_file="awards-$note_id.json"
                    if [ "${5-}" = --method ]; then
                      test "$5" = --method
                      test "$6" = POST
                      printf 'post\\n' >> reaction-posts
                      if [ -e fail-award ]; then printf '%s' '403 Forbidden' >&2; exit 1; fi
                      printf '%s' '{"id":40,"name":"thumbsup","user":{"id":3,"username":"me"}}'
                      printf '%s' '[{"id":40,"name":"thumbsup","user":{"id":3,"username":"me"}}]' > "$award_file"
                      if [ -e change-after-award ]; then cp changed-discussions.json discussions.json; fi
                    else
                      printf 'get\\n' >> award-reads
                      if [ -e fail-award-read ]; then printf '%s' '403 Forbidden' >&2; exit 1; fi
                      if [ -e "$award_file" ]; then cat "$award_file"; else cat awards.json; fi
                      if [ -e change-after-award-read ]; then cp changed-discussions.json discussions.json; fi
                    fi ;;
                  */raw_diffs) printf '%s' 'diff --git a/A b/A' ;;
                  */approvals)
                    if [ -e approvals-read ] && [ -e withdraw-approval ]; then
                      printf '%s' '{"approved_by":[]}'
                    else cat approvals.json; fi
                    touch approvals-read ;;
                  */draft_notes*) cat drafts.json ;;
                  */discussions\\?*)
                    if [ -e resolved ] && [ -e fail-discussions-after-resolution ]; then printf '%s' '503 unavailable' >&2; exit 1; fi
                    if [ -e resolved ]; then sed 's/"resolved":false/"resolved":true/g' discussions.json;
                    else cat discussions.json; fi ;;
                  */discussions/thread-a)
                    test "$*" = 'api /projects/1/merge_requests/2/discussions/thread-a --hostname \(Self.host) --method PUT --field resolved=true'
                    printf 'put\\n' >> resolution-posts
                    if [ -e deny-resolve ]; then printf '%s' '403 Forbidden' >&2; exit 1; fi
                    touch resolved
                    if [ -e lose-resolve-response ]; then printf '%s' 'response lost' >&2; exit 1; fi
                    cat resolved.json ;;
                  *) printf '%s' "Unexpected glab command: $*" >&2; exit 100 ;;
                esac
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "glab").path)
        }

        func coordinator(assessment: ReReviewAssessment? = nil, duringVerification: (() -> Void)? = nil) -> AuthorFeedbackCoordinator {
            AuthorFeedbackCoordinator(settings: settings, glab: glab, canAutomate: { _ in true }, verify: { [self] input, _, _ in
                inputs.append(input)
                duringVerification?()
                verified = true
                return assessment ?? .init(notes: [.init(noteID: 10, state: .addressed, reason: "Current diff fixes A")])
            })
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
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
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
            var json = try String(contentsOf: directory.appending(path: "discussions.json"), encoding: .utf8)
            if resolved { json = json.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true") }
            return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(json.utf8))
        }

        func write(_ name: String, _ content: String) throws { try Data(content.utf8).write(to: directory.appending(path: name)) }
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
