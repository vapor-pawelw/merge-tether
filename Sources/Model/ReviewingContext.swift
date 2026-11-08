import Foundation

/// Read-only participation facts, computed from a complete GitLab discussion response.
struct ReviewingActivity: Equatable, Sendable {
    var publishedCommentCount = 0
    var openThreadCount = 0
    var authorReplyCount = 0
    var otherReplyCount = 0
    var isComplete = false
    var otherOpenThreadCount = 0

    init(discussions: [GitLabMergeRequestDiscussion], reviewerID: Int, authorID: Int) {
        guard reviewerID > 0, authorID > 0 else { return }
        isComplete = true
        for discussion in discussions {
            let notes = discussion.notes.filter { $0.system != true }
            let complete = notes.allSatisfy { ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 }
            if !complete { isComplete = false }
            let own = notes.filter { $0.author?.id == reviewerID && ($0.id ?? 0) > 0 }
            publishedCommentCount += own.count
            if own.contains(where: { $0.resolvable == true && $0.resolved == false }) {
                openThreadCount += 1
            }
            if own.isEmpty && notes.contains(where: { $0.resolvable == true && $0.resolved == false }) {
                otherOpenThreadCount += 1
            }
            let resolvable = notes.filter { $0.resolvable == true }
            let resolved = !resolvable.isEmpty && resolvable.allSatisfy { $0.resolved == true }
            // Closed threads are history, even when the author wrote the last note.
            if resolved { continue }
            // A missing identity or note ID could hide our later answer. Do not
            // classify that thread as awaiting us from partial evidence.
            guard complete, let lastOwnID = own.compactMap(\.id).max() else { continue }
            let replies = notes.filter { ($0.id ?? 0) > lastOwnID && $0.author?.id != reviewerID }
            if replies.contains(where: { $0.author?.id == authorID }) { authorReplyCount += 1 }
            else if !replies.isEmpty { otherReplyCount += 1 }
        }
    }
}

/// Read-only workflow progress; a current review is not merge approval.
enum ReviewingProgress: Equatable, Sendable {
    case needsReview, queued, checking, waitingForOtherDiscussions, current
}

/// Read-only review progress and next steps; this never authorizes an MR action.
@MainActor
struct ReviewingContext {
    enum Presence: Equatable { case tracked, reviewRequested(String?), approvalRequested(String?) }
    enum Status: Equatable {
        case activityUnknown, drafts(Int), running, authorReplied(Int), otherReplied(Int)
        case openThreads(Int), commented(Int), reviewCompleted, noPublishedComments
        case queued, verifying, reviewNeeded, waitingForOtherDiscussions, waitingForReady
    }
    enum NextStep: Equatable {
        case monitoring, runReview, viewDiscussions, reviewComments, automaticReview, verifying, viewRun, setupAgent
    }
    private(set) var nextStep: NextStep = .viewDiscussions
    var isAutomaticProcessing: Bool { nextStep == .automaticReview || nextStep == .verifying }
    var nextStepMessage: LocalizedStringResource {
        switch nextStep {
        case .automaticReview: .ReviewingContext.reviewingAutomatic
        case .verifying: .ReviewingContext.reviewingVerificationAutomatic
        case .setupAgent: .ReviewingContext.reviewingSetupRequired
        case .runReview: .ReviewingContext.reviewingRunNeeded
        case .reviewComments: .ReviewingContext.reviewingDraftsNeedReview
        case .viewRun: .ReviewingContext.reviewingRunNeedsInput
        case .viewDiscussions: .ReviewingContext.reviewingInspectDiscussions
        case .monitoring:
            if status == .waitingForReady { .ReviewingContext.reviewingWaitingReadyMessage }
            else if status == .waitingForOtherDiscussions { .ReviewingContext.reviewingWaitingOtherThreads }
            else if case .openThreads = status { .ReviewingContext.reviewingWaitingAuthor }
            else { .ReviewingContext.reviewingMonitoring }
        }
    }
    var actionLabel: LocalizedStringResource? {
        switch nextStep {
        case .automaticReview, .verifying: nil
        case .monitoring: status == .waitingForReady ? nil : .ReviewingContext.reviewingViewDiscussions
        case .viewDiscussions: .ReviewingContext.reviewingViewDiscussions
        case .runReview: .CommandCenter.commandCenterReviewRun
        case .reviewComments: .MRHumanAction.mrHumanActionActionReviewDrafts
        case .viewRun: .MRHumanAction.mrHumanActionActionReviewRun
        case .setupAgent: .MRHumanAction.mrHumanActionActionSetupAssistant
        }
    }

