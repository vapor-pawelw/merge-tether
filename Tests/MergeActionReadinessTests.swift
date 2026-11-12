import Foundation
import Testing
@testable import GitLabTodos

struct MergeActionReadinessTests {
    @Test(arguments: ["discussions", "capability"])
    func independentFeedbackRecoverySurvivesAnotherPrimaryMergeBlocker(_ gate: String) throws {
        let checked = try status(blocker: gate == "discussions" ? "discussions" : "",
            action: gate == "capability" ? nil : .mergeNow)
        var listed = try item(checked, changes: gate == "discussions" ? ["blocking_discussions_resolved": false] : [:])
        listed.observedDiscussionFingerprint = "current-conversation"
        listed.authorFeedbackStatus = .init(head: checked.request.sha!, fingerprint: "current-conversation",
            semanticContextFingerprint: checked.request.semanticContextFingerprint, phase: .complete, replyNoteIDs: [5, 7])
        #expect(listed.manualMergeBlocker(using: checked) == (gate == "discussions" ? .prerequisite(.discussions) : .capability))
        #expect(!listed.canOfferManualMerge(using: checked))
        let recovery = try #require(listed.manualFeedbackRecovery())
        #expect(recovery.blocker == .reply && recovery.recoveryAction == .reviewFeedback)
        #expect(recovery.replySourceIDs == [5, 7])
        listed.authorFeedbackStatus?.findings = [.init(id: 5, discussionID: "thread", reviewerID: 9,
            reviewerUsername: "reviewer", state: .needsReply, reason: "A later comment in this thread needs a reply.",
            waitingForReviewers: [], sourceNoteID: 9)]
        #expect(listed.manualFeedbackRecovery()?.replySourceIDs == [7, 9])
        listed.observedDiscussionFingerprint = "edited-conversation"
        let changed = try #require(listed.manualFeedbackRecovery())
        #expect(changed.blocker == .discussionChanged && changed.recoveryAction == .refresh)
        #expect(changed.replySourceIDs.isEmpty)
    }

