import Foundation

/// Presents durable MR actions; raw unknown events remain available for manual reading.
struct MergeRequestBoardSnapshot {
    struct Row: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let latestJob: AssistantAutomationRunner.Handoff?
        let intents: [MRTodoIntent]
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
        var needsAttention: Bool {
            if let humanActionRequired = item.humanActionRequired { return humanActionRequired }
            if latestJob?.execution?.state.isActive == true || item.authorFeedbackStatus?.phase == .checking { return false }
            return item.needsAttention || intents.contains { $0.state == .pending || $0.state == .failed }
                || Self.jobNeedsAttention(latestJob?.execution?.state)
        }
        static func jobNeedsAttention(_ state: AssistantJobExecution.State?) -> Bool {
            switch state {
            case .failed, .blocked, .interrupted, .cancelled: true
            default: false
            }
        }
    }

    struct Proposal: Identifiable {
        let target: MRAutomationScope.Target
        let title: String
        let url: URL
        let item: MergeRequestAttentionMonitor.Item?
        var todos: [Todo]
        let intents: [MRTodoIntent]
        var id: MRAutomationScope.Target { target }
    }

    let own: [Row]
    let reviewed: [Row]
    let otherMergeRequests: [Row]
    let proposals: [Proposal]
    let otherTodos: [Todo]

    init(own: [MergeRequestAttentionMonitor.Item], reviewed: [MergeRequestAttentionMonitor.Item],
         todos: [Todo], attention: [MergeRequestAttentionMonitor.Item],
         handoffs: [AssistantAutomationRunner.Handoff], host: String?, username: String?,
         intents: [MRTodoIntent] = [], routedTodoIDs: Set<Int> = [],
         ignoredTargets: Set<MRAutomationScope.Target> = [], humanAttention: UserAttentionSnapshot? = nil) {
        func target(for todo: Todo) -> MRAutomationScope.Target? {
            guard let host, let username, todo.targetType == .mergeRequest,
                  let iid = todo.target.iid, iid > 0, todo.project.id > 0,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { return nil }
            return .init(host: host, username: username, projectID: todo.project.id, iid: iid)
        }
        func recognized(_ todo: Todo) -> Bool {
            guard let username else { return false }
            return MRTodoIntent.kind(for: todo, username: username) != nil
        }
        let accountIntents = intents.filter { $0.target.host == host && $0.target.username == username }
        let remaining = todos.filter { todo in
            guard !routedTodoIDs.contains(todo.id) else { return false }
            return target(for: todo).map { !ignoredTargets.contains($0) } ?? true
        }
        func sameMergeRequest(_ left: MergeRequestAttentionMonitor.Item, _ right: MergeRequestAttentionMonitor.Item) -> Bool {
            guard left.id == right.id, let host else { return false }
            return left.url.isGitLabMergeRequest(host: host, iid: left.id.iid)
                && right.url.isGitLabMergeRequest(host: host, iid: right.id.iid)
        }
        func row(_ original: MergeRequestAttentionMonitor.Item) -> Row {
            let valid = host.map { original.url.isGitLabMergeRequest(host: $0, iid: original.id.iid) } == true
            var item = attention.first { sameMergeRequest($0, original) } ?? original
            if item.mergeRequest == nil { item.mergeRequest = original.mergeRequest }
            item.isAuthored = original.isAuthored || username.map { original.mergeRequest?.author.username == $0 } == true
            item = item.presentingVerifiedAuthorFeedback()
            let latest = handoffs.filter {
                valid && $0.key.work.host == host && $0.key.username == username
                    && $0.key.work.projectID == item.id.projectID && $0.key.work.iid == item.id.iid
            }.max { $0.createdAt < $1.createdAt }
            let currentIntents = accountIntents.filter {
                valid && $0.target.host == host && $0.target.username == username
                    && $0.target.projectID == item.id.projectID && $0.target.iid == item.id.iid
            }.sorted { $0.updatedAt > $1.updatedAt }
            let actionKey = "\(host ?? "")/\(username ?? "")/mr/\(item.id.projectID)/\(item.id.iid)"
            item.humanActionRequired = humanAttention.map { $0.items.contains { $0.id == actionKey } }
            return Row(item: item, latestJob: latest, intents: currentIntents)
        }
        let originalListed = own + reviewed
        let orphanIntents = accountIntents.filter { intent in
            intent.state != .completed && !ignoredTargets.contains(intent.target)
                && !originalListed.contains { $0.id.projectID == intent.target.projectID && $0.id.iid == intent.target.iid
                    && $0.url.isGitLabMergeRequest(host: intent.target.host, iid: $0.id.iid) }
        }
        var orphanRows: [MergeRequestAttentionMonitor.Item] = []
        for intent in orphanIntents where !orphanRows.contains(where: { $0.id.projectID == intent.target.projectID && $0.id.iid == intent.target.iid }) {
            let request = intent.request
            orphanRows.append(.init(id: .init(projectID: request.projectID, iid: request.iid), title: request.title,
                url: request.webURL, mergeRequest: request, isAuthored: request.author.username == username))
        }
        let ownRows = own + orphanRows.filter(\.isAuthored)
        let reviewedRows = reviewed + orphanRows.filter { !$0.isAuthored }
        self.own = Self.ordered(ownRows.map(row))
        self.reviewed = Self.ordered(reviewedRows.map(row), draftsLast: true)
        let listed = ownRows + reviewedRows
        otherMergeRequests = Self.ordered(attention.filter { candidate in
            guard !listed.contains(where: { sameMergeRequest($0, candidate) }) else { return false }
            guard let host, let username else { return true }
            return !ignoredTargets.contains(.init(host: host, username: username,
                projectID: candidate.id.projectID, iid: candidate.id.iid))
        }.map(row))
        var grouped: [Proposal] = []
        if let host, let username {
            for row in otherMergeRequests where row.item.url.isGitLabMergeRequest(host: host, iid: row.item.id.iid) {
                grouped.append(.init(target: .init(host: host, username: username, projectID: row.item.id.projectID, iid: row.item.id.iid),
                    title: row.item.title, url: row.item.url, item: row.item, todos: [], intents: row.intents))
            }
        }
        var unknown: [Todo] = []
        for todo in remaining {
            guard recognized(todo), let target = target(for: todo), let iid = target.iid,
                  let canonical = todo.targetURL.gitLabTodoMergeRequestURL(host: target.host, iid: iid)
            else { unknown.append(todo); continue }
            // A managed MR's raw event remains readable until live routing accepts it.
            guard !listed.contains(where: { $0.id.projectID == target.projectID && $0.id.iid == target.iid
                && $0.url.isGitLabMergeRequest(host: target.host, iid: $0.id.iid) }) else {
                unknown.append(todo)
                continue
            }
            if let index = grouped.firstIndex(where: { $0.target == target }) {
                grouped[index].todos.append(todo)
            } else {
                grouped.append(.init(target: target, title: todo.displayTitle, url: canonical, item: nil, todos: [todo], intents: []))
            }
        }
        proposals = grouped
        otherTodos = unknown
    }

    private static func ordered(_ rows: [Row], draftsLast: Bool = false) -> [Row] {
        rows.enumerated().sorted {
            (draftsLast && $0.element.item.section == .draftMergeRequests ? 1 : 0,
             $0.element.needsAttention ? 0 : 1, $0.offset)
                < (draftsLast && $1.element.item.section == .draftMergeRequests ? 1 : 0,
                   $1.element.needsAttention ? 0 : 1, $1.offset)
        }.map(\.element)
    }
}
