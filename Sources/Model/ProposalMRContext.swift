import Foundation

struct ProposalMRContext {
    enum Reason: Identifiable, Equatable {
        case event(Todo), intent(MRTodoIntent.Kind), pipeline, conflict, feedback, merge, drafts, unmanaged
        var id: String {
            switch self {
            case .event(let todo): "event/\(todo.actionName.rawValue)/\(todo.author.id)"
            case .intent(let kind): "intent/\(kind.rawValue)"
            case .pipeline: "pipeline"
            case .conflict: "conflict"
            case .feedback: "feedback"
            case .merge: "merge"
            case .drafts: "drafts"
            case .unmanaged: "unmanaged"
            }
        }
    }
    let author: Todo.Author?
    let reasons: [Reason]

    init(proposal: MergeRequestBoardSnapshot.Proposal, fetchedRequest: GitLabMergeRequest? = nil) {
        let requests = [proposal.item?.mergeRequest]
            + proposal.intents.filter { $0.target == proposal.target }.map { Optional($0.request) }
            + [fetchedRequest]
        let requestAuthor = requests.compactMap { $0 }.first { Self.matches($0, proposal: proposal) }?.author
        author = requestAuthor ?? proposal.todos.first { todo in
            todo.project.id == proposal.target.projectID && todo.target.iid == proposal.target.iid
                && todo.targetURL.gitLabTodoMergeRequestURL(host: proposal.target.host, iid: proposal.target.iid ?? 0) == proposal.url
                && todo.target.author.map { $0.id > 0 && !$0.username.isEmpty } == true
        }?.target.author

        var reasons: [Reason] = []
        var seen: Set<String> = []
        let todos = proposal.todos.filter { todo in
            todo.project.id == proposal.target.projectID && todo.target.iid == proposal.target.iid
                && todo.targetURL.gitLabTodoMergeRequestURL(host: proposal.target.host, iid: proposal.target.iid ?? 0) == proposal.url
        }.sorted { $0.createdAt > $1.createdAt }
        for todo in todos {
            let reason = Reason.event(todo)
            if seen.insert(reason.id).inserted { reasons.append(reason) }
        }
        let represented = Set(todos.compactMap { MRTodoIntent.kind(for: $0, username: proposal.target.username) })
        for intent in proposal.intents.sorted(by: { $0.updatedAt > $1.updatedAt })
            where intent.target == proposal.target && Self.matches(intent.request, proposal: proposal)
                && intent.state != .completed && !represented.contains(intent.kind) {
            let reason = Reason.intent(intent.kind)
            if seen.insert(reason.id).inserted { reasons.append(reason) }
        }
        if reasons.isEmpty, let item = proposal.item {
            if item.hasConflict { reasons.append(.conflict) }
            if item.failedPipeline || item.needsPipelineHandoff { reasons.append(.pipeline) }
            if item.needsDiscussion || item.needsChanges || !item.feedback.isEmpty { reasons.append(.feedback) }
            if item.draftCount > 0 { reasons.append(.drafts) }
            if item.needsMerge { reasons.append(.merge) }
        }
        self.reasons = reasons.isEmpty ? [.unmanaged] : reasons
    }

    static func matches(_ request: GitLabMergeRequest, proposal: MergeRequestBoardSnapshot.Proposal) -> Bool {
        request.projectID == proposal.target.projectID && request.iid == proposal.target.iid
            && request.webURL == proposal.url
            && request.webURL.isGitLabMergeRequest(host: proposal.target.host, iid: request.iid)
            && request.author.id > 0 && !request.author.username.isEmpty
    }
}