    @Test(arguments: ["same", "target", "description", "title", "draft", "authorID", "username", "host", "head"])
    func displayedMergeStatusRequiresTheExactCurrentRequest(_ change: String) throws {
        let checked = try status()
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(checked.request)) as? [String: Any])
        switch change {
        case "target": fields["target_branch"] = "parent"
        case "description": fields["description"] = "New condition"
        case "title": fields["title"] = "Edited"
        case "draft": fields["draft"] = true
        case "authorID": fields["author"] = ["id": 4, "username": "me", "name": "Me"]
        case "username": fields["author"] = ["id": 3, "username": "other", "name": "Me"]
        case "host": fields["web_url"] = "https://other.example.test/g/p/-/merge_requests/2"
        case "head": fields["sha"] = String(repeating: "b", count: 40)
        default: break
        }
        let current = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(checked.matchesCurrentRequest(current) == (change == "same"))
    }

    @Test(arguments: [false, true])
    func manualMergeDoesNotDependOnTheAutomaticSetting(_ automatic: Bool) throws {
        let status = try status(automatic: automatic)
        #expect(status.mayMergeManually)
        #expect(status.mayAutoMerge == automatic)
    }

    @Test(arguments: ["draft", "approvals", "discussions", "drafts", "work", "dependencies", "target", "unknown", "permission", "conflict", "pipeline"])
    func manualMergeKeepsAllIndependentGuards(_ blocker: String) throws {
        #expect(try !status(blocker: blocker).mayMergeManually)
    }

    @Test func trainCanQueueWhileItsPipelineRunsButCannotSkipFailedCI() throws {
        #expect(try status(action: .enqueue, pipeline: "running").mayMergeManually)
        #expect(try !status(action: .enqueue, pipeline: "failed").mayMergeManually)
        #expect(try !status(action: .mergeNow, pipeline: "running").mayMergeManually)
    }

    @Test(arguments: [MergeSubmissionState.queued, .inTrain, .uncertain, .changed])
    func queuedOrUncertainRequestsNeverOfferAnotherSubmission(_ state: MergeSubmissionState) throws {
        let value = try status(state: state)
        #expect(!value.mayMergeManually && !value.mayAutoMerge)
    }

    @Test func unknownProjectCapabilitiesNeverOfferAWrite() throws {
        #expect(try !status(action: nil).mayMergeManually)
    }

    @Test(arguments: [MergeSubmissionAction.mergeNow, .enqueue])
    func sparseListFieldsDoNotVetoTheCheckedDetailAction(_ action: MergeSubmissionAction) throws {
        let checked = try status(action: action)
        let listed = try item(checked, removing: ["user", "head_pipeline"])
        #expect(listed.mergeRequest?.canMerge == nil)
        #expect(listed.canOfferManualMerge(using: checked))
        #expect(listed.manualMergeBlocker(using: checked) == nil)
    }

    @Test(arguments: ["permission", "conflict", "pipeline", "discussions", "queued", "checking"])
    func explicitCatalogBlockersStillVetoAReadyDetail(_ blocker: String) throws {
        let checked = try status()
        let changes: [String: Any]
        switch blocker {
        case "permission": changes = ["user": ["can_merge": false]]
        case "conflict": changes = ["has_conflicts": true]
        case "pipeline": changes = ["head_pipeline": ["id": 4, "status": "failed"]]
        case "discussions": changes = ["blocking_discussions_resolved": false]
        case "queued": changes = ["merge_when_pipeline_succeeds": true]
        default: changes = ["detailed_merge_status": "checking"]
        }
        let listed = try item(checked, changes: changes)
        let expected: ManualMergeBlocker = switch blocker {
        case "permission": .prerequisite(.permissions)
        case "conflict": .prerequisite(.conflicts)
        case "pipeline": .prerequisite(.pipeline)
        case "discussions": .prerequisite(.discussions)
        case "queued": .submission
        default: .prerequisite(.checking)
        }
        #expect(!listed.canOfferManualMerge(using: checked))
        #expect(listed.manualMergeBlocker(using: checked) == expected)
    }

    @Test(arguments: ["drafts", "draftList", "review", "recheck", "discussion", "otherDiscussion", "feedback", "changes", "conflict", "pipeline", "handoff"])
    func checkedMergeReadinessDoesNotErasePrivateOrUnfinishedWork(_ blocker: String) throws {
        let checked = try status()
        var listed = try item(checked, removing: ["user"])
        switch blocker {
        case "drafts": listed.draftCount = 1
        case "draftList": listed.drafts = [.init(id: 7, authorID: 3, note: "Private reply", discussionID: nil, position: nil)]
        case "review": listed.requiresCommentReview = true
        case "recheck": listed.requiresDiscussionRecheck = true
        case "discussion": listed.needsDiscussion = true
        case "otherDiscussion": listed.hasOtherUnresolvedDiscussions = true
        case "feedback": listed.feedback = [try JSONDecoder().decode(GitLabMergeRequestDiscussion.Note.self,
            from: Data("{\"id\":5,\"body\":\"Please check\"}".utf8))]
        case "changes": listed.needsChanges = true
        case "conflict": listed.hasConflict = true
        case "pipeline": listed.failedPipeline = true
        default: listed.needsPipelineHandoff = true
        }
        #expect(!listed.canOfferManualMerge(using: checked))
        #expect(listed.manualMergeBlocker(using: checked) != nil)
    }

    @Test(arguments: ["target_branch", "sha", "title", "author", "web_url"])
    func sparseListCannotBorrowReadinessFromAnotherContext(_ field: String) throws {
        let checked = try status()
        let value: Any = field == "author" ? ["id": 4, "username": "other", "name": "Other"]
            : field == "sha" ? String(repeating: "b", count: 40)
            : field == "web_url" ? "https://other.test/g/p/-/merge_requests/2" : "changed"
        let listed = try item(checked, removing: ["user"], changes: [field: value])
        #expect(!listed.canOfferManualMerge(using: checked))
        #expect(listed.manualMergeBlocker(using: checked) == .context)
    }

    @Test(arguments: ["current", "head", "discussion", "semantic", "checking", "failed"])
    func feedbackEvidenceMustBeCompleteAndBoundBeforeOfferingMerge(_ change: String) throws {
        let checked = try status()
        var listed = try item(checked, removing: ["user"])
        listed.observedDiscussionFingerprint = "conversation"
        listed.authorFeedbackStatus = .init(head: change == "head" ? "old" : checked.request.sha!,
            fingerprint: change == "discussion" ? "old" : "conversation",
            semanticContextFingerprint: change == "semantic" ? "old" : checked.request.semanticContextFingerprint,
            phase: change == "checking" ? .checking : change == "failed" ? .failed : .complete)
        #expect(listed.canOfferManualMerge(using: checked) == (change == "current"))
        #expect((listed.manualMergeBlocker(using: checked) == nil) == (change == "current"))
    }

    @Test func absentMergeEvidenceExplainsThePendingCheckOrCapability() throws {
        let ready = try status()
        let listed = try item(ready, removing: ["user"])
        #expect(listed.manualMergeBlocker(using: nil) == .checking)
        #expect(try listed.manualMergeBlocker(using: status(action: nil)) == .capability)
        #expect(try listed.manualMergeBlocker(using: status(blocker: "approvals")) == .prerequisite(.approvals))
        #expect(try listed.manualMergeBlocker(using: status(blocker: "dependencies")) == .prerequisite(.dependencies))
        #expect(try listed.manualMergeBlocker(using: status(blocker: "unknown")) == .prerequisite(.dependencyEvidence))
    }

    @Test(arguments: ["addressed", "ignored", "uncovered", "reply", "head", "conversation", "semantic", "checking", "failed"])
    func feedbackReadinessUsesTheExactVerifiedNotesAndExplainsItsRemainingGate(_ scenario: String) throws {
        let checked = try status()
        var listed = try item(checked, removing: ["user"])
        listed.feedback = [try feedbackNote()]
        listed.needsDiscussion = true
        listed.observedDiscussionFingerprint = "conversation"
        listed.authorFeedbackStatus = .init(head: scenario == "head" ? "old" : checked.request.sha!,
            fingerprint: scenario == "conversation" ? "old" : "conversation",
            semanticContextFingerprint: scenario == "semantic" ? "old" : checked.request.semanticContextFingerprint,
            phase: scenario == "checking" ? .checking : scenario == "failed" ? .failed : .complete,
            replyNoteIDs: scenario == "reply" ? [5] : [],
            addressedNoteIDs: scenario == "uncovered" ? [6] : scenario == "ignored" ? [] : [5],
            ignoredNoteIDs: scenario == "ignored" ? [5] : [])
        let expected: ManualMergeFeedbackBlocker? = switch scenario {
        case "uncovered": .unverifiedComments
        case "reply": .reply
        case "head": .sourceChanged
        case "conversation": .discussionChanged
        case "semantic": .descriptionChanged
        case "checking": .checking
        case "failed": .verificationFailed
        default: nil
        }
        #expect(listed.manualMergeBlocker(using: checked) == expected.map(ManualMergeBlocker.feedback))
        #expect(listed.manualFeedbackRecovery()?.blocker == expected)
        #expect(listed.canOfferManualMerge(using: checked) == (expected == nil))
        #expect(listed.feedback.count == 1 && listed.needsDiscussion)
    }

    @Test(arguments: ["changes", "verification", "publication", "reply", "question", "followUp", "unverified"])
    func eachRemainingFeedbackObligationKeepsAnActionableMergeHold(_ obligation: String) throws {
        let checked = try status()
        var listed = try item(checked)
        listed.observedDiscussionFingerprint = "conversation"
        var feedback = AuthorFeedbackStatus(head: checked.request.sha!, fingerprint: "conversation",
            semanticContextFingerprint: checked.request.semanticContextFingerprint, phase: .complete)
        switch obligation {
        case "changes", "verification": feedback.findings = [.init(id: 5, discussionID: "thread", reviewerID: 7,
            reviewerUsername: "reviewer", state: obligation == "changes" ? .needsChanges : .needsVerification,
            reason: "A specific remaining requirement", waitingForReviewers: [])]
        case "publication": feedback.pendingDraftCount = 1
        case "reply": feedback.replyNoteIDs = [5]
        case "question": feedback.codeReviewRequests = [.init(sourceNoteID: 5, sourceQuote: "Please check",
            kind: .feedbackVerification, summary: "Verify the fallback", question: "Does the fallback handle retries?")]
        case "followUp": feedback.followUpNoteIDs = [5]
        default: listed.feedback = [try feedbackNote()]
        }
        listed.authorFeedbackStatus = feedback
        let blocker = try #require(listed.manualMergeBlocker(using: checked))
        #expect(!listed.canOfferManualMerge(using: checked))
        #expect(blocker.recoveryAction == .reviewFeedback)
        #expect(blocker != .feedback(.checking))
    }

    @Test func unavailableFeedbackEvidenceHasAReadOnlyRecoveryInsteadOfADeadEnd() throws {
        let checked = try status()
        var listed = try item(checked)
        listed.observedDiscussionFingerprint = "conversation"
        listed.authorFeedbackStatus = .init(head: checked.request.sha!, fingerprint: "conversation",
            semanticContextFingerprint: checked.request.semanticContextFingerprint, phase: .failed)
        #expect(listed.manualMergeBlocker(using: checked)?.recoveryAction == .verifyFeedback)
        listed.authorFeedbackStatus?.phase = .checking
        #expect(listed.manualMergeBlocker(using: checked)?.recoveryAction == nil)
        listed.authorFeedbackStatus?.phase = .complete
        listed.observedDiscussionFingerprint = "new-conversation"
        #expect(listed.manualMergeBlocker(using: checked)?.recoveryAction == .refresh)
        listed.observedDiscussionFingerprint = nil
        #expect(listed.manualMergeBlocker(using: checked) == .feedback(.conversationUnavailable))
        listed.observedDiscussionFingerprint = "conversation"
        listed.authorFeedbackStatus?.semanticContextFingerprint = nil
        #expect(listed.manualMergeBlocker(using: checked) == .feedback(.assessmentMissing))
    }

    @MainActor @Test(arguments: ["manual", "undecided", "disabled", "paused", "featuresOff", "automatic"])
    func feedbackRecheckExecutesReviewInsteadOfANoopWhenBackgroundChecksCannotRun(_ profile: String) throws {
        let request = try status().request
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        switch profile {
        case "manual": configuration.applyPreset(.manual, for: .codex)
        case "undecided": configuration.packageDecision = .undecided
        case "disabled": configuration.packageDecision = .disabled
        case "paused": configuration.scope[target] = .paused
        case "featuresOff":
            configuration.autoResolveAcceptedFeedback = false
            configuration.autoMergeEnabled = false
            configuration.authorFeedback.isEnabled = false
            configuration.workflowRules[.newDiscussion].mode = .off
        default: break
        }
        let before = configuration
        let permitted = AuthorFeedbackCoordinator.permitsBackgroundCheck(for: request, configuration: configuration,
            host: target.host, username: target.username)
        let route = ManualFeedbackRecheckRoute(backgroundCheckAllowed: permitted)
        let displayed = try item(status())
        var executed: [String] = []
        var destination: ManualFeedbackReviewDestination?
        route.perform(verify: { executed.append("verify") }, review: {
            executed.append("review")
            destination = .init(item: displayed)
        })
        #expect(executed == [profile == "automatic" ? "verify" : "review"])
        #expect(route.recoveryAction == (profile == "automatic" ? .verifyFeedback : .reviewFeedback))
        #expect(displayed.authorFeedbackStatus == nil)
        #expect(destination == (profile == "automatic" ? nil : .gitLab(displayed.url)))
        #expect(configuration == before)
    }

    private func feedbackNote() throws -> GitLabMergeRequestDiscussion.Note {
        try JSONDecoder().decode(GitLabMergeRequestDiscussion.Note.self,
            from: Data(#"{"id":5,"author":{"id":7,"username":"reviewer"},"body":"Please check","system":false,"resolvable":true,"resolved":true}"#.utf8))
    }

    @MainActor @Test(arguments: ["current", "head", "title", "description", "discussion"])
    func acceptedCorrectionsAndACoveredSummaryOfferMergeOnCardAndDetailsOnlyForTheirCheckedContext(_ change: String) throws {
        let checked = try status()
        let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"finding","notes":[{"id":10,"author":{"id":7},"system":false,"resolvable":true,"resolved":true,"body":"Cover the retry path","created_at":"2026-01-01T10:00:00Z"},{"id":11,"author":{"id":3},"system":false,"body":"The correction is present and the regression verifies it.","created_at":"2026-01-01T10:01:00Z"},{"id":12,"author":{"id":7},"system":false,"body":"The correction is accepted.","created_at":"2026-01-01T10:02:00Z"}]},{"id":"summary","notes":[{"id":20,"author":{"id":7},"system":false,"resolvable":false,"body":"The earlier retry finding is fixed."}]}]"#.utf8))
        let assessment = try ReReviewAssessment(notes: [
            .init(noteID: 10, state: .addressed, reason: "The correction and published reply are verified.", acceptanceNoteID: 12),
            .init(noteID: 12, state: .informational, reason: "The reviewer explicitly accepted the correction."),
            .init(noteID: 20, state: .addressed, reason: "The summary adds no independent expectation.",
                informationalPurpose: .reviewSummary,
                reviewSummaryCoverage: .init(referencedNoteIDs: [10], noIndependentExpectation: true))
        ]).normalizingCoveredReviewSummaries(in: threads, authorID: 3)
        let fingerprint = try #require(ReviewVerdict.fingerprint(threads))
        var observedThreads = threads
        if change == "discussion" {
            let encoded = String(decoding: try JSONEncoder().encode(threads), as: UTF8.self)
                .replacingOccurrences(of: "The earlier retry finding is fixed.",
                    with: "The earlier retry finding is fixed. Also document rollback before merging.")
            observedThreads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(encoded.utf8))
        }
        let changes: [String: Any] = change == "head" ? ["sha": String(repeating: "b", count: 40)]
            : change == "title" ? ["title": "Changed requirements"]
            : change == "description" ? ["description": "A new prerequisite before merge"] : [:]
        var listed = try item(checked, removing: ["user"], changes: changes)
        listed.feedback = [try #require(threads.first?.notes.first)]
        listed.needsDiscussion = true
        listed.observedDiscussionFingerprint = ReviewVerdict.fingerprint(observedThreads)
        listed.authorFeedbackStatus = .init(head: checked.request.sha!, fingerprint: fingerprint,
            semanticContextFingerprint: checked.request.semanticContextFingerprint, phase: .complete,
            replyNoteIDs: Set(assessment.missingPublishedRepliesByThread(in: threads, authorID: 3).keys),
            addressedNoteIDs: Set(assessment.notes.map(\.noteID)))
        var input = MRBoardProjector.Input(account: .init(host: "gitlab.example.test", username: "me", revision: 1))
        input.attention = .init(host: "gitlab.example.test", username: "me", revision: 1,
            evidence: [listed], attention: [], catalog: [listed])
        input.authored = [checked]
        input.automation.applyPreset(.manual, for: .codex)
        let projector = MRBoardProjector(input: input)
        let board = projector.board()
        let card = try #require(board.own.first)
        let detail = CommandCenterDisplayFrame.Detail(item: listed, board: board, host: "gitlab.example.test", username: "me")
        #expect(card.item.canOfferManualMerge(using: checked) == (change == "current"))
        #expect(detail.item.canOfferManualMerge(using: checked) == (change == "current"))
        #expect((projector.attentionItems.first?.needsMerge == true) == (change == "current"))
        #expect(AuthorFeedbackPolicy.acceptedReviewers(discussions: threads, assessment: assessment, authorID: 3,
            approvedReviewerIDs: []) == [7])
    }

    @MainActor @Test(arguments: [MergeSubmissionAction.mergeNow, .enqueue])
    func sparseCatalogOffersTheSameMergeOnCardAndDetails(_ action: MergeSubmissionAction) throws {
        let checked = try status(action: action)
        let listed = try item(checked, removing: ["user", "head_pipeline"])
        var input = MRBoardProjector.Input(account: .init(host: "gitlab.example.test", username: "me", revision: 1))
        input.attention = .init(host: "gitlab.example.test", username: "me", revision: 1,
            evidence: [listed], attention: [], catalog: [listed])
        input.authored = [checked]
        input.automation.applyPreset(.manual, for: .codex)
        let projector = MRBoardProjector(input: input)
        let card = try #require(projector.board().own.first)
        let detail = CommandCenterDisplayFrame.Detail(item: listed, board: projector.board(),
            host: "gitlab.example.test", username: "me")
        #expect(projector.attentionItems.first?.needsMerge == true)
        #expect(card.evidenceMatchesCatalogContext)
        #expect(card.item.canOfferManualMerge(using: checked))
        #expect(detail.item.canOfferManualMerge(using: checked))
        #expect(checked.action == action)
    }

    private func item(_ status: AuthoredMergeRequestStatus, removing: [String] = [],
                      changes: [String: Any] = [:]) throws -> MergeRequestAttentionMonitor.Item {
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status.request)) as? [String: Any])
        for key in removing { fields.removeValue(forKey: key) }
        for (key, value) in changes { fields[key] = value }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        return .init(id: .init(projectID: request.projectID, iid: request.iid), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
    }

    private func status(automatic: Bool = false, blocker: String = "", action: MergeSubmissionAction? = .mergeNow,
                        pipeline: String? = nil, state: MergeSubmissionState = .none) throws -> AuthoredMergeRequestStatus {
        var object: [String: Any] = ["project_id": 1, "iid": 2, "author": ["id": 3, "username": "me", "name": "Me"],
            "title": "Feature", "labels": [], "web_url": "https://gitlab.example.test/g/p/-/merge_requests/2",
            "state": "opened", "draft": blocker == "draft", "sha": String(repeating: "a", count: 40),
            "source_project_id": 1, "target_project_id": 1, "source_branch": "feature", "target_branch": "main",
            "detailed_merge_status": pipeline == "running" ? "ci_still_running" : "mergeable",
            "has_conflicts": blocker == "conflict", "user": ["can_merge": blocker != "permission"]]
        if let pipeline { object["head_pipeline"] = ["id": 4, "status": pipeline] }
        if blocker == "pipeline" { object["head_pipeline"] = ["id": 4, "status": "failed"] }
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        let approvals = try JSONDecoder().decode(GitLabMergeRequestApprovalState.self,
            from: Data("{\"rules\":[{\"approvals_required\":2,\"approved\":\(blocker != "approvals")}]}".utf8))
        return .init(request: request, approvals: approvals, discussionsResolved: blocker != "discussions",
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: automatic,
            dependencyReadiness: blocker == "dependencies" ? .waitingForDependencies
                : blocker == "target" ? .reviewStackTarget : blocker == "unknown" ? .unavailable : .ready,
            pendingDraftCount: blocker == "drafts" ? 1 : 0, requiresCommentReview: blocker == "work",
            action: action, submissionState: state)
    }
}
