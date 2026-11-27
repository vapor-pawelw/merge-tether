import Foundation
import MergeTetherRemote

/// Read-only participation facts, computed from a complete GitLab discussion response.
struct ReviewingActivity: Equatable, Sendable {
    var publishedCommentCount = 0
    var openThreadCount = 0
    var authorReplyCount = 0
    var otherReplyCount = 0
    var isComplete = false
    var otherOpenThreadCount = 0
    private(set) var openThreadPeople: [PersonIdentity] = []
    private(set) var otherOpenThreadPeople: [PersonIdentity] = []
    private(set) var otherReplyPeople: [PersonIdentity] = []

    init(discussions: [GitLabMergeRequestDiscussion], reviewerID: Int, authorID: Int) {
        guard reviewerID > 0, authorID > 0 else { return }
        isComplete = true
        var openThreadAuthors: [GitLabWorkflowUser?] = []
        var otherOpenThreadAuthors: [GitLabWorkflowUser?] = []
        var otherReplyAuthors: [GitLabWorkflowUser?] = []
        for discussion in discussions {
            let notes = discussion.notes.filter { $0.system != true }
            let complete = notes.allSatisfy { ($0.id ?? 0) > 0 && ($0.author?.id ?? 0) > 0 }
            if !complete { isComplete = false }
            let own = notes.filter { $0.author?.id == reviewerID && ($0.id ?? 0) > 0 }
            publishedCommentCount += own.count
            let isOpen: (GitLabMergeRequestDiscussion.Note) -> Bool = { $0.resolvable == true && $0.resolved == false }
            if own.contains(where: isOpen) {
                openThreadCount += 1
                openThreadAuthors.append(discussion.reviewRoot?.author)
            } else if notes.contains(where: isOpen) {
                otherOpenThreadCount += 1
                otherOpenThreadAuthors.append(discussion.reviewRoot?.author)
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
            else if !replies.isEmpty {
                otherReplyCount += 1
                otherReplyAuthors.append(contentsOf: replies.map(\.author))
            }
        }
        openThreadPeople = Self.uniquePeople(openThreadAuthors)
        otherOpenThreadPeople = Self.uniquePeople(otherOpenThreadAuthors)
        otherReplyPeople = Self.uniquePeople(otherReplyAuthors)
    }

    private static func uniquePeople(_ users: [GitLabWorkflowUser?]) -> [PersonIdentity] {
        var seen: Set<Int> = []
        var people: [PersonIdentity] = []
        for user in users {
            guard let user, user.id > 0, user.person.normalizedUsername != nil else { return [] }
            if seen.insert(user.id).inserted { people.append(user.person) }
        }
        return people
    }
}

/// Read-only workflow progress; a current review is not merge approval.
enum ReviewingProgress: Equatable, Sendable {
    case needsReview, queued, checking, waitingForOtherDiscussions, current
}

struct ReviewingAssessment: Equatable, Sendable {
    let progress: ReviewingProgress
    var reasons: [ReviewLaunchReason] = []
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
    private enum CompletedReviewApproval {
        case unknown, waitingForViewer, waitingForRequired, complete
    }
    private(set) var nextStep: NextStep = .viewDiscussions
    private(set) var reviewReasons: [ReviewLaunchReason] = []
    var isAutomaticProcessing: Bool { nextStep == .automaticReview || nextStep == .verifying }
    var isMonitoringCompletedReview: Bool { status == .reviewCompleted && nextStep == .monitoring }
    var hasCompletedApprovals: Bool { completedReviewApproval == .complete }
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
            else if completedReviewApproval == .waitingForViewer { .ReviewingContext.reviewingViewerApprovalPending }
            else if completedReviewApproval == .waitingForRequired { .ReviewingContext.reviewingRequiredApprovalsPending }
            else { .ReviewingContext.reviewingMonitoring }
        }
    }
    var actionLabel: LocalizedStringResource? {
        switch nextStep {
        case .automaticReview, .verifying: nil
        case .monitoring: status == .waitingForReady || isMonitoringCompletedReview ? nil : .ReviewingContext.reviewingViewDiscussions
        case .viewDiscussions: .ReviewingContext.reviewingViewDiscussions
        case .runReview: .CommandCenter.commandCenterReviewRun
        case .reviewComments: .MRHumanAction.mrHumanActionActionReviewDrafts
        case .viewRun: .MRHumanAction.mrHumanActionActionReviewRun
        case .setupAgent: .MRHumanAction.mrHumanActionActionSetupAssistant
        }
    }

    /// Callers provide entries for the signed-in account. Only the current MR
    /// and head's review workflow can explain work on this card.
    static func reviewWorkflow(for row: MergeRequestBoardSnapshot.Row,
                               entries: [MergeWorkflowActivityEntry]) -> MergeWorkflowActivityEntry? {
        guard let request = row.item.mergeRequest, let head = request.sha, !head.isEmpty else { return nil }
        return entries.filter {
            let candidate = $0.event.mergeRequest
            return $0.event.kind == .reviewUpdate && candidate.projectID == row.id.projectID
                && candidate.iid == row.id.iid && candidate.webURL == row.item.url
                && candidate.sha == head
        }.max { $0.createdAt < $1.createdAt }
    }

    var author: Todo.Author?
    var presence: Presence = .tracked
    var status: Status = .activityUnknown
    private let presenceActor: PersonIdentity?
    private let activity: ReviewingActivity?
    private var completedReviewApproval: CompletedReviewApproval = .unknown

    init(row: MergeRequestBoardSnapshot.Row, workflowState: MergeWorkflowActivityState? = nil,
         workflowReasons: [ReviewLaunchReason] = [],
         assistantReady: Bool = true, assistantChecking: Bool = false,
         draftAutomationAllowed: Bool = false, viewerUsername: String? = nil) {
        let item = row.presented
        if let request = row.displayRequest, request.projectID == item.id.projectID,
           request.iid == item.id.iid, request.webURL == row.displayURL,
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
        presenceActor = source?.author.person
        let review = row.latestJob.flatMap { AssistantAutomationRunner.recordsReviewVerdict(for: $0) ? $0 : nil }
        let currentReview = review.flatMap { run in
            run.expectedHeadSHA != nil && run.expectedHeadSHA == item.mergeRequest?.sha ? run : nil
        }
        let activity = row.evidenceMatchesCatalogContext ? item.reviewingActivity : nil
        self.activity = activity
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

        // A running intent whose worker already finished (latest run is terminal) is stale bookkeeping,
        // e.g. a run cancelled by policy; it must not keep the card in "Preparing review" forever.
        let latestRunFinished = row.latestJob?.operationalExecution?.state.isActive == false
        let automaticIntent = row.intents.first {
            $0.kind == .review && $0.headSHA == item.mergeRequest?.sha
                && (($0.state == .running && !($0.jobID != nil && latestRunFinished))
                    || ($0.state == .pending && item.humanActionRequired == false))
        }
        let queuedWorkflow = workflowState == .queued || workflowState == .running || workflowState == .waitingForAssistant
        let queued = queuedWorkflow || automaticIntent != nil || item.reviewingProgress == .queued
        let checking = item.reReviewReadiness == .checking || item.authorFeedbackStatus?.phase == .checking
            || item.reviewingProgress == .checking
        let deferredReview = item.mergeRequest?.draft == true && !draftAutomationAllowed
            ? row.intents.first(where: \.isDeferredReview) : nil
        let observedReasons = row.evidenceMatchesCatalogContext ? item.evidence.reviewingAssessment?.reasons ?? [] : []
        func readyAction(_ action: NextStep) -> NextStep {
            assistantReady || assistantChecking ? action : .setupAgent
        }
        if review?.execution?.state.isActive == true {
            nextStep = .automaticReview
        } else if row.waitsForReviewStart {
            status = .reviewNeeded
            nextStep = readyAction(.runReview)
            reviewReasons = row.reviewIntentForManualStart?.reviewLaunchReasons
                ?? (row.newReviewAssignedAt != nil ? [.reviewRequested] : observedReasons)
        } else if let deferredReview, drafts == 0, !MergeRequestBoardSnapshot.Row.jobNeedsAttention(currentReview?.execution?.state) {
            status = .waitingForReady
            nextStep = readyAction(.runReview)
            reviewReasons = deferredReview.reviewLaunchReasons
        } else if queued {
            status = workflowState == .running ? .running : .queued
            nextStep = readyAction(.automaticReview)
            reviewReasons = queuedWorkflow && !workflowReasons.isEmpty ? workflowReasons : automaticIntent?.reviewLaunchReasons ?? observedReasons
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
            reviewReasons = observedReasons
        } else if item.reviewingProgress == .waitingForOtherDiscussions {
            status = .waitingForOtherDiscussions
            nextStep = .monitoring
        } else if item.reviewingProgress == .current {
            if let activity, activity.openThreadCount > 0 { status = .openThreads(activity.openThreadCount) }
            else { status = .reviewCompleted }
            nextStep = .monitoring
        } else if workflowState == .failed {
            nextStep = readyAction(.runReview)
            reviewReasons = [.retryReview] + workflowReasons
        } else if (activity?.authorReplyCount ?? 0) > 0 || (activity?.otherReplyCount ?? 0) > 0 {
            nextStep = .viewDiscussions
        } else if (activity?.publishedCommentCount ?? 0) > 0 || currentReview?.execution?.state == .succeeded {
            nextStep = .monitoring
        } else if activity?.isComplete == true {
            nextStep = readyAction(.runReview)
        }

        if nextStep == .runReview, reviewReasons.isEmpty { reviewReasons = [.noVerifiedReview] }

        if isMonitoringCompletedReview, row.evidenceMatchesCatalogContext {
            let discussionsBlockMerge = row.displayRequest.map {
                $0.blockingDiscussionsResolved == false || $0.detailedMergeStatus == .discussionsNotResolved
            } == true
            if discussionsBlockMerge, let activity, activity.otherOpenThreadCount > 0 {
                status = .waitingForOtherDiscussions
            } else if let progress = row.displayItem.approvalProgress {
                completedReviewApproval = Self.completedApproval(progress, viewerUsername: viewerUsername)
            }
        }
    }

    private static func completedApproval(_ progress: MergeRequestApprovalProgress,
                                          viewerUsername: String?) -> CompletedReviewApproval {
        if let viewerUsername, !viewerUsername.isEmpty {
            if case .approved = progress.viewerApproval(username: viewerUsername, reviewers: [], isOwnMergeRequest: false) {
                return progress.isSatisfied ? .complete : .waitingForRequired
            }
            if progress.userCanApprove != false, progress.completed == progress.approvedBy.count {
                return .waitingForViewer
            }
        }
        if progress.required > 0, !(progress.requirementsSatisfied ?? (progress.completed >= progress.required)) {
            return .waitingForRequired
        }
        return .unknown
    }

    var presenceMessage: LocalizedStringResource {
        if let presencePeopleMessage { return presencePeopleMessage.resource }
        return switch presence {
        case .tracked: .ReviewingContext.reviewingTracked
        case .reviewRequested(let username):
            if let username { .ReviewingContext.reviewingReviewRequestedBy(username) }
            else { .ReviewingContext.reviewingReviewRequested }
        case .approvalRequested(let username):
            if let username { .ReviewingContext.reviewingApprovalRequestedBy(username) }
            else { .ReviewingContext.reviewingApprovalRequested }
        }
    }

    var presencePeopleMessage: RemotePeopleMessage? {
        guard let presenceActor, presenceActor.normalizedUsername != nil else { return nil }
        switch presence {
        case .reviewRequested: return .init(.ReviewingContext.reviewingReviewRequestedByPrefix, people: [presenceActor])
        case .approvalRequested: return .init(.ReviewingContext.reviewingApprovalRequestedByPrefix, people: [presenceActor])
        case .tracked: return nil
        }
    }

    var statusPeopleMessage: RemotePeopleMessage? {
        guard let activity else { return nil }
        switch status {
        case .openThreads(let count):
            return openThreadsMessage(count, people: activity.openThreadPeople)
        case .waitingForOtherDiscussions:
            return openThreadsMessage(activity.otherOpenThreadCount, people: activity.otherOpenThreadPeople)
        case .authorReplied:
            return author.flatMap { .init(.ReviewingContext.reviewingRepliesFrom, people: [$0.person]) }
        case .otherReplied:
            return .init(.ReviewingContext.reviewingRepliesFrom, people: activity.otherReplyPeople)
        default:
            return nil
        }
    }

    private func openThreadsMessage(_ count: Int, people: [PersonIdentity]) -> RemotePeopleMessage? {
        .init(count == 1 ? .ReviewingContext.reviewingOpenThreadFrom : .ReviewingContext.reviewingOpenThreadsFrom, people: people)
    }

    var statusMessage: LocalizedStringResource {
        if let statusPeopleMessage { return statusPeopleMessage.resource }
        return switch status {
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
