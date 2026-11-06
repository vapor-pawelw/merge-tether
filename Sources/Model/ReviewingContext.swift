import Foundation

/// Read-only participation facts, computed from a complete GitLab discussion response.
struct ReviewingActivity: Equatable, Sendable {
    var publishedCommentCount = 0
    var openThreadCount = 0
    var authorReplyCount = 0
    var otherReplyCount = 0
    var isComplete = false

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
            // A missing identity or note ID could hide our later answer. Do not
            // classify that thread as awaiting us from partial evidence.
            guard complete, let lastOwnID = own.compactMap(\.id).max() else { continue }
            let replies = notes.filter { ($0.id ?? 0) > lastOwnID && $0.author?.id != reviewerID }
            if replies.contains(where: { $0.author?.id == authorID }) { authorReplyCount += 1 }
            else if !replies.isEmpty { otherReplyCount += 1 }
        }
    }
}

/// Informational context does not decide attention or authorize an MR action.
@MainActor
struct ReviewingContext {
    enum Presence: Equatable { case tracked, reviewRequested(String?), approvalRequested(String?) }
    enum Status: Equatable {
        case activityUnknown, drafts(Int), running, authorReplied(Int), otherReplied(Int)
        case openThreads(Int), commented(Int), reviewCompleted, noPublishedComments
    }
    var author: Todo.Author?
    var presence: Presence = .tracked
    var status: Status = .activityUnknown

    init(row: MergeRequestBoardSnapshot.Row) {
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
        if review?.execution?.state.isActive == true { status = .running }
        else if max(item.draftCount, item.drafts.count) > 0 { status = .drafts(max(item.draftCount, item.drafts.count)) }
        else if let activity = item.reviewingActivity {
            if activity.authorReplyCount > 0 { status = .authorReplied(activity.authorReplyCount) }
            else if activity.otherReplyCount > 0 { status = .otherReplied(activity.otherReplyCount) }
            else if activity.openThreadCount > 0 { status = .openThreads(activity.openThreadCount) }
            else if activity.publishedCommentCount > 0 { status = .commented(activity.publishedCommentCount) }
            else if review?.execution?.state == .succeeded { status = .reviewCompleted }
            else if activity.isComplete { status = .noPublishedComments }
        } else if review?.execution?.state == .succeeded { status = .reviewCompleted }
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
        }
    }
}
