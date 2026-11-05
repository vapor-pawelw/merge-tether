import Foundation

/// Presentation-only deduplication. GitLab to-dos and attention evidence remain unchanged.
struct InboxSnapshot {
    let todos: [Todo]
    let attention: [MergeRequestAttentionMonitor.Item]
    let todoApprovals: [Int: MergeRequestAttentionMonitor.Item.ID]

    var count: Int { todos.count + attention.count }

    init(todos: [Todo], attention: [MergeRequestAttentionMonitor.Item], host: String?, username: String?) {
        self.todos = todos
        guard let host, let username else {
            self.attention = attention
            self.todoApprovals = [:]
            return
        }
        var approvals: [Int: MergeRequestAttentionMonitor.Item.ID] = [:]
        self.attention = MergeRequestAttentionMonitor.Item.ordered(attention.compactMap { original in
            guard original.url.isGitLabMergeRequest(host: host, iid: original.id.iid) else { return original }
            let matching = todos.filter {
                $0.targetType == .mergeRequest && $0.project.id == original.id.projectID && $0.target.iid == original.id.iid
                    && $0.targetURL.isGitLabMergeRequest(host: host, iid: original.id.iid)
            }
            var item = original
            if item.canApprove, let todo = matching.first(where: { $0.actionName == .approvalRequired }) {
                approvals[todo.id] = item.id
                item.canApprove = false
            }
            if matching.contains(where: { $0.actionName == .buildFailed }) { item.failedPipeline = false }
            if matching.contains(where: { $0.actionName == .unmergeable }) { item.hasConflict = false }
            if !item.feedback.isEmpty {
                item.feedback = TodoAutomationEvent.feedbackWithoutTodo(
                    item.feedback, todos: matching, host: host, projectID: item.id.projectID, iid: item.id.iid, username: username
                )
                if item.feedback.isEmpty {
                    item.needsDiscussion = item.hasOtherUnresolvedDiscussions
                    if matching.contains(where: { $0.actionName == .reviewSubmitted }) { item.needsChanges = false }
                }
            }
            return item.needsAttention ? item : nil
        })
        self.todoApprovals = approvals
    }
}
