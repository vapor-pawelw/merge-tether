import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct ReviewingContextTests {
    private func request(draft: Bool = false, discussionsResolved: Bool? = nil) throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice Author"},"title":"Example","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":\#(draft),"sha":"abc","source_branch":"feature","target_branch":"main","labels":[],"blocking_discussions_resolved":\#(discussionsResolved.map(String.init) ?? "null")}"#.utf8))
    }
    private func item() throws -> MergeRequestAttentionMonitor.Item {
        let request = try request()
        return .init(id: .init(projectID: 1, iid: 2), title: request.title, url: request.webURL, mergeRequest: request)
    }
    private func note(_ id: Int?, user: Int?, resolved: Bool = false, system: Bool = false) -> GitLabMergeRequestDiscussion.Note {
        .init(id: id, author: user.map { .init(id: $0, username: "user\($0)", name: nil) },
              system: system, resolvable: true, resolved: resolved, resolvedBy: nil, body: "Comment")
    }
    private func row(_ item: MergeRequestAttentionMonitor.Item, job: AssistantAutomationRunner.Handoff? = nil,
                     intents: [MRTodoIntent] = [], humanAttention: Bool? = nil) -> MergeRequestBoardSnapshot.Row {
        .init(item: item, latestJob: job, intents: intents,
            attentionPresentation: .init(evidence: item, humanActionRequired: humanAttention, verifiesFeedback: false))
    }
    private func reviewJob(_ state: AssistantJobExecution.State) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead),
              title: "Review", prompt: "", createdAt: Date(), allowsPush: false,
              execution: .init(state: state), workflow: .review, expectedHeadSHA: "abc")
    }

    @Test(arguments: [true, false])
    func legacyApprovalRequiresEvidenceItFollowsTheCurrentDiff(_ current: Bool) async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.close() }
        let legacy = SettingsManager(defaults: fixture.defaults)
        legacy.autoPublishOptOuts.insert(fixture.target)
        #expect(legacy.save())
        fixture.approvalTime = current ? "2026-01-01T12:00:00Z" : "2026-01-01T10:00:00Z"

        let monitor = fixture.monitor()
        await fixture.refresh(monitor)

        #expect(monitor.currentOpenItems.first?.reviewingProgress == (current ? .current : .needsReview))
        #expect(fixture.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["head", "target", "base", "title"])
    func persistedApprovalBecomesStaleAfterDiffChanges(_ change: String) async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.close() }
        let initial = fixture.monitor()
        await fixture.refresh(initial)
        #expect(initial.currentOpenItems.first?.reviewingProgress == .current)

        let restarted = fixture.monitor()
        fixture.diffReadFails = true
        await fixture.refresh(restarted)
        #expect(restarted.currentOpenItems.first?.reviewingProgress == .current)

        switch change {
        case "head": fixture.head = "def"
        case "target":
            fixture.branch = "release"
            fixture.metadataChange = "changed target branch from `main` to `release`"
        case "title":
            fixture.title = "Edited title"
            fixture.metadataChange = "<p>changed title from Example to Edited title</p>"
        default: fixture.base = "new-base"
        }
        fixture.diffReadFails = false
        if fixture.metadataChange == nil { fixture.diffTime = "2026-01-02T11:00:00Z" }
        let changedWhileClosed = fixture.monitor()
        await fixture.refresh(changedWhileClosed)
        #expect(changedWhileClosed.currentOpenItems.first?.reviewingProgress == .needsReview)

        fixture.approvalTime = "2026-01-02T10:00:00Z"
        await fixture.refresh(changedWhileClosed)
        #expect(changedWhileClosed.currentOpenItems.first?.reviewingProgress == .needsReview)

        fixture.approvalTime = "2026-01-02T12:00:00Z"
        await fixture.refresh(changedWhileClosed)
        #expect(changedWhileClosed.currentOpenItems.first?.reviewingProgress == .current)
        #expect(fixture.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func switchingAccountsDoesNotReuseTheOtherReviewersBaseline() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.close() }
        let monitor = fixture.monitor()
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .current)

        fixture.diffReadFails = true
        fixture.glab.currentUsername = "other"
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .needsReview)

        fixture.glab.currentUsername = fixture.target.username
        fixture.userID = 6
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .needsReview)

        fixture.userID = 5
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .current)
    }

    @Test(arguments: ["merged", "closed", "failed"])
    func onlyConfirmedTerminalReadRemovesApprovalBaseline(_ outcome: String) async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.close() }
        await fixture.refresh(fixture.monitor())

        fixture.listed = false
        fixture.state = outcome == "merged" ? "merged" : "closed"
        fixture.requestReadFails = outcome == "failed"
        let cleanup = fixture.monitor()
        await fixture.refresh(cleanup)
        #expect(!cleanup.hasError)
        #expect(fixture.gitlab.requests.filter { $0.endpoint == "/projects/1/merge_requests/2" }.count >= 2)

        fixture.listed = true
        fixture.state = "opened"
        fixture.requestReadFails = false
        fixture.diffReadFails = true
        let reopened = fixture.monitor()
        await fixture.refresh(reopened)
        #expect(reopened.currentOpenItems.first?.reviewingProgress == (outcome == "failed" ? .current : .needsReview))
    }

    @Test func aFailedApprovalReadKeepsTheBaselineUntilWithdrawalIsObserved() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.close() }
        let monitor = fixture.monitor()
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .current)

        fixture.approvalReadFails = true
        await fixture.refresh(monitor)
        fixture.approvalReadFails = false
        fixture.diffReadFails = true
        await fixture.refresh(monitor)
        #expect(monitor.currentOpenItems.first?.reviewingProgress == .current)

        let approvedAt = fixture.approvalTime
        fixture.approvalTime = nil
        await fixture.refresh(monitor)
        fixture.approvalTime = approvedAt
        let restarted = fixture.monitor()
        await fixture.refresh(restarted)
        #expect(restarted.currentOpenItems.first?.reviewingProgress == .needsReview)
    }

    @MainActor
    private final class ApprovalFixture {
        let target = MRAutomationScope.Target.mergeRequest(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let defaults: UserDefaults
        let gitlab = InMemoryGitLab()
        let glab: GlabService
        private let suite = "ReviewingContextTests.\(UUID())"
        private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var head = "abc"
        var branch = "main"
        var base = "base"
        var title = "Example"
        var state = "opened"
        var userID = 5
        var listed = true
        var diffTime = "2026-01-01T11:00:00Z"
        var metadataChange: String?
        var approvalTime: String? = "2026-01-01T12:00:00Z"
        var diffReadFails = false
        var requestReadFails = false
        var approvalReadFails = false

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            glab = gitlab.service(host: target.host, username: target.username)
            gitlab.handler = { [unowned self] command in
                let refs = #", "diff_refs":{"base_sha":"\#(base)","head_sha":"\#(head)","start_sha":"start"}"#
                let mr = #"{"project_id":1,"iid":2,"author":{"id":7,"username":"alice","name":"Alice"},"title":"\#(title)","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"\#(state)","draft":false,"sha":"\#(head)","source_branch":"feature","target_project_id":1,"target_branch":"\#(branch)","labels":[]"#
                let username = glab.currentUsername ?? target.username
                switch command.endpoint {
                case "/user": return InMemoryGitLab.output(#"{"id":\#(userID),"username":"\#(username)"}"#)
                case let path where path.hasPrefix("/merge_requests?"):
                    return InMemoryGitLab.output(!listed || path.contains("created_by_me") ? "[]" : "[\(mr)}]")
                case "/projects/1/merge_requests/2":
                    if requestReadFails { throw GlabError.unknown("MR read failed") }
                    return InMemoryGitLab.output(mr + refs + "}")
                case "/projects/1/merge_requests/2/approvals":
                    if approvalReadFails { throw GlabError.unknown("approval read failed") }
                    let approval = approvalTime.map { #"{"user":{"id":\#(userID),"username":"\#(username)"},"approved_at":"\#($0)"}"# } ?? ""
                    return InMemoryGitLab.output(#"{"project_id":1,"iid":2,"approvals_required":1,"approvals_left":0,"approved_by":[\#(approval)]}"#)
                case "/projects/1/merge_requests/2/versions?per_page=1":
                    if diffReadFails { throw GlabError.unknown("diff read failed") }
                    return InMemoryGitLab.output(#"[{"head_commit_sha":"\#(head)","base_commit_sha":"\#(base)","start_commit_sha":"start","created_at":"\#(diffTime)"}]"#)
                case let path where path.hasPrefix("/projects/1/merge_requests/2/discussions"):
                    if let metadataChange {
                        return InMemoryGitLab.output(#"[{"id":"metadata","notes":[{"id":4,"system":true,"body":"\#(metadataChange)","created_at":"2026-01-02T11:00:00Z"}]}]"#)
                    }
                    return InMemoryGitLab.output("[]")
                default: return InMemoryGitLab.output("[]")
                }
            }
        }

        func monitor() -> MergeRequestAttentionMonitor {
            .init(glab: glab, settings: SettingsManager(defaults: defaults), verdictDirectory: directory,
                  provenanceDirectory: directory, canAutomate: { _ in false })
        }

        func refresh(_ monitor: MergeRequestAttentionMonitor) async {
            await withCheckedContinuation { continuation in
                monitor.onRefreshed = {
                    monitor.onRefreshed = nil
                    continuation.resume()
                }
                monitor.refresh(host: target.host, username: glab.currentUsername ?? target.username, todos: [])
            }
        }

        func close() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func detailsShowOneTaskRowPerKindPreferringRunningThenFailedWork() throws {
        let request = try request()
        func intent(_ kind: MRTodoIntent.Kind, _ state: MRTodoIntent.State) -> MRTodoIntent {
            .init(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
                kind: kind, state: state, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
                headSHA: "abc", updatedAt: Date())
        }
        let pending = intent(.followUp, .pending), running = intent(.followUp, .running)
        let secondRunning = intent(.followUp, .running), failed = intent(.pipeline, .failed)
        let pipelinePending = intent(.pipeline, .pending), done = intent(.conflict, .completed)
        let visible = BoardMRIntentActions.visibleIntents([pending, running, secondRunning, pipelinePending, failed, done])
        #expect(visible.map(\.id) == [running.id, failed.id])
    }

    @Test func aFeaturedFollowUpLeavesOnlyIndependentTaskRows() throws {
        let request = try request()
        func intent(_ kind: MRTodoIntent.Kind, _ state: MRTodoIntent.State) -> MRTodoIntent {
            .init(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
                kind: kind, state: state, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
                headSHA: "abc", updatedAt: .now)
        }
        let failedFollowUp = intent(.followUp, .failed)
        let pendingFollowUp = intent(.followUp, .pending)
        let pendingPipeline = intent(.pipeline, .pending)
        let intents = [pendingFollowUp, failedFollowUp, pendingPipeline]

        #expect(BoardMRIntentActions.visibleIntents(intents).map(\.id) == [failedFollowUp.id, pendingPipeline.id])
        #expect(BoardMRIntentActions.visibleIntents(intents, excluding: failedFollowUp.id).map(\.id) == [pendingPipeline.id])
    }

    @Test(arguments: [false, true])
    func adoptedDraftKeepsOrdinaryManualActionsWithoutStartingAutomaticWork(_ ready: Bool) throws {
        let request = try request(draft: true)
        var item = try item(); item.mergeRequest = request
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .review, state: .pending, todoIDs: [5], noteIDs: [], sourceEvents: [], request: request,
            headSHA: "abc", updatedAt: Date())
        let snapshot = row(item, intents: [intent])
        let context = ReviewingContext(row: snapshot, assistantReady: ready)
        #expect(!snapshot.needsAttention)
        #expect(MRHumanAction(row: snapshot, assistantReady: false) == nil)
        #expect(context.nextStep == (ready ? .runReview : .setupAgent))
        #expect(context.actionLabel != nil)
        #expect(!context.isAutomaticProcessing)
        #expect(context.status == .waitingForReady)
        let automated = ReviewingContext(row: snapshot, workflowState: .queued,
            assistantReady: true, draftAutomationAllowed: true)
        #expect(automated.nextStep == .automaticReview && automated.isAutomaticProcessing)
    }

    @Test func unknownActivityDoesNotInventAFirstReviewOrARecentlyAddedReceipt() throws {
        let item = try item()
        let context = ReviewingContext(row: row(item))
        #expect(context.author?.username == "alice")
        #expect(context.presence == .tracked)
        #expect(context.status == .activityUnknown)
    }

    @Test func sourceRequestExplainsPresenceWithoutConfusingItsActorWithTheMRAuthor() throws {
        let item = try item()
        let todo = try GlabService.decodeTodos(Data(#"[{"id":5,"action_name":"review_requested","target_type":"MergeRequest","target_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","body":"Review","state":"pending","created_at":"2026-01-01T00:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"request-bot","name":"Request Bot"},"target":{"id":10,"iid":2,"title":"Example","state":"opened","draft":false}}]"#.utf8))[0]
        let intent = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
            kind: .review, state: .completed, todoIDs: [5], noteIDs: [], sourceEvents: [], request: try request(),
            headSHA: "abc", updatedAt: Date(), sourceTodo: todo)
        let context = ReviewingContext(row: row(item, intents: [intent]))
        #expect(context.author?.username == "alice")
        #expect(context.presence == .reviewRequested("request-bot"))
    }

    @Test func authorRepliesCountOnlyAfterOurLastCommentInTheSameThread() throws {
        let discussions: [GitLabMergeRequestDiscussion] = [
            .init(id: "our-thread", notes: [note(10, user: 3), note(11, user: 7)]),
            .init(id: "we-answered", notes: [note(20, user: 3), note(21, user: 7), note(22, user: 3)]),
            .init(id: "others-thread", notes: [note(30, user: 9), note(31, user: 7)]),
            .init(id: "system", notes: [note(40, user: 3), note(41, user: 7, system: true)])
        ]
        let activity = ReviewingActivity(discussions: discussions, reviewerID: 3, authorID: 7)
        #expect(activity.publishedCommentCount == 4)
        #expect(activity.openThreadCount == 3)
        #expect(activity.authorReplyCount == 1)
        #expect(activity.otherReplyCount == 0)
        #expect(activity.isComplete)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .authorReplied(1))
    }

    @Test func anotherReviewersReplyDoesNotBecomeAnAuthorReply() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [note(10, user: 3), note(11, user: 9)])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0 && activity.otherReplyCount == 1)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .otherReplied(1))
    }

    @Test func resolvedOwnCommentsAreStillRecordedWithoutAnOpenThread() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [note(10, user: 3, resolved: true)])], reviewerID: 3, authorID: 7)
        #expect(activity.publishedCommentCount == 1 && activity.openThreadCount == 0)
        var item = try item(); item.reviewingActivity = activity
        let original = row(item, humanAttention: false)
        #expect(ReviewingContext(row: original).status == .commented(1))
        #expect(!original.needsAttention)
    }

    @Test func malformedEvidenceDoesNotClaimWeHaveNeverCommented() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "incomplete", notes: [note(nil, user: nil)])], reviewerID: 3, authorID: 7)
        #expect(!activity.isComplete)
        var item = try item(); item.reviewingActivity = activity
        #expect(ReviewingContext(row: row(item)).status == .activityUnknown)
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        #expect(ReviewingContext(row: row(item)).status == .noPublishedComments)
    }

    @Test func pendingDraftsAndActiveRunsExplainCurrentProgress() throws {
        var item = try item(); item.drafts = attentionFixtureDrafts(2)
        #expect(ReviewingContext(row: row(item)).status == .drafts(2))
        #expect(ReviewingContext(row: row(item, job: reviewJob(.running))).status == .running)
        item.drafts = []
        #expect(ReviewingContext(row: row(item, job: reviewJob(.succeeded))).status == .reviewCompleted)
    }

    @Test(arguments: [AssistantJobExecution.State.running, .succeeded, .failed], [false, true])
    func pipelineDiagnosisKeepsPipelineProgressWithoutClaimingReviewActivity(
        _ state: AssistantJobExecution.State, legacy: Bool
    ) throws {
        var job = reviewJob(state)
        if legacy {
            job.taskPrompt = "Diagnose this MR's failed pipeline and prepare an in-scope verified fix.\nFocus on these GitLab note IDs: "
        } else {
            job.taskIntent = .pipelineDiagnosis
        }
        let snapshot = row(try item(), job: job)
        let context = ReviewingContext(row: snapshot)

        #expect(context.status == .activityUnknown)
        #expect(context.nextStep == .viewDiscussions)
        if state == .running {
            let card = MRCardPresentation(row: snapshot, reviewingContext: context, allowsRemoval: true, assistantReady: true)
            #expect(card.working)
            #expect(card.activity?.jobID == job.id)
            #expect(card.status == MRActivity.agentStatus(.AutomationProgress.progressPipeline, assistant: job.key.assistant))
        }
    }

    @Test func incompleteThreadCannotInventAnUnansweredReply() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [
            note(10, user: 3), note(11, user: 7), note(nil, user: 3)
        ])], reviewerID: 3, authorID: 7)
        #expect(!activity.isComplete)
        #expect(activity.authorReplyCount == 0 && activity.otherReplyCount == 0)
        #expect(activity.publishedCommentCount == 1)
    }

    @Test func requestIdentityMustMatchBeforeShowingItsAuthor() throws {
        let request = try request()
        let wrongItem = MergeRequestAttentionMonitor.Item(id: .init(projectID: 9, iid: 2),
            title: request.title, url: request.webURL, mergeRequest: request)
        #expect(ReviewingContext(row: row(wrongItem)).author == nil)
    }

    @Test func nonReviewJobDoesNotClaimAReviewWasCompleted() throws {
        var job = reviewJob(.succeeded)
        job.workflow = nil
        #expect(ReviewingContext(row: row(try item(), job: job)).status == .activityUnknown)
    }

    @Test func replyOrderUsesNoteIdentityRatherThanResponseArrayOrder() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "thread", notes: [
            note(30, user: 3, resolved: true), note(20, user: 7), note(10, user: 3, resolved: true)
        ])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0)
        #expect(activity.publishedCommentCount == 2)
    }

    @Test func resolvedHistoricalAuthorRepliesDoNotLookLikePendingReviewWork() throws {
        let activity = ReviewingActivity(discussions: [.init(id: "closed", notes: [
            note(10, user: 3, resolved: true), note(11, user: 7, resolved: true)
        ])], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0)
        var item = try item(); item.reviewingActivity = activity
        let snapshot = row(item, humanAttention: false)
        let context = ReviewingContext(row: snapshot)
        #expect(context.status == .commented(1))
        #expect(context.nextStep == .monitoring)
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
        #expect(!snapshot.needsAttention)
    }

    @Test func untouchedOtherReviewersThreadsAreNotOurPendingAuthorReplies() throws {
        let activity = ReviewingActivity(discussions: [
            .init(id: "ours", notes: [note(10, user: 3, resolved: true), note(11, user: 7, resolved: true)]),
            .init(id: "other", notes: [note(20, user: 9)])
        ], reviewerID: 3, authorID: 7)
        #expect(activity.authorReplyCount == 0 && activity.openThreadCount == 0)
        #expect(activity.otherOpenThreadCount == 1)
    }

    @Test func openThreadStatusNamesUniqueRootAuthorsAndExcludesRepliesAndClosedThreads() throws {
        var item = try item()
        item.reviewingProgress = .waitingForOtherDiscussions
        let ownReply = GitLabMergeRequestDiscussion.Note(id: 31,
            author: .init(id: 3, username: "sam", name: "Sam", avatarURL: nil),
            system: false, resolvable: false, resolved: nil, resolvedBy: nil)
        item.reviewingActivity = ReviewingActivity(discussions: [
            .init(notes: [note(9, user: 8, system: true), note(10, user: 9), note(11, user: 7)]),
            .init(notes: [note(20, user: 9)]),
            .init(notes: [note(30, user: 10), ownReply]),
            .init(notes: [note(40, user: 11)]),
            .init(notes: [note(50, user: 12, resolved: true)]),
            .init(notes: [note(60, user: 3)])
        ], reviewerID: 3, authorID: 7)
        let context = ReviewingContext(row: row(item))
        #expect(context.status == .waitingForOtherDiscussions)
        #expect(context.statusPeopleMessage?.people.map(\.username) == ["user9", "user10"])
        #expect(context.statusPeopleMessage?.text == "Open review threads from @user9, @user10 and 1 other")
    }

    @Test(arguments: [1, 2])
    func openThreadAuthorsReachThePhoneWithTheirProfile(_ threads: Int) throws {
        var item = try item()
        let avatar = try #require(URL(string: "https://gitlab.example.test/avatar/sam.png"))
        let root = GitLabMergeRequestDiscussion.Note(id: 10,
            author: .init(id: 3, username: "sam", name: "Sam Reviewer", avatarURL: avatar),
            system: false, resolvable: true, resolved: false, resolvedBy: nil)
        item.reviewingProgress = .current
        item.reviewingActivity = ReviewingActivity(discussions: Array(repeating: .init(notes: [root]), count: threads),
            reviewerID: 3, authorID: 7)
        let snapshot = row(item)
        let model = MRCardPresentation(row: snapshot, reviewingContext: ReviewingContext(row: snapshot),
            allowsRemoval: true, assistantReady: true)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "sam@host"), model: model)
        let expected = threads == 1 ? "Open review thread from Sam Reviewer" : "Open review threads from Sam Reviewer"
        #expect(model.status == expected)
        #expect(phone.presentation?.status == expected)
        #expect(phone.presentation?.statusPeopleMessage?.people == [.init(name: "Sam Reviewer", username: "sam", avatarURL: avatar)])
    }

    @Test func openThreadStatusKeepsItsCountWhenAThreadAuthorIsMissing() throws {
        var item = try item()
        item.reviewingProgress = .current
        item.reviewingActivity = ReviewingActivity(discussions: [
            .init(notes: [note(10, user: nil), note(11, user: 3)])
        ], reviewerID: 3, authorID: 7)
        let context = ReviewingContext(row: row(item))
        #expect(context.statusPeopleMessage == nil)
        #expect(String(localized: context.statusMessage) == "1 open review thread")
    }

    @Test func runningReviewIntentOfAFinishedRunDoesNotKeepTheCardPreparing() throws {
        let request = try request()
        func intent(_ jobID: UUID?) -> MRTodoIntent {
            var value = MRTodoIntent(id: UUID(), target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2),
                kind: .review, state: .running, todoIDs: [], noteIDs: [], sourceEvents: [], request: request,
                headSHA: "abc", updatedAt: Date())
            value.jobID = jobID
            return value
        }
        let stale = intent(UUID())
        #expect(ReviewingContext(row: row(try item(), job: reviewJob(.succeeded), intents: [stale])).nextStep != .automaticReview)
        #expect(ReviewingContext(row: row(try item(), job: reviewJob(.running), intents: [stale])).nextStep == .automaticReview)
        #expect(ReviewingContext(row: row(try item(), intents: [stale])).nextStep == .automaticReview)
    }

    @Test func aKnownEmptyReviewHasAnExplicitManualAction() throws {
        var item = try item()
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        let context = ReviewingContext(row: row(item))
        #expect(context.nextStep == .runReview)
        #expect(String(localized: try #require(context.actionLabel)) == "Run review")
    }

    @Test(arguments: [MergeWorkflowActivityState.queued, .running, .waitingForAssistant])
    func queuedAutomaticReviewDoesNotAskForASecondManualRun(_ state: MergeWorkflowActivityState) throws {
        var item = try item()
        item.reviewingActivity = ReviewingActivity(discussions: [], reviewerID: 3, authorID: 7)
        let context = ReviewingContext(row: row(item, humanAttention: false), workflowState: state)
        #expect(context.nextStep == .automaticReview)
        #expect(context.actionLabel == nil)
    }

    @Test func automaticallyHandledDraftsDoNotAskForManualReviewComments() throws {
        var item = try item(); item.drafts = attentionFixtureDrafts(2)
        let context = ReviewingContext(row: row(item, humanAttention: false))
        #expect(context.nextStep == .automaticReview)
        #expect(context.actionLabel == nil)
    }

    @Test func staleSucceededJobIsNotProofOfAReviewOfTheCurrentHead() throws {
        var job = reviewJob(.succeeded); job.expectedHeadSHA = "old-head"
        let context = ReviewingContext(row: row(try item(), job: job))
        #expect(context.status != .reviewCompleted)
    }

    @Test func actualVerificationShowsProgressWithoutAskingForManualReview() throws {
        var item = try item(); item.reReviewReadiness = .checking
        let context = ReviewingContext(row: row(item))
        #expect(context.nextStep == .verifying)
        #expect(context.actionLabel == nil)
    }

    @Test func workflowProgressIgnoresOtherWorkflowsAndOlderHeads() throws {
        func entry(_ state: MergeWorkflowActivityState, head: String, kind: MergeWorkflowTrigger,
                   createdAt: Double) throws -> MergeWorkflowActivityEntry {
            var snapshot = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
            snapshot["sha"] = head
            let value: [String: Any] = [
                "id": "event-\(createdAt)", "createdAt": createdAt, "host": "gitlab.example.test",
                "user": ["id": 3, "username": "me"], "state": state.rawValue,
                "event": ["kind": kind.rawValue, "mergeRequest": snapshot, "identity": "event-\(createdAt)", "context": "Review update", "isInfrastructureFailure": false, "noteIDs": []]
            ]
            return try JSONDecoder().decode(MergeWorkflowActivityEntry.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let current = try entry(.queued, head: "abc", kind: .reviewUpdate, createdAt: 1)
        let obsolete = try entry(.failed, head: "old", kind: .reviewUpdate, createdAt: 9)
        let unrelated = try entry(.running, head: "abc", kind: .newDiscussion, createdAt: 10)
        let snapshot = row(try item())
        #expect(ReviewingContext.workflowState(for: snapshot, entries: [obsolete, unrelated, current]) == .queued)
        #expect(ReviewingContext.workflowState(for: snapshot, entries: [obsolete, unrelated]) == nil)
    }

    @Test func missingCurrentReviewEvidenceExposesAReviewActionUnlessAlreadyQueued() throws {
        var item = try item(); item.reviewingProgress = .needsReview
        let snapshot = row(item)
        #expect(ReviewingContext(row: snapshot).nextStep == .runReview)
        #expect(ReviewingContext(row: snapshot, workflowState: .queued).nextStep == .automaticReview)
    }

    @Test func waitingForOtherReviewThreadsIsReadOnlyAndDoesNotInventApproval() throws {
        var item = try item(); item.reviewingProgress = .waitingForOtherDiscussions
        let snapshot = row(item, humanAttention: false)
        let context = ReviewingContext(row: snapshot)
        #expect(context.nextStep == .monitoring)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Waiting for other review threads to be resolved.")
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
        #expect(!snapshot.needsAttention && !item.canApprove && !item.autoApproveReady)
    }

    @Test func freshReviewEvidenceSupersedesAnOlderFailedWorkflow() throws {
        var item = try item(); item.reviewingProgress = .current
        let context = ReviewingContext(row: row(item, humanAttention: false), workflowState: .failed, assistantReady: false)
        #expect(context.status == .reviewCompleted)
        #expect(context.nextStep == .monitoring)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Watching for updates.")
        #expect(context.actionLabel == nil)
    }

    @Test(arguments: [false, true])
    func completedReviewKeepsItsSummaryInDetailsWithoutACardAction(_ openThread: Bool) throws {
        var item = try item()
        item.reviewingProgress = .current
        item.approvalProgress = .init(completed: 2, required: 2, approvedBy: [
            .init(id: 3, username: "user3", name: "Reviewer", avatarURL: nil),
            .init(id: 4, username: "user4", name: "Other reviewer", avatarURL: nil)
        ])
        let discussions: [GitLabMergeRequestDiscussion] = openThread
            ? [.init(id: "thread", notes: [note(1, user: 3)])] : []
        item.reviewingActivity = ReviewingActivity(discussions: discussions, reviewerID: 3, authorID: 7)
        let snapshot = row(item, humanAttention: false)
        let model = MRCardPresentation(row: snapshot, reviewingContext: ReviewingContext(row: snapshot, viewerUsername: "user3"),
            allowsRemoval: true, assistantReady: true)

        #expect(model.status == (openThread ? "Open review thread from @user3" : "Review run completed"))
        #expect(model.nextStep == (openThread ? "No action needed. Waiting for updates to your review threads."
            : "No action needed. Watching for updates."))
        #expect(model.actionLabel.map { String(localized: $0) } == (openThread ? "View discussions" : nil))
        #expect(model.cardNeutralStatus.map { String(localized: $0) } == (openThread ? model.status : nil))
        #expect(model.cardNextStep == (openThread ? model.nextStep : nil))

        let projected = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "me@host"), model: model)
        let phone = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(projected))
        #expect(phone.visibleStatus == model.status)
        #expect(phone.visibleNextStep == model.nextStep)
        #expect(phone.boardStatus == (openThread ? model.status : nil))
        #expect(phone.boardNextStep == model.cardNextStep)
        #expect(phone.primaryCTA?.destination == (openThread ? .discussions : nil))
    }

    @Test func completedReviewShowsAnotherReviewersBlockingThreadOnBothBoards() throws {
        var item = try item()
        item.mergeRequest = try request(discussionsResolved: false)
        item.approvalProgress = .init(completed: 0, required: 2)
        item.reviewingProgress = .current
        item.reviewingActivity = .init(discussions: [.init(id: "thread", notes: [note(1, user: 4)])],
            reviewerID: 3, authorID: 7)
        let snapshot = row(item)
        let model = MRCardPresentation(row: snapshot, reviewingContext: ReviewingContext(row: snapshot),
            allowsRemoval: true, assistantReady: true)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "user3@host"), model: model)

        #expect(model.cardNeutralStatus.map { String(localized: $0) } == "Open review thread from @user4")
        #expect(model.cardNextStep == "No action needed. Waiting for other review threads to be resolved.")
        #expect(phone.boardStatus == model.status)
        #expect(phone.boardNextStep == model.cardNextStep)
        #expect(phone.primaryCTA?.destination == .discussions)
        #expect(phone.needsAttention == false)
    }

    @Test(arguments: [false, true])
    func completedReviewKeepsPendingApprovalVisible(_ viewerApproved: Bool) throws {
        var item = try item()
        item.reviewingProgress = .current
        let approvers: [Todo.Author] = viewerApproved ? [
            .init(id: 3, username: "user3", name: "Reviewer", avatarURL: nil)
        ] : [
            .init(id: 4, username: "user4", name: "First reviewer", avatarURL: nil),
            .init(id: 5, username: "user5", name: "Second reviewer", avatarURL: nil)
        ]
        item.approvalProgress = .init(completed: approvers.count, required: 2, approvedBy: approvers)
        let snapshot = row(item)
        let model = MRCardPresentation(row: snapshot, reviewingContext: ReviewingContext(row: snapshot, viewerUsername: "user3"),
            allowsRemoval: true, assistantReady: true)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(item, account: "user3@host"), model: model)

        #expect(model.cardNeutralStatus.map { String(localized: $0) } == "Review run completed")
        #expect(model.cardNextStep == (viewerApproved ? "Waiting for required approvals."
            : "You haven’t approved this revision."))
        #expect(phone.boardStatus == model.status)
        #expect(phone.boardNextStep == model.cardNextStep)
    }

    @Test func freshWaitingForOtherThreadsSupersedesAnOlderFailedWorkflow() throws {
        var item = try item(); item.reviewingProgress = .waitingForOtherDiscussions
        let context = ReviewingContext(row: row(item, humanAttention: false), workflowState: .failed, assistantReady: false)
        #expect(context.status == .waitingForOtherDiscussions)
        #expect(context.nextStep == .monitoring)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: context.nextStepMessage) == "No action needed. Waiting for other review threads to be resolved.")
        #expect(String(localized: try #require(context.actionLabel)) == "View discussions")
    }

    @Test func missingCLICannotPretendAQueuedReviewIsBeingHandled() throws {
        let context = ReviewingContext(row: row(try item()), workflowState: .waitingForAssistant,
            assistantReady: false, assistantChecking: false)
        #expect(context.nextStep == .setupAgent)
        #expect(!context.isAutomaticProcessing)
        #expect(String(localized: try #require(context.actionLabel)) == "Open settings")
    }

    @Test func aPendingDependencyCheckKeepsActualQueuedWorkNeutral() throws {
        let context = ReviewingContext(row: row(try item()), workflowState: .queued,
            assistantReady: false, assistantChecking: true)
        #expect(context.nextStep == .automaticReview && context.isAutomaticProcessing)
        #expect(context.actionLabel == nil)
    }

}
