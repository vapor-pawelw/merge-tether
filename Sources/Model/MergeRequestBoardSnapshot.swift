import Foundation

/// Presents durable MR actions; raw unknown events remain available for manual reading.
struct MergeRequestBoardSnapshot {
    struct Row: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let latestJob: AssistantAutomationRunner.Handoff?
        let intents: [MRTodoIntent]
        var pipelineEvidence: GitLabMergeRequest? = nil
        var pipelineEvidenceCheckedAt: Date? = nil
        var catalog: MRCurrentRowProjection.Catalog? = nil
        /// Compatibility only; fresh command guards still decide every action.
        var evidenceMatchesCatalogContext = true
        var displayRequest: GitLabMergeRequest? { catalog?.facts.request ?? item.mergeRequest }
        var displayTitle: String { catalog?.facts.title ?? item.title }
        var displayURL: URL { catalog?.facts.url ?? item.url }
        var isDraft: Bool { displayRequest?.draft == true || displayRequest == nil && item.section == .draftMergeRequests }
        var displayItem: MergeRequestAttentionMonitor.Item {
            guard let catalog else { return item }
            let facts = catalog.facts
            return .init(id: item.id, title: facts.title, url: facts.url,
                lifecycleCompletionID: facts.lifecycleCompletionID, approvalProgress: facts.approvalProgress,
                mergeRequest: facts.request, isAuthored: facts.isAuthored, reviewingActivity: facts.reviewingActivity,
                dependencies: catalog.dependencies)
        }
        /// Dedicated CI metadata never replaces the MR snapshot bound to drafts or feedback.
        var currentPipelineRequest: GitLabMergeRequest? {
            PipelineJobReconciliation.matchingDetails(displayRequest, details: pipelineEvidence,
                checkedAt: pipelineEvidenceCheckedAt, job: latestJob) ?? displayRequest
        }
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
        var attentionIntents: [MRTodoIntent] {
            intents.filter { intent in
                !(intent.kind == .pipeline && intent.jobID == latestJob?.id
                    && PipelineJobReconciliation.isObsolete(latestJob, request: currentPipelineRequest))
            }
        }
        var stoppedJobNeedsAttention: Bool {
            Self.jobNeedsAttention(latestJob?.operationalExecution?.state)
                && !PipelineJobReconciliation.isObsolete(latestJob, request: currentPipelineRequest)
                && !stoppedFollowUpIsReconciled
                && !intents.contains { $0.jobID == latestJob?.id && $0.state == .completed }
        }
        private var stoppedFollowUpIsReconciled: Bool {
            guard item.isAuthored, let job = latestJob, let request = item.mergeRequest else { return false }
            return item.authorFeedbackStatus?.reconciles(job, request: request,
                discussionFingerprint: item.observedDiscussionFingerprint) == true
        }
        var hasIndependentStoppedWork: Bool {
            stoppedJobNeedsAttention || attentionIntents.contains { $0.state == .failed && !isReconciling($0) }
        }
        var needsAttention: Bool {
            if displayRequest.map({ ["merged", "closed"].contains($0.state) }) == true { return false }
            if let humanActionRequired = item.humanActionRequired { return humanActionRequired }
            if latestJob?.operationalExecution?.state.isActive == true { return false }
            if item.draftProofRecoveryChecking || isCheckingReadOnlyReconciliation {
                return hasIndependentStoppedWork
            }
            if item.authorFeedbackStatus?.phase == .checking || item.aiOriginChecking { return false }
            return item.needsAttention || attentionIntents.contains { ($0.state == .pending && !$0.isDeferredReview) || $0.state == .failed }
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
    let completions: [MergeRequestLifecycleLedger.CompletionReceipt]
    private let ignoredTargets: Set<MRAutomationScope.Target>
    private let automation: AutomationSettings?
    private let grouping: MRBoardGrouping
    private let knownRequests: [MergeRequestAttentionMonitor.Item.ID: GitLabMergeRequest]

    init(own: [MergeRequestAttentionMonitor.Item], reviewed: [MergeRequestAttentionMonitor.Item],
         todos: [Todo], attention: [MergeRequestAttentionMonitor.Item],
         handoffs: [AssistantAutomationRunner.Handoff], host: String?, username: String?,
         intents: [MRTodoIntent] = [], routedTodoIDs: Set<Int> = [],
         ignoredTargets: Set<MRAutomationScope.Target> = [], humanAttention: UserAttentionSnapshot? = nil,
         pinnedCards: Set<BoardCardPin> = [], pipelineEvidence: [GitLabMergeRequest] = [],
         pipelineEvidenceCheckedAt: Date? = nil, preservedOrder: [MergeRequestAttentionMonitor.Item.ID: Int] = [:],
         automation: AutomationSettings? = nil, displayRequests: [GitLabMergeRequest] = [],
         grouping: MRBoardGrouping = .withoutAutomation,
         completions: [MergeRequestLifecycleLedger.CompletionReceipt] = [],
         currentRows: [MergeRequestAttentionMonitor.Item.ID: MRCurrentRowProjection] = [:]) {
        self.ignoredTargets = ignoredTargets
        self.automation = automation
        self.grouping = grouping
        self.completions = completions.filter { receipt in
            guard let iid = receipt.target.iid, iid > 0 else { return false }
            return receipt.target.host == host && receipt.target.username == username
                && receipt.target.projectID > 0 && (receipt.kind == .merged || receipt.kind == .closed)
                && receipt.url.isGitLabMergeRequest(host: receipt.target.host, iid: iid)
        }
        let validatedDisplay = displayRequests.filter { request in
            guard let host, let username, !username.isEmpty, request.projectID > 0, request.iid > 0 else { return false }
            return request.webURL.isGitLabMergeRequest(host: host, iid: request.iid)
        }
        knownRequests = Dictionary((validatedDisplay + (own + reviewed + attention).compactMap(\.mergeRequest)).map {
            (MergeRequestAttentionMonitor.Item.ID(projectID: $0.projectID, iid: $0.iid), $0)
        }, uniquingKeysWith: { first, _ in first })
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
            let projection = currentRows[original.id] ?? MRCurrentRowProjection(evidence: attention.first { sameMergeRequest($0, original) } ?? original,
                catalog: original, username: username)
            var item = projection.item
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
            return Row(item: item, latestJob: latest, intents: currentIntents,
                pipelineEvidence: pipelineEvidence.first { $0.projectID == item.id.projectID && $0.iid == item.id.iid },
                pipelineEvidenceCheckedAt: pipelineEvidenceCheckedAt, catalog: projection.catalog,
                evidenceMatchesCatalogContext: projection.evidenceMatchesCatalogContext)
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
        self.own = Self.ordered(ownRows.map(row), host: host, username: username, pinnedCards: pinnedCards, preservedOrder: preservedOrder, automation: automation, grouping: grouping)
        self.reviewed = Self.ordered(reviewedRows.map(row), draftsLast: true, host: host, username: username, pinnedCards: pinnedCards, preservedOrder: preservedOrder, automation: automation, grouping: grouping)
        let listed = ownRows + reviewedRows
        otherMergeRequests = Self.ordered(attention.filter { candidate in
            guard !listed.contains(where: { sameMergeRequest($0, candidate) }) else { return false }
            guard let host, let username else { return true }
            return !ignoredTargets.contains(.init(host: host, username: username,
                projectID: candidate.id.projectID, iid: candidate.id.iid))
        }.map(row), host: host, username: username, pinnedCards: pinnedCards, preservedOrder: preservedOrder, automation: automation, grouping: grouping)
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

    /// An open Details selection may outlive a host change; numeric MR IDs alone are insufficient.
    func row(matching item: MergeRequestAttentionMonitor.Item, host: String?, username: String?) -> Row? {
        guard let host, let username, !username.isEmpty,
              let url = item.url.gitLabTodoMergeRequestURL(host: host, iid: item.id.iid) else { return nil }
        return (own + reviewed + otherMergeRequests).first {
            $0.id == item.id && $0.item.url.gitLabTodoMergeRequestURL(host: host, iid: item.id.iid) == url
        }
    }

    struct OtherCard: Identifiable {
        enum Content {
            case proposal(Proposal)
            case todo(Todo)
            case job(AssistantAutomationRunner.Handoff)
            case completion(MergeRequestLifecycleLedger.CompletionReceipt)
        }
        let id: BoardCardPin
        let content: Content
        var activityGroup: MRBoardActivity.Group = .regular
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
        cards += completions.filter { $0.target.host == host && $0.target.username == username }.map {
            .init(id: .init(host: host, username: username, item: .completion($0.id)), content: .completion($0))
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
        for index in cards.indices {
            cards[index].activityGroup = activityGroup(for: cards[index].content, host: host, username: username)
        }
        let pinned = Self.pinnedFirst(cards, pins: pinnedCards) { $0.id }
        guard automation != nil else { return pinned }
        return pinned.enumerated().sorted {
            ($0.element.activityGroup.rawValue, $0.offset) < ($1.element.activityGroup.rawValue, $1.offset)
        }.map(\.element)
    }

    private func activityGroup(for content: OtherCard.Content, host: String, username: String) -> MRBoardActivity.Group {
        guard let automation else { return .regular }
        let target: MRAutomationScope.Target
        let isDraft: Bool
        let finished: Bool
        switch content {
        case .completion: return .regular
        case .proposal(let proposal):
            target = proposal.target
            let request = knownRequests[.init(projectID: target.projectID, iid: target.iid ?? 0)]
                .flatMap { $0.webURL == proposal.url ? $0 : nil }
            isDraft = request?.draft ?? proposal.item.map { $0.section == .draftMergeRequests }
                ?? proposal.todos.contains(where: \.isDraft)
            finished = MergeRequestFinishedState(request ?? proposal.item?.mergeRequest) != nil
        case .todo(let todo):
            guard todo.targetType == .mergeRequest, let iid = todo.target.iid,
                  let url = todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) else { return .regular }
            target = .init(host: host, username: username, projectID: todo.project.id, iid: iid)
            let request = knownRequests[.init(projectID: target.projectID, iid: iid)]
                .flatMap { $0.webURL == url ? $0 : nil }
            isDraft = request?.draft ?? todo.isDraft
            finished = MergeRequestFinishedState(request) != nil
        case .job(let job):
            target = .init(host: host, username: username, projectID: job.key.work.projectID, iid: job.key.work.iid)
            let request = knownRequests[.init(projectID: target.projectID, iid: target.iid ?? 0)]
            if let url = job.mergeRequestURL {
                guard url.isGitLabMergeRequest(host: host, iid: job.key.work.iid),
                      request == nil || request?.webURL == url else { return .regular }
            }
            isDraft = request?.draft == true
            finished = MergeRequestFinishedState(request) != nil
        }
        guard target.projectID > 0, let iid = target.iid, iid > 0,
              target.host == host, target.username == username else { return .regular }
        return MRBoardActivity(automation: automation, target: target, isDraft: isDraft, isFinished: finished, grouping: grouping).group
    }

    private static func ordered(_ rows: [Row], draftsLast: Bool = false, host: String?, username: String?,
                                pinnedCards: Set<BoardCardPin>,
                                preservedOrder: [MergeRequestAttentionMonitor.Item.ID: Int], automation: AutomationSettings?,
                                grouping: MRBoardGrouping) -> [Row] {
        func isPinned(_ row: Row) -> Bool {
            guard let host, row.item.url.isGitLabMergeRequest(host: host, iid: row.id.iid),
                  let pin = BoardCardPin.mergeRequest(host: host, username: username,
                      projectID: row.id.projectID, iid: row.id.iid) else { return false }
            return pinnedCards.contains(pin)
        }
        func isFinished(_ row: Row) -> Bool {
            row.displayRequest.map { ["merged", "closed"].contains($0.state) } == true
        }
        func activityRank(_ row: Row) -> Int {
            guard let automation, let host, let username else { return 0 }
            let target: MRAutomationScope.Target? = row.id.projectID > 0 && row.id.iid > 0
                && row.item.url.isGitLabMergeRequest(host: host, iid: row.id.iid)
                ? .init(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid) : nil
            return MRBoardActivity(automation: automation, target: target,
                isDraft: row.isDraft, isFinished: isFinished(row), grouping: grouping).group.rawValue
        }
        let normal = rows.enumerated().sorted {
            (isFinished($0.element) ? 0 : 1, activityRank($0.element), isPinned($0.element) ? 0 : 1,
             automation?.hasEnabledAutomation != true && draftsLast && $0.element.isDraft ? 1 : 0,
             $0.element.needsAttention ? 0 : 1, $0.offset)
                < (isFinished($1.element) ? 0 : 1, activityRank($1.element), isPinned($1.element) ? 0 : 1,
                   automation?.hasEnabledAutomation != true && draftsLast && $1.element.isDraft ? 1 : 0,
                   $1.element.needsAttention ? 0 : 1, $1.offset)
        }.map(\.element)
        let finished = normal.filter(isFinished)
        let active = normal.filter { !isFinished($0) }
        if automation != nil {
            let regular = active.filter { activityRank($0) == MRBoardActivity.Group.regular.rawValue }
            let inactive = active.filter { activityRank($0) != MRBoardActivity.Group.regular.rawValue }
            return finished + restorePositions(regular, offset: 0) + restorePositions(inactive, offset: regular.count)
        }
        return finished + restorePositions(active, offset: 0)

        func restorePositions(_ group: [Row], offset: Int) -> [Row] {
            let latched = group.enumerated().filter { preservedOrder[$0.element.id] != nil }.sorted {
                (preservedOrder[$0.element.id] ?? 0, $0.offset) < (preservedOrder[$1.element.id] ?? 0, $1.offset)
            }.map(\.element)
            var result = group.filter { preservedOrder[$0.id] == nil }
            for row in latched {
                result.insert(row, at: min(max(0, (preservedOrder[row.id] ?? 0) - offset), result.count))
            }
            return result
        }
    }

    private static func pinnedFirst<Element>(_ values: [Element], pins: Set<BoardCardPin>,
                                              identity: (Element) -> BoardCardPin?) -> [Element] {
        values.enumerated().sorted {
            (identity($0.element).map { pins.contains($0) } == true ? 0 : 1, $0.offset)
                < (identity($1.element).map { pins.contains($0) } == true ? 0 : 1, $1.offset)
        }.map(\.element)
    }
}