    /// Callers provide entries for the signed-in account. Only the current MR
    /// and head's review workflow can explain work on this card.
    static func workflowState(for row: MergeRequestBoardSnapshot.Row,
                              entries: [MergeWorkflowActivityEntry]) -> MergeWorkflowActivityState? {
        guard let request = row.item.mergeRequest, let head = request.sha, !head.isEmpty else { return nil }
        return entries.filter {
            let candidate = $0.event.mergeRequest
            return $0.event.kind == .reviewUpdate && candidate.projectID == row.id.projectID
                && candidate.iid == row.id.iid && candidate.webURL == row.item.url
                && candidate.sha == head
        }.max { $0.createdAt < $1.createdAt }?.state
    }

    var author: Todo.Author?
    var presence: Presence = .tracked
    var status: Status = .activityUnknown

    init(row: MergeRequestBoardSnapshot.Row, workflowState: MergeWorkflowActivityState? = nil,
         assistantReady: Bool = true, assistantChecking: Bool = false,
         draftAutomationAllowed: Bool = false) {
        let item = row.item
        if let request = item.mergeRequest, request.projectID == item.id.projectID,
           request.iid == item.id.iid, request.webURL == item.url,
           let host = item.url.host, item.url.isGitLabMergeRequest(host: host, iid: item.id.iid),
           request.author.id > 0, !request.author.username.isEmpty {
            author = request.author
        }
        let source = row.intents.sorted { $0.updatedAt > $1.updatedAt }.first { intent in
            guard intent.kind == .review, intent.target.projectID == item.id.projectID,
                  intent.target.iid == item.id.iid,
                  item.url.isGitLabMergeRequest(host: intent.target.host, iid: item.id.iid),
                  let todo = intent.sourceTodo,
                  todo.project.id == item.id.projectID, todo.target.iid == item.id.iid,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: intent.target.host, iid: item.id.iid) == item.url
            else { return false }
            return todo.actionName == .reviewRequested || todo.actionName == .approvalRequired
        }?.sourceTodo
        if let source {
            let username = source.author.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let actor = username.isEmpty ? nil : username
            presence = source.actionName == .approvalRequired ? .approvalRequested(actor) : .reviewRequested(actor)
        }
        let review = row.latestJob.flatMap { $0.workflow == .review || $0.reviewModel != nil ? $0 : nil }
        let currentReview = review.flatMap { run in
            run.expectedHeadSHA != nil && run.expectedHeadSHA == item.mergeRequest?.sha ? run : nil
        }
        let activity = item.reviewingActivity
        let drafts = max(item.draftCount, item.drafts.count)
        if review?.execution?.state.isActive == true { status = .running }
        else if drafts > 0 { status = .drafts(drafts) }
        else if let activity {
            if activity.authorReplyCount > 0 { status = .authorReplied(activity.authorReplyCount) }
            else if activity.otherReplyCount > 0 { status = .otherReplied(activity.otherReplyCount) }
            else if activity.openThreadCount > 0 { status = .openThreads(activity.openThreadCount) }
            else if activity.publishedCommentCount > 0 { status = .commented(activity.publishedCommentCount) }
            else if currentReview?.execution?.state == .succeeded { status = .reviewCompleted }
            else if activity.isComplete { status = .noPublishedComments }
        } else if currentReview?.execution?.state == .succeeded { status = .reviewCompleted }

