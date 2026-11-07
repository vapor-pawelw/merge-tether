import Foundation

/// Presents durable MR actions; raw unknown events remain available for manual reading.
struct MergeRequestBoardSnapshot {
    struct Row: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let latestJob: AssistantAutomationRunner.Handoff?
        let intents: [MRTodoIntent]
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
        var isCheckingReadOnlyReconciliation: Bool {
            guard let status = item.authorFeedbackStatus, let request = item.mergeRequest else { return false }
            return status.readOnlyReconciliation && status.phase == .checking
                && status.head == request.sha && status.fingerprint == item.observedDiscussionFingerprint
                && status.semanticContextFingerprint == request.semanticContextFingerprint
        }
        func isReconciling(_ intent: MRTodoIntent) -> Bool {
            isCheckingReadOnlyReconciliation && intent.kind == .followUp && intent.jobID == nil
                && intent.state == .failed && intent.target.projectID == id.projectID && intent.target.iid == id.iid
                && intent.target.username == item.mergeRequest?.author.username
        }
        var stoppedJobNeedsAttention: Bool {
            Self.jobNeedsAttention(latestJob?.operationalExecution?.state)
                && !intents.contains { $0.jobID == latestJob?.id && $0.state == .completed }
        }
        var hasIndependentStoppedWork: Bool {
            stoppedJobNeedsAttention || intents.contains { $0.state == .failed && !isReconciling($0) }
        }
        var needsAttention: Bool {
            if let humanActionRequired = item.humanActionRequired { return humanActionRequired }
            if latestJob?.operationalExecution?.state.isActive == true { return false }
            if item.draftProofRecoveryChecking || isCheckingReadOnlyReconciliation {
                return hasIndependentStoppedWork
            }
            if item.authorFeedbackStatus?.phase == .checking || item.aiOriginChecking { return false }
            return item.needsAttention || intents.contains { ($0.state == .pending && !$0.isDeferredReview) || $0.state == .failed }
                || stoppedJobNeedsAttention
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
        var latestJob: AssistantAutomationRunner.Handoff? = nil
        var id: MRAutomationScope.Target { target }
    }

    let own: [Row]
    let reviewed: [Row]
    let otherMergeRequests: [Row]
    let proposals: [Proposal]
    let otherTodos: [Todo]
    private let ignoredTargets: Set<MRAutomationScope.Target>

