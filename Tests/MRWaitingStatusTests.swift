import Foundation
import Testing
import MergeTetherRemote
@testable import MergeTether

@MainActor @Suite struct MRWaitingStatusTests {
    @Test(arguments: ["current", "missing", "stale", "unavailable", "hidden"], [true, false])
    func answeredFeedbackAndAReportedDependencyHoldNeedCurrentDependencyEvidence(_ evidence: String,
                                                                                _ discussionsBlocked: Bool) throws {
        var item = try fixture()
        let encoded = try JSONEncoder().encode(item.mergeRequest)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var fields = try #require(decoded as? [String: Any])
        fields["detailed_merge_status"] = "merge_request_blocked"
        if discussionsBlocked { fields["blocking_discussions_resolved"] = false }
        fields["merge_when_pipeline_succeeds"] = false
        fields["head_pipeline"] = ["id": 42, "status": "success", "sha": item.mergeRequest!.sha!]
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        item.mergeRequest = request
        let discussions: [GitLabMergeRequestDiscussion] = [10, 20, 30].map { id in
            .init(id: "thread-\(id)", notes: [
                .init(id: id, author: .init(id: 7, username: "alice", name: "Alice"), system: false,
                    resolvable: true, resolved: false, resolvedBy: nil, body: "Verify this condition"),
                .init(id: id + 1, author: .init(id: 3, username: "me", name: "Me"), system: false,
                    resolvable: false, resolved: nil, resolvedBy: nil, body: "Implemented and verified the correction.")])
        }
        let fingerprint = try #require(ReviewVerdict.fingerprint(discussions))
        item.observedDiscussionFingerprint = fingerprint
        item.feedback = GitLabMergeRequestDiscussion.unresolvedFeedback(in: discussions, excluding: 3)
        item.authorFeedbackStatus = .init(head: request.sha!, fingerprint: fingerprint,
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: [10, 20, 30].map { .init(id: $0, discussionID: "thread-\($0)", reviewerID: 7,
                reviewerUsername: "alice", state: .waitingAcceptance, reason: "Published reply covers the correction",
                waitingForReviewers: ["alice"]) }, addressedNoteIDs: [10, 20, 30])
        let parent = try MRDependencyPresentationTests().request(4, project: 1)
        if evidence != "missing" {
            item.dependencies = .init(request: request, stack: nil,
                dependencies: .init(requests: [parent], hasHiddenDependency: evidence == "hidden"),
                unavailableSources: evidence == "stale" || evidence == "unavailable" ? [.gitLab] : [])
        }
        let presentation = model(row(item))
        #expect((presentation.waitingStatus != nil) == (evidence == "current"))
        let original = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: presentation)
        let phone = RemoteBoardAdapter.mergePresentation(original, item: item,
            status: try mergeStatus(item, discussionsResolved: !discussionsBlocked), waitingStatus: presentation.waitingStatus)
        if evidence == "current" {
            #expect(item.authorFeedbackStatus?.findings.count == 3)
            #expect(item.authorFeedbackStatus?.replyNoteIDs.isEmpty == true && item.drafts.isEmpty)
            #expect(presentation.status == "Awaiting confirmation from Alice · Needs 2 more approvals")
            #expect(phone.presentation?.status == presentation.status)
            // A discussion blocker is already a listed requirement; the dependency hold joins the list.
            #expect(phone.presentation?.requirements == ["Awaiting confirmation from Alice", "Needs 2 more approvals"]
                + (discussionsBlocked ? [] : ["Required merge requests must merge first."]))
            #expect(phone.detail.isEmpty)
            #expect(phone.dependencies?.predecessors.first?.reference == "!4")
        } else { #expect(phone.presentation?.status != "Awaiting confirmation from Alice · Needs 2 more approvals") }
    }

    @Test func currentReviewerWaitIncludesApprovalProgressAndKeepsDependenciesSeparate() throws {
        var item = try fixture()
        let parent = try MRDependencyPresentationTests().request(4, project: 1)
        item.dependencies = .init(request: item.mergeRequest!, stack: nil,
            dependencies: .init(requests: [parent], hasHiddenDependency: false))
        let row = row(item)
        let model = model(row)
        let waiting = try #require(model.waitingStatus)
        #expect(waiting.reviewers == ["alice"])
        #expect(waiting.approvalProgress?.completed == 0 && waiting.approvalProgress?.required == 2)
        #expect(waiting.awaitingRequiredApprovals)
        #expect(waiting.requirements.map { String(localized: $0) } == ["Awaiting confirmation from Alice", "Needs 2 more approvals"])
        #expect(waiting.coveredBlockers == [.discussions, .approvals])
        #expect(model.status == "Awaiting confirmation from Alice · Needs 2 more approvals")
        #expect(model.humanAction == nil && !model.working)
        let original = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: model)
        let phone = RemoteBoardAdapter.mergePresentation(original, item: item, status: try mergeStatus(item),
            waitingStatus: model.waitingStatus)
        #expect(phone.presentation?.status == model.status)
        #expect(phone.presentation?.threadResolutionPeople == nil)
        #expect(phone.presentation?.requirementPeopleMessage?.people == [.init(name: "Alice", username: "alice")])
        #expect(phone.approvals?.received == 0 && phone.approvals?.required == 2)
        #expect(phone.dependencies?.predecessors.first?.reference == "!4")
        #expect(!phone.actions.contains { [.merge, .enqueueMerge, .resolveThreads, .publish, .approve].contains($0.kind) })
    }

    @Test(arguments: [true, false])
    func fulfilledCountsRetainReviewerWaitAndExplicitUnsatisfiedRules(_ satisfied: Bool) throws {
        var item = try fixture()
        item.approvalProgress = .init(completed: 5, required: 2)
        item.approvalProgress?.requirementsSatisfied = satisfied
        let waiting = try #require(model(row(item)).waitingStatus)
        #expect(waiting.awaitingRequiredApprovals == !satisfied)
        #expect(waiting.approvalProgress?.completed == 5)
        #expect(String(localized: waiting.title).contains("Alice"))
        // The header badge carries the count; a line appears only while a rule is unsatisfied.
        #expect(!String(localized: waiting.title).contains("5/2"))
        #expect(waiting.requirements.count == (satisfied ? 1 : 2))
        #expect(String(localized: waiting.title).contains("Required approvals are still missing") == !satisfied)
        #expect(waiting.coveredBlockers.contains(.approvals) == !satisfied)
    }

    @Test func resolutionWaitSendsAuthorsAndKeepsTheTextForOlderPhones() throws {
        var item = try fixture()
        let avatar = try #require(URL(string: "https://gitlab.example.test/avatar/alice.png"))
        item.feedback[0] = .init(id: 10, author: .init(id: 7, username: "alice", name: "Alice", avatarURL: avatar),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Check the retry")
        item.authorFeedbackStatus?.findings[0].waitingForHumanResolution = ["@alice", "alice", "bob"]
        let presentation = model(row(item))
        let original = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: presentation)
        let phone = RemoteBoardAdapter.mergePresentation(original, item: item,
            status: try mergeStatus(item, discussionsResolved: false), waitingStatus: presentation.waitingStatus)
        let card = try #require(phone.presentation)
        let data = try JSONEncoder().encode(card)
        struct WirePresentation: Decodable { let threadResolutionPeople: [RemotePerson]? }
        let decoded = try JSONDecoder().decode(WirePresentation.self, from: data)
        #expect(decoded.threadResolutionPeople == [
            .init(name: "Alice", username: "alice", avatarURL: avatar),
            .init(name: "bob", username: "bob"),
        ])
        #expect(try JSONDecoder().decode(RemoteCardText.self, from: data) == card)
        #expect(card.requirements == [
            "Feedback addressed, waiting for thread resolution from Alice and @bob",
            "Needs 2 more approvals",
        ])
    }

    @Test func approvalOnlyWaitDoesNotRequireFeedbackAndZeroRequiredDoesNotInventAWait() throws {
        var item = try fixture()
        item.authorFeedbackStatus = nil
        item.feedback = []; item.discussionObservation = .resolved
        #expect(model(row(item)).status == "Needs 2 more approvals")
        #expect(model(row(item)).waitingStatus?.coveredBlockers == [.approvals])
        item.approvalProgress = .init(completed: 1, required: 2)
        #expect(model(row(item)).status == "Needs 1 more approval")
        item.approvalProgress = .init(completed: 0, required: 0)
        #expect(model(row(item)).waitingStatus == nil)
        item.approvalProgress = nil
        #expect(model(row(item)).waitingStatus == nil)
    }

    @Test func quietBackgroundReadsKeepTheWaitingListWhileAShownRefreshReplacesIt() throws {
        let row = row(try fixture())
        let settled = model(row)
        for shown in [false, true] {
            let refreshing = MRCardPresentation(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false,
                assistantReady: true, isRefreshingAttention: true, showsReadProgress: shown)
            if shown { #expect(refreshing.waitingStatus == nil && refreshing.working) }
            else {
                #expect(refreshing.status == settled.status && !refreshing.working)
                #expect(refreshing.waitingStatus?.requirements.map { String(localized: $0) }
                    == settled.waitingStatus?.requirements.map { String(localized: $0) })
            }
        }
    }

    @Test func unknownApprovalCountsDoNotHideTheCurrentReviewerOrInventANumerator() throws {
        var item = try fixture()
        item.approvalProgress = nil
        let presentation = model(row(item))
        #expect(presentation.status == "Awaiting confirmation from Alice")
        #expect(presentation.waitingStatus?.approvalProgress == nil)
    }

    @Test func reviewerHandlesAreDeduplicatedAndLongListsAreBounded() throws {
        var item = try fixture()
        item.authorFeedbackStatus?.findings[0] = .init(id: 10, discussionID: "thread", reviewerID: 7,
            reviewerUsername: "alice", state: .waitingAcceptance, reason: nil,
            waitingForReviewers: ["alice", "@alice", "bob", "carol", "dave", " "])
        let waiting = try #require(model(row(item)).waitingStatus)
        #expect(waiting.reviewers == ["alice", "bob", "carol", "dave"])
        let title = String(localized: waiting.title)
        #expect(title.contains("Alice, @bob and 2 others"))
        #expect(!title.contains("@carol"))
    }

    @Test(arguments: ["head", "description", "discussion", "noDiscussion", "noSemantic", "failed", "checking", "publication", "reply", "code", "finding", "draft", "conflict", "pipeline", "stale", "changed", "refreshFailure", "refreshing", "manual", "rejectedReply", "reviewReadFailure", "approvalAction", "mergeAction"])
    func incompleteOrActionableEvidenceCannotBePresentedAsWaiting(_ change: String) throws {
        var item = try fixture()
        switch change {
        case "head": item.authorFeedbackStatus = .init(head: "older", fingerprint: "conversation", phase: .complete)
        case "description": item.authorFeedbackStatus?.semanticContextFingerprint = "older"
        case "discussion": item.authorFeedbackStatus = .init(head: item.mergeRequest!.sha!, fingerprint: "older", phase: .complete)
        case "noDiscussion": item.observedDiscussionFingerprint = nil
        case "noSemantic": item.authorFeedbackStatus?.semanticContextFingerprint = nil
        case "failed": item.authorFeedbackStatus?.phase = .failed
        case "checking": item.authorFeedbackStatus?.phase = .checking
        case "publication": item.authorFeedbackStatus?.phase = .waitingPublication
        case "reply": item.authorFeedbackStatus?.replyNoteIDs = [10]
        case "code": item.authorFeedbackStatus?.followUpNoteIDs = [10]
        case "finding": item.authorFeedbackStatus?.findings[0] = .init(id: 10, discussionID: "thread", reviewerID: 7,
            reviewerUsername: "alice", state: .needsChanges, reason: "Fix the retry", waitingForReviewers: [])
        case "draft": item.drafts = attentionFixtureDrafts(1)
        case "conflict": item.catalogIssues.insert(.conflict)
        case "pipeline": item.catalogIssues.insert(.failedPipeline)
        case "manual": item.requiresCommentReview = true
        case "rejectedReply": item.draftProofRecoveryReadFailure = true
        case "reviewReadFailure": item.reReviewReadiness = .failed
        case "approvalAction": item.approvalObservation = .manualFallback
        case "mergeAction": item.manualMergeAvailable = true
        default: break
        }
        var snapshot = row(item, humanAttention: change == "manual")
        snapshot.evidenceMatchesCatalogContext = change != "stale"
        let presentation = MRCardPresentation(row: snapshot, reviewingContext: ReviewingContext(row: snapshot),
            allowsRemoval: false, assistantReady: true, confirmationState: change == "changed" ? .changed : nil,
            isRefreshingAttention: change == "refreshing", refreshFailures: change == "refreshFailure" ? [.init(check: .mergeRequests)] : [])
        #expect(presentation.waitingStatus == nil)
        #expect(presentation.status?.contains("@alice") != true)
    }

    @Test(arguments: ["blocked", "failed", "interrupted", "cancelled"])
    func stoppedWorkIsNotReplacedByWaitingForTheReviewer(_ state: String) throws {
        let item = try fixture()
        let executionState = try #require(AssistantJobExecution.State(rawValue: state))
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Follow-up", prompt: "Fix", createdAt: Date(), allowsPush: true,
            execution: .init(state: executionState, blocker: "Required evidence is unavailable."),
            expectedHeadSHA: item.mergeRequest?.sha)
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [],
            attentionPresentation: .init(evidence: item, humanActionRequired: true, verifiesFeedback: false))
        let presentation = model(snapshot)
        let action = try #require(presentation.humanAction)
        #expect(presentation.waitingStatus == nil && presentation.status == nil)
        if executionState == .interrupted || executionState == .cancelled {
            #expect(action.kind == .interruptedRun && action.detail == nil)
        } else {
            #expect(action.kind == .blockedRun && action.detail == "Required evidence is unavailable.")
        }
    }

    @Test(arguments: ["merged", "closed", "draft"])
    func completedAndDraftRequestsKeepTheirExistingStatus(_ state: String) throws {
        var item = try fixture()
        let source = try #require(item.mergeRequest)
        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var fields = try #require(decoded as? [String: Any])
        fields["state"] = state == "draft" ? "opened" : state
        fields["draft"] = state == "draft"
        item.mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        let presentation = model(row(item))
        #expect(presentation.waitingStatus == nil)
        if state != "draft" { #expect(presentation.status == String(localized: MergeRequestFinishedState(rawValue: state)!.status)) }
    }

    @Test func newerCatalogCountsAreUsedWithoutBorrowingAnOlderFeedbackAssessment() throws {
        var item = try fixture()
        var catalog = item
        catalog.approvalProgress = .init(completed: 5, required: 2)
        var snapshot = row(item)
        snapshot.catalog = .init(catalog)
        #expect(model(snapshot).waitingStatus?.approvalProgress?.completed == 5)
        item.authorFeedbackStatus?.semanticContextFingerprint = "earlier description"
        snapshot = row(item); snapshot.catalog = .init(catalog)
        #expect(model(snapshot).waitingStatus == nil)
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running])
    func activeWorkKeepsItsStatusInsteadOfTheReviewerWait(_ state: AssistantJobExecution.State) throws {
        let item = try fixture()
        let request = item.mergeRequest!
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
            title: "Review", prompt: "Review", createdAt: Date(), allowsPush: false,
            execution: .init(state: state), expectedHeadSHA: request.sha)
        let snapshot = MergeRequestBoardSnapshot.Row(item: item, latestJob: job, intents: [])
        let presentation = model(snapshot)
        #expect(presentation.waitingStatus == nil)
        #expect(presentation.status?.contains("@alice") != true)
    }

    @Test(arguments: ["queued", "uncertain", "stale", "staleCatalog"])
    func phoneSubmissionAndUnavailableChecksKeepPriority(_ state: String) throws {
        let item = try fixture()
        let presentation = model(row(item))
        let original = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: presentation)
        let status = try mergeStatus(item, submission: state == "queued" ? .queued : state == "uncertain" ? .uncertain : .none)
        let phone = RemoteBoardAdapter.mergePresentation(original, item: item, status: status,
            evidenceMatchesCatalogContext: state != "stale", hasCurrentCatalog: state != "staleCatalog",
            waitingStatus: presentation.waitingStatus)
        #expect(phone.presentation?.status != presentation.status)
    }

    @Test(arguments: ["missing", "capability"])
    func missingMergeActionMetadataDoesNotEraseCurrentIndependentWaitingFacts(_ state: String) throws {
        let item = try fixture()
        let presentation = model(row(item))
        let original = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: presentation)
        let status = try mergeStatus(item, action: state == "capability" ? nil : .mergeNow)
        let phone = RemoteBoardAdapter.mergePresentation(original, item: item, status: state == "missing" ? nil : status,
            waitingStatus: presentation.waitingStatus)
        #expect(phone.presentation?.status == presentation.status)
        // The pending merge check joins the requirement list instead of a separate detail line.
        let blocker: ManualMergeBlocker = state == "missing" ? .checking : .capability
        #expect(phone.presentation?.requirements?.last == String(localized: blocker.title))
        #expect(phone.detail.isEmpty && phone.primaryCTA != nil)
        #expect(!phone.actions.contains { [.merge, .enqueueMerge, .approve, .publish, .resolveThreads].contains($0.kind) })
    }

    private func row(_ item: MergeRequestAttentionMonitor.Item, humanAttention: Bool? = false) -> MergeRequestBoardSnapshot.Row {
        .init(item: item, latestJob: nil, intents: [],
            attentionPresentation: .init(evidence: item, humanActionRequired: humanAttention, verifiesFeedback: false))
    }
    private func model(_ row: MergeRequestBoardSnapshot.Row) -> MRCardPresentation {
        .init(row: row, reviewingContext: ReviewingContext(row: row), allowsRemoval: false, assistantReady: true)
    }
    private func fixture() throws -> MergeRequestAttentionMonitor.Item {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","description":"Context","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"mergeable","has_conflicts":false,"user":{"can_merge":true}}"#.utf8))
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 2), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: true)
        item.observedDiscussionFingerprint = "conversation"
        item.discussionObservation = .unresolvedIncoming
        item.feedback = [.init(id: 10, author: .init(id: 7, username: "alice", name: "Alice"),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Check the retry")]
        item.approvalProgress = .init(completed: 0, required: 2)
        item.authorFeedbackStatus = .init(head: request.sha!, fingerprint: "conversation",
            semanticContextFingerprint: request.semanticContextFingerprint, phase: .complete,
            findings: [.init(id: 10, discussionID: "thread", reviewerID: 7, reviewerUsername: "alice",
                state: .waitingAcceptance, reason: "Current code addresses the concern", waitingForReviewers: ["alice"])],
            addressedNoteIDs: [10])
        return item
    }
    private func mergeStatus(_ item: MergeRequestAttentionMonitor.Item, submission: MergeSubmissionState = .none,
                             discussionsResolved: Bool = true,
                             action: MergeSubmissionAction? = .mergeNow) throws -> AuthoredMergeRequestStatus {
        let approvals = try JSONDecoder().decode(GitLabMergeRequestApprovalState.self,
            from: Data(#"{"rules":[{"approvals_required":2,"approved":false}]}"#.utf8))
        return .init(request: item.mergeRequest!, approvals: approvals, discussionsResolved: discussionsResolved,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: false,
            dependencyReadiness: .waitingForDependencies, action: action, submissionState: submission)
    }
}
