import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRHumanActionTests {
    @Test(arguments: [MRTodoIntent.Kind.followUp, .pipeline])
    func aPendingFollowUpQuotesItsSelectedCommentsInsteadOfUnrelatedFeedback(_ kind: MRTodoIntent.Kind) throws {
        // given
        let request = try MRDependencyPresentationTests().request(2, project: 1, title: "Example MR")
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL)
        item.mergeRequest = request
        item.observedDiscussionFingerprint = "comments"
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2),
            kind: kind, state: .pending, todoIDs: [], noteIDs: [43, 42], sourceEvents: [], request: request,
            headSHA: request.sha!, updatedAt: Date())
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [intent])
        // when
        let action = try #require(MRHumanAction(row: snapshot, assistantReady: true))
        // then
        #expect(action.kind == .intent)
        #expect(action.feedbackEvidence(for: item) == (kind == .followUp ? .rawNotes([42, 43]) : .none))
        item.observedDiscussionFingerprint = "edited comments"
        #expect(action.feedbackEvidence(for: item) == (kind == .followUp ? .unavailable(42) : .none))
    }

    @Test func aFollowUpWithoutLinkedCommentsExplicitlyReportsMissingEvidence() throws {
        // given
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL)
        item.mergeRequest = request
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2),
            kind: .followUp, state: .pending, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
            headSHA: request.sha!, updatedAt: Date())
        // when
        let action = try #require(MRHumanAction(row: .init(item: item, latestJob: nil, intents: [intent]), assistantReady: true))
        // then
        #expect(action.feedbackEvidence(for: item) == .unavailable(nil))
    }

    @Test(arguments: [false, true])
    func aFailedCheckDoesNotClaimItsSourceIsTheMRWideStatus(_ authorCheck: Bool) throws {
        var item = item()
        item.needsChanges = true
        if authorCheck { item.authorFeedbackStatus = .init(head: "head", fingerprint: "comments", phase: .failed) }
        else { item.reReviewReadiness = .failed }
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.feedbackEvidence(for: item) == .none)
    }
    @Test(arguments: ["checking", "edited", "head", "description", "missingSource"])
    func aPreservedAssessmentNeverQuotesNewRawFeedback(_ change: String) throws {
        var original = item()
        let finding = AuthorFeedbackPolicy.Finding(id: 10, discussionID: "original", reviewerID: 8,
            reviewerUsername: "reviewer", state: .needsChanges, reason: "The timeout is missing", waitingForReviewers: [],
            sourceNoteID: change == "missingSource" ? nil : 42)
        original.authorFeedbackStatus = .init(head: "head", fingerprint: "original comments",
            semanticContextFingerprint: "original description", phase: .complete, findings: [finding])
        let action = try #require(MRHumanAction(row: row(original), assistantReady: true))
        if change != "missingSource" { #expect(action.feedbackEvidence(for: original) == .finding(finding)) }
        var current = original
        current.feedback = [.init(id: 99, author: .init(id: 9, username: "other", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "An unrelated new request")]
        if change == "checking" || change == "missingSource" { current.authorFeedbackStatus?.phase = .checking; current.authorFeedbackStatus?.findings = [] }
        if change == "edited" { current.authorFeedbackStatus = .init(head: "head", fingerprint: "edited comments", semanticContextFingerprint: "original description", phase: .complete, findings: [finding]) }
        if change == "head" { current.authorFeedbackStatus = .init(head: "new head", fingerprint: "original comments", semanticContextFingerprint: "original description", phase: .complete, findings: [finding]) }
        if change == "description" { current.authorFeedbackStatus?.semanticContextFingerprint = "changed description" }
        #expect(action.feedbackEvidence(for: current) == .unavailable(change == "missingSource" ? nil : 42))
    }

    @Test func anOwedReplyWithoutAFindingKeepsItsOwnDiscussionInsteadOfAnotherChecksConcern() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "comments", phase: .complete, replyNoteIDs: [10])
        item.reReviewReadiness = .blocked([.init(noteID: 99, reason: "Another check's concern")])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.explanation == "A reviewer comment still needs a published reply.")
        #expect(action.detail == nil && action.sourceNoteID == 10)
        #expect(action.feedbackEvidence(for: item) == .replyThreads([10]))
        item.authorFeedbackStatus?.replyNoteIDs = [20]
        #expect(action.feedbackEvidence(for: item) == .unavailable(10))
    }

    @Test func aPreservedReReviewConcernDoesNotAdoptAChangedDiscussionSnapshot() throws {
        var item = item()
        let blocker = ReReviewReadiness.Blocker(noteID: 42, reason: "Verify the timeout")
        item.reReviewFingerprint = "original comments"
        item.reReviewReadiness = .uncertain([blocker])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.feedbackEvidence(for: item) == .reReview([blocker]))
        item.reReviewFingerprint = "edited comments"
        #expect(action.feedbackEvidence(for: item) == .unavailable(42))
    }

    @Test func aVerifiedFixNeverHidesTheReplyStillOwedToTheReviewer() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "thread", reviewerID: 8, reviewerUsername: "reviewer",
                state: .waitingAcceptance, reason: "Current diff fixes the retry timeout.", waitingForReviewers: ["reviewer"],
                summary: "The timeout is fixed.", sourceNoteID: 42)], replyNoteIDs: [10])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.explanation == "A reviewer comment still needs a published reply.")
        #expect(action.detail == "Current diff fixes the retry timeout.")
        #expect(action.sourceNoteID == 42 && action.action == .handleFeedback)
    }

    @Test(arguments: [AuthorFeedbackPolicy.State.needsVerification, .waitingAcceptance])
    func aConfirmedCorrectionLeadsBeforeUncertaintyOrAnOwedReply(_ earlierState: AuthorFeedbackPolicy.State) throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "earlier", reviewerID: 8, reviewerUsername: "reviewer",
                state: earlierState, reason: "Earlier feedback", waitingForReviewers: [], sourceNoteID: 10),
                .init(id: 20, discussionID: "remaining", reviewerID: 8, reviewerUsername: "reviewer",
                state: .needsChanges, reason: "The retry still has no timeout.", waitingForReviewers: [], sourceNoteID: 20)],
            replyNoteIDs: earlierState == .waitingAcceptance ? [10] : [])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.explanation == "The retry still has no timeout.")
        #expect(action.sourceNoteID == 20 && action.action == .handleFeedback)
    }

    @Test func aFindingWithNoReasonNeverBorrowsAnotherChecksExplanation() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "unverified", reviewerID: 8, reviewerUsername: "reviewer",
                state: .needsVerification, reason: nil, waitingForReviewers: [], sourceNoteID: 10)])
        item.reReviewReadiness = .blocked([.init(noteID: 99, reason: "A different check's concern")])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.detail == nil && action.sourceNoteID == 10)
        #expect(action.explanation == "Open reviewer comments need review; remaining work has not been verified.")
    }

    @Test func aMissingAssessmentSourceNeverBorrowsAnUnrelatedOpenComment() throws {
        var item = item()
        item.feedback = [.init(id: 99, author: .init(id: 8, username: "reviewer", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "An unrelated open comment")]
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "thread", reviewerID: 8, reviewerUsername: "reviewer",
                state: .needsChanges, reason: "A legacy concern with no exact source", waitingForReviewers: [])])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.sourceNoteID == nil)
        #expect(action.detail == "A legacy concern with no exact source")
    }

    @Test func reReviewUncertaintyRetainsItsExactCommentWithoutClaimingACorrection() throws {
        var item = item()
        item.reReviewReadiness = .uncertain([.init(noteID: 42, reason: "The timeout evidence is incomplete")])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.sourceNoteID == 42 && action.action == .reviewFeedback)
        #expect(String(localized: action.message) == "Open reviewer comments need review; remaining work has not been verified.")
    }

    @Test func rawOpenFeedbackAsksForReviewWithoutClaimingAnotherFixIsRequired() throws {
        var item = item()
        item.feedback = [.init(id: 42, author: .init(id: 8, username: "reviewer", name: nil),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Please cover the timeout")]
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.action == .reviewFeedback)
        #expect(action.explanation == "Open reviewer comments need review; remaining work has not been verified.")
        #expect(action.sourceNoteID == nil)
        #expect(action.feedbackEvidence(for: item) == .rawNotes([42]))
    }

    @Test func aServerChangeRequestDoesNotInventACommentOrVerifiedCorrection() throws {
        var item = item()
        item.needsChanges = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.action == .reviewFeedback)
        #expect(action.explanation == "GitLab reports requested changes. Review the current feedback.")
        #expect(action.sourceNoteID == nil && action.detail == nil)
        #expect(action.feedbackEvidence(for: item) == .gitLabStatus)
    }

    @Test func aLegacyAssessmentShowsItsSpecificReasonAndExactSource() throws {
        var item = item()
        let reason = "The retry still has no timeout."
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "thread", reviewerID: 8, reviewerUsername: "reviewer",
                state: .needsChanges, reason: reason, waitingForReviewers: [], sourceNoteID: 42)])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.action == .handleFeedback && action.explanation == reason)
        #expect(action.sourceNoteID == 42)
    }

    @Test func uncertainEvidenceAndMissingRepliesHaveDifferentExplanations() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: "thread", reviewerID: 8, reviewerUsername: "reviewer",
                state: .needsVerification, reason: nil, waitingForReviewers: [], sourceNoteID: 42)])
        let uncertain = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(uncertain.action == .reviewFeedback)
        #expect(uncertain.explanation == "Open reviewer comments need review; remaining work has not been verified.")
        item.authorFeedbackStatus?.findings[0] = .init(id: 10, discussionID: "thread", reviewerID: 8,
            reviewerUsername: "reviewer", state: .waitingAcceptance, reason: nil, waitingForReviewers: [], sourceNoteID: 42)
        item.authorFeedbackStatus?.replyNoteIDs = [10]
        let reply = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(reply.action == .handleFeedback)
        #expect(reply.explanation == "A reviewer comment still needs a published reply.")
    }

    private func item() -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: 1, iid: 2), title: "Example MR",
              url: URL(string: "https://gitlab.example.test/group/repo/-/merge_requests/2")!)
    }
    private func row(_ item: MergeRequestAttentionMonitor.Item,
                     execution: AssistantJobExecution? = nil, expectedHead: String? = nil,
                     mayPush: Bool = false, executable: Bool = true) -> MergeRequestBoardSnapshot.Row {
        let job = execution.map { execution in
            AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
                title: "Example run", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: mayPush,
                execution: execution, taskPrompt: executable ? "Review this MR" : nil,
                mergeRequestURL: executable ? item.url : nil, expectedHeadSHA: expectedHead)
        }
        return .init(item: item, latestJob: job, intents: [])
    }

    private func stoppedHistoryRow(state: AssistantJobExecution.State, manualDraft: Bool = false,
                                   completedMatchesJob: Bool = true, independentFailure: Bool = false) throws -> MergeRequestBoardSnapshot.Row {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.isAuthored = true
        item.draftCount = manualDraft ? 1 : 0
        item.humanActionRequired = manualDraft ? true : nil
        let base = row(item, execution: .init(state: state, error: "Historical failure"), expectedHead: "head")
        let job = try #require(base.latestJob)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        var intents = [MRTodoIntent(id: UUID(), target: target, kind: .pipeline, state: .completed,
            todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: "head",
            jobID: completedMatchesJob ? job.id : UUID(), updatedAt: Date())]
        if independentFailure {
            intents.append(.init(id: UUID(), target: target, kind: .conflict, state: .failed,
                todoIDs: [], noteIDs: [], sourceEvents: [], request: request, headSHA: "head",
                error: "Conflict verification failed", updatedAt: Date()))
        }
        return .init(item: item, latestJob: job, intents: intents)
    }

    private func partiallyIgnoredStoppedRow(blocker: String = "The old contract suggestion is unresolved") throws -> MergeRequestBoardSnapshot.Row {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.isAuthored = true
        item.observedDiscussionFingerprint = "current comments"
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "current comments",
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: [.init(id: 20, discussionID: "remaining", reviewerID: 8, reviewerUsername: "bob", state: .needsChanges,
                reason: "The independent timeout still needs handling", waitingForReviewers: [],
                summary: "Handle the independent timeout", sourceNoteID: 20)], followUpNoteIDs: [20], ignoredNoteIDs: [10])
        let base = row(item, execution: .init(state: .blocked, finishedAt: Date(), summary: "The run stopped", blocker: blocker),
                       expectedHead: "head")
        var job = try #require(base.latestJob)
        job.workflow = .followUp
        job.feedbackNoteIDs = [10, 20]
        return .init(item: item, latestJob: job, intents: [])
    }

    @Test func stoppedFollowUpPrioritizesConfirmedConcernsWithinItsSelectedThreads() throws {
        let base = try partiallyIgnoredStoppedRow()
        var item = base.item
        item.authorFeedbackStatus?.findings.insert(.init(id: 30, discussionID: "uncertain", reviewerID: 9,
            reviewerUsername: "reviewer", state: .needsVerification, reason: "Check this separately", waitingForReviewers: [],
            summary: "Verify an uncertain concern", sourceNoteID: 30), at: 0)
        item.authorFeedbackStatus?.followUpNoteIDs = [20, 30]
        var job = try #require(base.latestJob)
        job.feedbackNoteIDs = [10, 20, 30]
        let action = try #require(MRHumanAction(row: .init(item: item, latestJob: job, intents: []), assistantReady: true))
        #expect(action.sourceNoteID == 20)
        #expect(action.explanation.contains("Handle the independent timeout"))
    }

    @Test(arguments: ["The old contract suggestion is unresolved", "The test runner could not start", "The source push failed"])
    func freshRemainingFeedbackKeepsTheIndependentStoppedCauseVisible(_ blocker: String) throws {
        let row = try partiallyIgnoredStoppedRow(blocker: blocker)
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.explanation.contains("Handle the independent timeout"))
        #expect(action.explanation.contains(blocker))
        #expect(action.sourceNoteID == 20)
        #expect(action.kind == .blockedRun && action.action == .retryRun)
        #expect(action.detail == blocker)
        #expect(row.latestJob?.execution?.state == .blocked && row.stoppedJobNeedsAttention)
    }

    @Test(arguments: ["head", "comments", "description", "missingSource", "otherSource", "unrelatedIgnore"])
    func staleOrUnrelatedFeedbackCannotReplaceTheStoppedRunExplanation(_ change: String) throws {
        let original = try partiallyIgnoredStoppedRow()
        var item = original.item
        if change == "head" { item.authorFeedbackStatus = .init(head: "old", fingerprint: "current comments", phase: .complete) }
        if change == "comments" { item.observedDiscussionFingerprint = "new comments" }
        if change == "description" { item.authorFeedbackStatus?.semanticContextFingerprint = "old description" }
        if change == "missingSource" { item.authorFeedbackStatus?.findings[0].sourceNoteID = nil }
        if change == "otherSource" { item.authorFeedbackStatus?.findings[0].sourceNoteID = 99 }
        if change == "unrelatedIgnore" { item.authorFeedbackStatus?.ignoredNoteIDs = [99] }
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: original.latestJob, intents: [])
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.explanation == "The old contract suggestion is unresolved")
        #expect(action.sourceNoteID == nil)
    }

    @Test(arguments: ["The test runner could not start", "The source push failed"])
    func ignoringAllFeedbackDoesNotHideAnIndependentToolOrDeliveryStop(_ blocker: String) throws {
        let original = try partiallyIgnoredStoppedRow(blocker: blocker)
        var item = original.item
        item.authorFeedbackStatus?.findings = []
        item.authorFeedbackStatus?.followUpNoteIDs = []
        item.authorFeedbackStatus?.ignoredNoteIDs = [10, 20]
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: original.latestJob, intents: [])
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.explanation == blocker && action.detail == blocker)
        #expect(action.sourceNoteID == nil && action.action == .retryRun)
        #expect(row.stoppedJobNeedsAttention)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked], [false, true])
    func completedHistoricalJobCannotReviveAttentionOrReplaceManualDraftPublication(state: AssistantJobExecution.State,
                                                                                   manualDraft: Bool) throws {
        let row = try stoppedHistoryRow(state: state, manualDraft: manualDraft)
        #expect(!row.hasIndependentStoppedWork)
        #expect(row.needsAttention == manualDraft)
        let action = MRHumanAction(row: row, assistantReady: true)
        if manualDraft {
            #expect(action?.kind == .publication && action?.action == .reviewDrafts)
        } else {
            #expect(action == nil)
        }
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked])
    func unrelatedCompletedIntentDoesNotHideARealStoppedJob(state: AssistantJobExecution.State) throws {
        let row = try stoppedHistoryRow(state: state, manualDraft: true, completedMatchesJob: false)
        #expect(row.hasIndependentStoppedWork && row.needsAttention)
        #expect(MRHumanAction(row: row, assistantReady: true)?.action == .retryRun)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .blocked])
    func completedHistoricalJobDoesNotReplaceAnIndependentFailedIntent(state: AssistantJobExecution.State) throws {
        let row = try stoppedHistoryRow(state: state, independentFailure: true)
        #expect(row.hasIndependentStoppedWork && row.needsAttention)
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.action == .retryIntent)
        #expect(action.detail == "Conflict verification failed")
    }

    @Test func aRunAllowedToPushMayHaveChangedTheHeadBeforeStopping() throws {
        var item = item()
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"pushed","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.draftCount = 2
        let reason = "The fix reached the branch but its tests could not start."
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .blocked, blocker: reason),
            expectedHead: "before-push", mayPush: true), assistantReady: true))
        #expect(action.kind == .blockedRun && action.detail == reason)
    }

    @Test(arguments: [MRHumanAction.Action.reviewApproval, .reviewMerge, .reviewDecision, .reviewHandoff])
    func humanDecisionsDoNotRequireSettingUpAnAssistant(_ expected: MRHumanAction.Action) throws {
        var item = item()
        item.needsDiscussion = true
        switch expected {
        case .reviewApproval: item.canApprove = true
        case .reviewMerge: item.needsMerge = true
        case .reviewDecision: item.canConfirmReReview = true
        default: item.needsPipelineHandoff = true
        }
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.action == expected)
    }

    @Test func automaticApprovalWithoutAnAssistantExplainsTheMissingSetup() throws {
        var item = item()
        item.autoApproveReady = true
        item.humanActionRequired = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .setupAssistant)
        #expect(action.action == .setupAssistant)
    }

    @Test func aCheckWithoutDraftsDoesNotInventAPublicationTask() throws {
        var item = item()
        item.requiresDiscussionRecheck = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .reviewDecision)
        #expect(action.action == .reviewFeedback)
    }

    @Test func anOldRunCannotReplaceTheCurrentPublicationDecision() throws {
        var item = item()
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"current","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.draftCount = 2
        let execution = AssistantJobExecution(state: .blocked, summary: "A failure on the previous revision.")
        let action = try #require(MRHumanAction(row: row(item, execution: execution, expectedHead: "previous"), assistantReady: true))
        #expect(action.kind == .publication && action.action == .reviewDrafts)
        #expect(action.detail == nil)
        item.draftCount = 0
        let previous = try #require(MRHumanAction(row: row(item, execution: execution, expectedHead: "previous"), assistantReady: true))
        #expect(previous.kind == .interruptedRun && previous.action == .reviewRun)
        #expect(previous.detail == nil)
    }

    @Test(arguments: [AssistantJobExecution.State.blocked, .failed])
    func stoppedRunOffersRetryWithoutLosingTheActualReasonOrDraftPriority(_ state: AssistantJobExecution.State) throws {
        var item = item()
        item.draftCount = 3
        let reason = "The source branch could not be pushed because push permission is off."
        let execution = AssistantJobExecution(state: state, summary: "[MR](https://gitlab.example.test/mr/2)\n\nThree comments checked.\n\n\(reason)")
        let action = try #require(MRHumanAction(row: row(item, execution: execution), assistantReady: true))
        #expect(action.kind == .blockedRun)
        #expect(action.action == .retryRun)
        #expect(action.detail == reason)
        #expect(String(localized: action.actionLabel) == "Try again")
    }

    @Test(arguments: [AssistantJobExecution.State.interrupted, .cancelled])
    func interruptedOrCancelledRunOffersRetry(_ state: AssistantJobExecution.State) throws {
        let action = try #require(MRHumanAction(row: row(item(), execution: .init(state: state)), assistantReady: true))
        #expect(action.kind == .interruptedRun)
        #expect(action.action == .retryRun)
        #expect(action.detail == nil)
    }

    @Test func cancelledWorkDoesNotOverrideAnExplicitNeutralAttentionProjection() {
        var item = item()
        item.humanActionRequired = false
        #expect(MRHumanAction(row: row(item, execution: .init(state: .cancelled)), assistantReady: true) == nil)
    }

    @Test func aLegacyRunWithoutExecutableInstructionsKeepsItsResultAction() throws {
        let action = try #require(MRHumanAction(row: row(item(), execution: .init(state: .failed), executable: false),
                                              assistantReady: true))
        #expect(action.action == .reviewRun)
        #expect(String(localized: action.actionLabel) == "View run result")
    }

    @Test func aCompletedRunDoesNotReplaceTheCurrentPublicationDecisionWithRetry() throws {
        var item = item()
        item.draftCount = 1
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .succeeded)), assistantReady: true))
        #expect(action.kind == .publication && action.action == .reviewDrafts)
    }

    @Test func aSuccessfulWorkerStillShowsTheApplicationsExactCompletionFailure() throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        let reason = "The worker finished, but its result is not covered by current feedback evidence."
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .followUp, state: .failed, todoIDs: [], noteIDs: [42], sourceEvents: [], request: request,
            headSHA: "head", error: reason, updatedAt: Date())
        let base = row(item, execution: .init(state: .succeeded))
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: base.latestJob, intents: [intent])
        let action = try #require(MRHumanAction(row: row, assistantReady: true))
        #expect(action.action == .retryIntent)
        #expect(action.detail == reason)
    }

    @Test func draftCountAloneProducesAConcretePublicationReason() throws {
        var item = item()
        item.draftCount = 3
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .publication)
        #expect(action.action == .reviewDrafts)
        #expect(String(localized: action.message) == "3 comments need your review before publication.")
        #expect(action.detail == nil)
    }

    @Test(arguments: [false, true])
    func rawVerificationAndProcessDiagnosticsNeverBecomeTheCardHeadline(worker: Bool) throws {
        var item = item()
        let diagnostic = "Current account and headSHA match the snapshot. Technical evidence is missing."
        item.draftProofRecoveryFailure = worker ? nil : diagnostic
        item.draftCount = worker ? 0 : 1
        let row = row(item, execution: worker ? .init(state: .blocked, error: diagnostic) : nil)
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row),
            allowsRemoval: false, assistantReady: true)
        let action = try #require(model.humanAction)
        #expect(model.message == String(localized: action.message))
        #expect(!model.message.contains("headSHA"))
        #expect(action.detail == diagnostic)
    }

    @Test(arguments: ["The test described in this reply could not be confirmed. Check the reply before publishing.", "  ", String(repeating: "x", count: 201)])
    func onlyBoundedHumanSummariesBecomeHeadlines(summary: String) throws {
        var item = item()
        item.draftCount = 2
        item.draftProofRecoveryFailure = "Current account and commit match, but independent evidence is missing."
        item.draftProofRecoverySummary = summary
        let row = row(item)
        let model = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false, assistantReady: true)
        let action = try #require(model.humanAction)
        #expect(model.message == (AgentExplanation.summary(summary) ?? String(localized: action.message)))
        #expect(action.action == .retryDraftVerification)
        #expect(action.detail == item.draftProofRecoveryFailure)
    }

    @Test func semanticRejectionPointsToTheExactPreparedReplyAndItsSourceDiscussion() throws {
        var item = item()
        item.draftCount = 2
        item.drafts = [.init(id: 11, authorID: 3, note: "A verified reply waiting for publication permission", discussionID: "other", position: nil),
            .init(id: 12, authorID: 3, note: "I confirmed empty HTTP 200 in a test.\nThe second sentence is part of this reply.", discussionID: "source", position: nil)]
        item.draftProofRecoveryFailure = "No independent evidence establishes the claimed test run."
        item.draftProofRecoverySummary = "The empty-response test could not be confirmed."
        item.rejectedDrafts = [.init(draftID: 12, state: .uncertain, reason: item.draftProofRecoveryFailure!,
            summary: item.draftProofRecoverySummary, discussionRootNoteID: 40)]

        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.action == .reviewDrafts)
        let context = try #require(action.preparedReply)
        #expect(context.draftID == 12)
        #expect(context.quote == item.drafts[1].note)
        #expect(context.discussionURL?.absoluteString == item.url.absoluteString + "#note_40")
        #expect(action.explanation.lowercased().contains("prepared reply"))
        #expect(PreparedReplyContext.rejected(in: item).map(\.draftID) == [12])
    }

    @Test func aRejectedIDMissingFromTheCurrentDraftsCannotInventAQuote() throws {
        var item = item()
        item.draftCount = 1
        item.drafts = [.init(id: 11, authorID: 3, note: "User's current reply", discussionID: "other", position: nil)]
        item.draftProofRecoveryFailure = "The current draft snapshot could not be read."
        item.rejectedDrafts = [.init(draftID: 12, state: .invalid, reason: "An older reply was invalid",
            summary: "Check the prepared reply", discussionRootNoteID: 40)]
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.action == .retryDraftVerification && action.preparedReply == nil)
        #expect(PreparedReplyContext.rejected(in: item).isEmpty)
    }

    @Test func failedDraftProofRecoveryOffersVerificationWithoutPublication() throws {
        var item = item()
        item.draftCount = 1
        let reason = "The remote file changed after this draft was prepared."
        item.draftProofRecoveryFailure = reason
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .verificationFailure)
        #expect(action.detail == reason)
        #expect(String(localized: action.actionLabel) == "Verify drafts again")
    }

    @Test func recoveringDraftProofDoesNotAskForManualPublication() {
        var item = item()
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
    }

    @Test func recoveringDraftProofKeepsAnIndependentBlockedRunAction() throws {
        var item = item()
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion", phase: .checking)
        let action = try #require(MRHumanAction(row: row(item, execution: .init(state: .blocked, blocker: "Tests could not run.")), assistantReady: true))
        #expect(action.kind == .blockedRun)
    }

    @Test func recoveringDraftProofKeepsAnIndependentFailedIntentAction() throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.draftCount = 1
        item.draftProofRecoveryChecking = true
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion", phase: .checking)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .pipeline, state: .failed, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
            headSHA: "head", error: "Pipeline ownership could not be verified.", updatedAt: Date())
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [intent])
        let action = try #require(MRHumanAction(row: snapshot, assistantReady: true))
        #expect(action.kind == .intent && action.action == .retryIntent)
        #expect(action.detail == intent.error)
    }

    @Test(arguments: [false, true])
    func unboundFailedFollowUpWaitsNeutrallyOnlyForExplicitCurrentReconciliation(checkingReconciliation: Bool) throws {
        var item = item()
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        item.mergeRequest = request
        item.isAuthored = true
        item.draftCount = 4
        item.draftProofRecoveryChecking = true
        item.observedDiscussionFingerprint = "discussion"
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "discussion",
            semanticContextFingerprint: request.semanticContextFingerprint, readOnlyReconciliation: checkingReconciliation,
            phase: .checking, pendingDraftCount: 4)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .followUp, state: .failed, todoIDs: [], noteIDs: [42], sourceEvents: [], request: request,
            headSHA: "old-head", error: "Earlier attempt", updatedAt: Date())
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [intent])
        #expect(snapshot.hasIndependentStoppedWork == !checkingReconciliation)
        #expect(snapshot.needsAttention == !checkingReconciliation)
        #expect((MRHumanAction(row: snapshot, assistantReady: true) == nil) == checkingReconciliation)
    }

    @Test func oneDraftUsesSingularLanguage() throws {
        var item = item()
        item.draftCount = 1
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(String(localized: action.message) == "1 comment needs your review before publication.")
    }

    @Test func uncheckedDraftsExplainWhyPublicationNeedsReview() throws {
        var item = item()
        item.draftCount = 2
        item.requiresDiscussionRecheck = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .uncheckedDrafts)
        #expect(action.action == .reviewDrafts)
        #expect(String(localized: action.message) == "2 comments still need verification before automatic publication.")
    }

    @Test func verificationFailureHasAConcreteRetryActionWithoutInventingADetail() throws {
        var item = item()
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .failed)
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .verificationFailure)
        #expect(action.action == .verifyFeedback)
        #expect(action.detail == nil)
        #expect(String(localized: action.actionLabel) == "Verify again")
    }

    @Test func missingAssistantUsesSetupOnlyWhenNoPublicationDecisionIsPending() throws {
        var item = item()
        item.needsDiscussion = true
        let action = try #require(MRHumanAction(row: row(item), assistantReady: false))
        #expect(action.kind == .setupAssistant)
        #expect(action.action == .setupAssistant)
    }

    @Test func feedbackShowsTheVerifiersActualOutstandingExpectation() throws {
        var item = item()
        let reason = "The reviewer still expects a response explaining why retries are safe."
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .complete,
            findings: [.init(id: 10, discussionID: nil, reviewerID: 7, reviewerUsername: "alice", state: .needsChanges,
                reason: reason, waitingForReviewers: ["alice"])])
        let action = try #require(MRHumanAction(row: row(item), assistantReady: true))
        #expect(action.kind == .feedback)
        #expect(action.detail == reason)
    }

    @Test func quietSharedHumanProjectionOverridesAutomaticFlags() {
        var item = item()
        item.needsDiscussion = true
        item.failedPipeline = true
        item.humanActionRequired = false
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func activeAutomationIsQuietEvenWithOldFailureFlags(_ state: AssistantJobExecution.State) {
        var item = item()
        item.needsDiscussion = true
        item.humanActionRequired = true
        #expect(MRHumanAction(row: row(item, execution: .init(state: state)), assistantReady: true) == nil)
    }

    @Test func readOnlyCheckingAndPublicationAreQuiet() {
        var item = item()
        item.draftCount = 2
        item.authorFeedbackStatus = .init(head: "head", fingerprint: "text", phase: .checking)
        #expect(MRHumanAction(row: row(item), assistantReady: true) == nil)
        item.authorFeedbackStatus = nil
        #expect(MRHumanAction(row: row(item), assistantReady: true, confirmationState: .publishing) == nil)
        #expect(MRHumanAction(row: row(item), assistantReady: true, confirmationState: .approving) == nil)
    }
}