        let automaticIntent = row.intents.contains {
            $0.kind == .review && $0.headSHA == item.mergeRequest?.sha
                && ($0.state == .running || ($0.state == .pending && item.humanActionRequired == false))
        }
        let queued = workflowState == .queued || workflowState == .running || workflowState == .waitingForAssistant
            || automaticIntent || item.reviewingProgress == .queued
        let checking = item.reReviewReadiness == .checking || item.authorFeedbackStatus?.phase == .checking
            || item.reviewingProgress == .checking
        let deferredReview = item.mergeRequest?.draft == true && !draftAutomationAllowed
            && row.intents.contains(where: \.isDeferredReview)
        func readyAction(_ action: NextStep) -> NextStep {
            assistantReady || assistantChecking ? action : .setupAgent
        }
        if review?.execution?.state.isActive == true {
            nextStep = .automaticReview
        } else if deferredReview, drafts == 0, !MergeRequestBoardSnapshot.Row.jobNeedsAttention(currentReview?.execution?.state) {
            status = .waitingForReady
            nextStep = readyAction(.runReview)
        } else if queued {
            status = workflowState == .running ? .running : .queued
            nextStep = readyAction(.automaticReview)
        } else if checking {
            status = .verifying
            nextStep = readyAction(.verifying)
        } else if drafts > 0 {
            nextStep = item.humanActionRequired == false ? readyAction(.automaticReview) : .reviewComments
        } else if MergeRequestBoardSnapshot.Row.jobNeedsAttention(currentReview?.execution?.state) {
            nextStep = .viewRun
        } else if item.reviewingProgress == .needsReview {
            status = .reviewNeeded
            nextStep = readyAction(.runReview)
        } else if item.reviewingProgress == .waitingForOtherDiscussions {
            status = .waitingForOtherDiscussions
            nextStep = .monitoring
        } else if item.reviewingProgress == .current {
            if let activity, activity.openThreadCount > 0 { status = .openThreads(activity.openThreadCount) }
            else { status = .reviewCompleted }
            nextStep = .monitoring
        } else if workflowState == .failed {
            nextStep = readyAction(.runReview)
        } else if (activity?.authorReplyCount ?? 0) > 0 || (activity?.otherReplyCount ?? 0) > 0 {
            nextStep = .viewDiscussions
        } else if (activity?.publishedCommentCount ?? 0) > 0 || currentReview?.execution?.state == .succeeded {
            nextStep = .monitoring
        } else if activity?.isComplete == true {
            nextStep = readyAction(.runReview)
        }

    }

    var presenceMessage: LocalizedStringResource {
        switch presence {
        case .tracked: .ReviewingContext.reviewingTracked
        case .reviewRequested(let username):
            if let username { .ReviewingContext.reviewingReviewRequestedBy(username) }
            else { .ReviewingContext.reviewingReviewRequested }
        case .approvalRequested(let username):
            if let username { .ReviewingContext.reviewingApprovalRequestedBy(username) }
            else { .ReviewingContext.reviewingApprovalRequested }
        }
    }

    var statusMessage: LocalizedStringResource {
        switch status {
        case .activityUnknown: .ReviewingContext.reviewingActivityUnknown
        case .drafts(let count): .ReviewingContext.reviewingDrafts(count)
        case .running: .ReviewingContext.reviewingRunning
        case .authorReplied(let count): .ReviewingContext.reviewingAuthorReplied(count)
        case .otherReplied(let count): .ReviewingContext.reviewingOtherReplied(count)
        case .openThreads(let count): .ReviewingContext.reviewingOpenThreads(count)
        case .commented(let count): .ReviewingContext.reviewingCommented(count)
        case .reviewCompleted: .ReviewingContext.reviewingReviewCompleted
        case .noPublishedComments: .ReviewingContext.reviewingNoPublishedComments
        case .queued: .ReviewingContext.reviewingQueued
        case .verifying: .ReviewingContext.reviewingVerifying
        case .reviewNeeded: .ReviewingContext.reviewingReviewNeeded
        case .waitingForOtherDiscussions: .ReviewingContext.reviewingOtherThreadsOpen
        case .waitingForReady: .ReviewingContext.reviewingWaitingReady
        }
    }
}