    init(own: [MergeRequestAttentionMonitor.Item], reviewed: [MergeRequestAttentionMonitor.Item],
         todos: [Todo], attention: [MergeRequestAttentionMonitor.Item],
         handoffs: [AssistantAutomationRunner.Handoff], host: String?, username: String?,
         intents: [MRTodoIntent] = [], routedTodoIDs: Set<Int> = [],
         ignoredTargets: Set<MRAutomationScope.Target> = [], humanAttention: UserAttentionSnapshot? = nil,
         pinnedCards: Set<BoardCardPin> = []) {
        self.ignoredTargets = ignoredTargets
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
            if let request = original.mergeRequest, let displayed = item.mergeRequest,
               MergeRequestDependencySummary.Context(request) == MergeRequestDependencySummary.Context(displayed) {
                item.dependencies = original.dependencies ?? item.dependencies
            }
            item.isAuthored = original.isAuthored || username.map { original.mergeRequest?.author.username == $0 } == true
            item = item.presentingVerifiedAuthorFeedback()
            let latest = handoffs.filter {
                !$0.isObsoleteReminder && valid && $0.key.work.host == host && $0.key.username == username
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
            intent.grantsManagement && intent.state != .completed && !ignoredTargets.contains(intent.target)
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
        self.own = Self.ordered(ownRows.map(row), host: host, username: username, pinnedCards: pinnedCards)
        self.reviewed = Self.ordered(reviewedRows.map(row), draftsLast: true, host: host, username: username, pinnedCards: pinnedCards)
        let listed = ownRows + reviewedRows
        otherMergeRequests = Self.ordered(attention.filter { candidate in
            guard !listed.contains(where: { sameMergeRequest($0, candidate) }) else { return false }
            guard let host, let username else { return true }
            return !ignoredTargets.contains(.init(host: host, username: username,
                projectID: candidate.id.projectID, iid: candidate.id.iid))
        }.map(row), host: host, username: username, pinnedCards: pinnedCards)
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
        for index in grouped.indices {
            let target = grouped[index].target
            grouped[index].latestJob = handoffs.filter {
                !$0.isObsoleteReminder && $0.key.work.host == target.host && $0.key.username == target.username
                    && $0.key.work.projectID == target.projectID && $0.key.work.iid == target.iid
            }.max { $0.createdAt < $1.createdAt }
        }
        proposals = Self.pinnedFirst(grouped, pins: pinnedCards) { proposal in
            BoardCardPin.mergeRequest(host: proposal.target.host, username: proposal.target.username,
                projectID: proposal.target.projectID, iid: proposal.target.iid ?? 0)
        }
        otherTodos = unknown
    }

    struct OtherCard: Identifiable {
        enum Content {
            case proposal(Proposal)
            case todo(Todo)
            case job(AssistantAutomationRunner.Handoff)
        }
        let id: BoardCardPin
        let content: Content
    }

    /// One identity per card, including proposals with a matching agent run.
    func otherCards(jobs: [AssistantAutomationRunner.Handoff], host: String?, username: String?,
                    pinnedCards: Set<BoardCardPin>) -> [OtherCard] {
        guard let host, let username else { return [] }
        var cards = proposals.compactMap { proposal -> OtherCard? in
            guard proposal.target.host == host, proposal.target.username == username,
                  let pin = BoardCardPin.mergeRequest(host: host, username: username,
                      projectID: proposal.target.projectID, iid: proposal.target.iid ?? 0) else { return nil }
            return .init(id: pin, content: .proposal(proposal))
        }
        cards += otherTodos.compactMap { todo in
            BoardCardPin.todo(host: host, username: username, id: todo.id).map { .init(id: $0, content: .todo(todo)) }
        }
        let rows = own + reviewed + otherMergeRequests
        let latest = Dictionary(grouping: jobs.filter { !$0.isObsoleteReminder && $0.key.work.host == host && $0.key.username == username }, by: \.key.work)
            .values.compactMap { $0.max { $0.createdAt < $1.createdAt } }
            .sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
        for job in latest {
            let target = MRAutomationScope.Target(host: host, username: username, projectID: job.key.work.projectID, iid: job.key.work.iid)
            guard !ignoredTargets.contains(target),
                  job.execution?.state.isActive == true || Row.jobNeedsAttention(job.execution?.state),
                  !rows.contains(where: { $0.item.id.projectID == target.projectID && $0.item.id.iid == target.iid
                      && $0.item.url.isGitLabMergeRequest(host: host, iid: job.key.work.iid) }),
                  !proposals.contains(where: { $0.target == target && $0.latestJob != nil }),
                  let pin = BoardCardPin.mergeRequest(host: host, username: username,
                      projectID: job.key.work.projectID, iid: job.key.work.iid) else { continue }
            cards.append(.init(id: pin, content: .job(job)))
        }
        return Self.pinnedFirst(cards, pins: pinnedCards) { $0.id }
    }

    private static func ordered(_ rows: [Row], draftsLast: Bool = false, host: String?, username: String?,
                                pinnedCards: Set<BoardCardPin>) -> [Row] {
        func isPinned(_ row: Row) -> Bool {
            guard let host, row.item.url.isGitLabMergeRequest(host: host, iid: row.id.iid),
                  let pin = BoardCardPin.mergeRequest(host: host, username: username,
                      projectID: row.id.projectID, iid: row.id.iid) else { return false }
            return pinnedCards.contains(pin)
        }
        return rows.enumerated().sorted {
            (isPinned($0.element) ? 0 : 1,
             draftsLast && $0.element.item.section == .draftMergeRequests ? 1 : 0,
             $0.element.needsAttention ? 0 : 1, $0.offset)
                < (isPinned($1.element) ? 0 : 1,
                   draftsLast && $1.element.item.section == .draftMergeRequests ? 1 : 0,
                   $1.element.needsAttention ? 0 : 1, $1.offset)
        }.map(\.element)
    }

    private static func pinnedFirst<Element>(_ values: [Element], pins: Set<BoardCardPin>,
                                              identity: (Element) -> BoardCardPin?) -> [Element] {
        values.enumerated().sorted {
            (identity($0.element).map { pins.contains($0) } == true ? 0 : 1, $0.offset)
                < (identity($1.element).map { pins.contains($0) } == true ? 0 : 1, $1.offset)
        }.map(\.element)
    }
}
