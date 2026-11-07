import Foundation
import MergeTetherRemote

@MainActor enum RemoteBoardAdapter {
    static func card(_ item: MergeRequestAttentionMonitor.Item, account: String,
                     extraActions: [RemoteActionKind] = [], context: [String] = []) -> RemoteCard {
        let drafts = item.drafts.enumerated().map { index, draft in
            let context: String?
            if case let .line(location) = draft.kind { context = location }
            else { context = draft.discussionID }
            return RemoteDraft(id: draft.id ?? (-1 - index), body: draft.note ?? "", context: context)
        }
        var card = RemoteCard(id: "mr:\(item.id.projectID):\(item.id.iid)", title: item.title,
            project: item.url.gitLabProjectPath, url: item.url,
            head: item.mergeRequest?.sha, detail: detail(item), drafts: drafts)
        var kinds = extraActions
        if item.mergeRequest?.sha != nil {
            if item.draftCount == drafts.count, !drafts.isEmpty, !item.requiresDiscussionRecheck,
               item.drafts.allSatisfy({ $0.id != nil && AICommentAssessmentStore.safeForAutomaticPublication($0) }) { kinds.append(.publish) }
            if item.canApprove { kinds.append(.approve) }
            if item.canConfirmReReview { kinds.append(.reReview) }
        }
        let metadata = item.drafts.flatMap { draft in
            [String(draft.authorID), draft.discussionID ?? "", String(describing: draft.resolveDiscussion),
             draft.position?.newPath ?? "", String(describing: draft.position?.newLine),
             draft.position?.oldPath ?? "", String(describing: draft.position?.oldLine)]
        }
        if let content = try? RemoteDigest.token(card),
           let token = try? RemoteDigest.token([account, content, item.reReviewFingerprint ?? ""] + metadata + context) {
            card.actions = Array(Set(kinds.map(\.rawValue))).sorted().compactMap { raw in
                RemoteActionKind(rawValue: raw).map { RemoteAction(id: raw, kind: $0, token: token) }
            }
        }
        return card
    }

    static func board(monitor: TodoMonitorService, session: UUID, account: String) -> RemoteBoard {
        let board = monitor.boardSnapshot
        let other = board.otherCards(jobs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost,
            username: monitor.glab.currentUsername, pinnedCards: monitor.settings.boardPins)
        var result = project(board: board, other: other, session: session, account: account)
        let rows = board.own + board.reviewed
        for lane in result.lanes.indices {
            for index in result.lanes[lane].cards.indices {
                var card = result.lanes[lane].cards[index]
                if let row = rows.first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == card.id }) {
                    let item = row.item
                    var extras: [RemoteActionKind] = []
                    let handoffs = monitor.pipelineHandoffs.filter { $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid }
                    if !handoffs.isEmpty { extras.append(.handoff) }
                    switch monitor.attentionFeedbackAction(for: item) {
                    case .ready, .failed: extras.append(.prepare)
                    default: break
                    }
                    if item.reReviewReadiness == .failed || item.reReviewReadiness == .unavailable { extras.append(.verify) }
                    card = self.card(item, account: account, extraActions: extras, context: handoffs.map(\.id).sorted() + [(try? RemoteDigest.token(monitor.settings.automation)) ?? ""])
                    if let human = MRHumanAction(row: row, assistantReady: monitor.availableAssistants.contains(monitor.settings.automation.assistant),
                        confirmationState: monitor.attention.confirmationStates[item.id]) {
                        card.detail = human.detail ?? String(localized: human.message)
                    } else if !item.isAuthored {
                        card.detail = String(localized: monitor.reviewingContext(for: row).nextStepMessage)
                    }
                    let busy = row.latestJob?.execution?.state.isActive == true || item.authorFeedbackStatus?.phase == .checking
                        || item.reReviewReadiness == .checking || monitor.attention.confirmationStates[item.id] == .publishing
                        || monitor.attention.confirmationStates[item.id] == .approving
                    if busy { card.actions = [] }
                    else {
                        let intent = row.intents.first { $0.state == .failed } ?? row.intents.first { $0.state == .pending }
                        if let intent, intent.kind == .refresh || monitor.availableAssistants.contains(monitor.settings.automation.assistant),
                           let token = try? RemoteDigest.token([account, try RemoteDigest.token(intent), try RemoteDigest.token(monitor.settings.automation)]) {
                            card.actions.append(.init(id: "intent:\(intent.id)", kind: .prepare, token: token))
                        }
                        if let job = row.latestJob, MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state),
                           job.taskPrompt != nil, job.mergeRequestURL != nil,
                           let token = try? RemoteDigest.token([account, try RemoteDigest.token(job), try RemoteDigest.token(monitor.settings.automation)]) {
                            card.actions.append(.init(id: "job:\(job.id)", kind: .retryJob, token: token))
                        }
                    }
                }
                result.lanes[lane].cards[index] = card
            }
        }
        result.updatedAt = monitor.lastRefresh
        result.partial = monitor.boardRefreshState != .current || monitor.lastError != nil
            || monitor.attention.hasError || monitor.authoredMergeRequests.hasError || monitor.isLoading
            || monitor.attention.isLoading || monitor.authoredMergeRequests.isLoading
        if result.partial {
            for lane in result.lanes.indices { for card in result.lanes[lane].cards.indices { result.lanes[lane].cards[card].actions = [] } }
        }
        return result
    }

    static func project(board: MergeRequestBoardSnapshot, other: [MergeRequestBoardSnapshot.OtherCard], session: UUID, account: String) -> RemoteBoard {
        let others = other.compactMap { entry -> RemoteCard? in
            switch entry.content {
            case .proposal(let proposal):
                var card = proposal.item.map { self.card($0, account: account) }
                    ?? RemoteCard(id: "mr:\(proposal.target.projectID):\(proposal.target.iid ?? 0)", title: proposal.title,
                        project: proposal.url.gitLabProjectPath, url: proposal.url)
                card.actions = []
                card.detail = String(localized: .Remote.remoteProposal)
                return card
            case .todo(let todo):
                var card = RemoteCard(id: "todo:\(todo.id)", title: todo.displayTitle, project: todo.project.nameWithNamespace,
                    url: todo.targetURL, detail: todo.body)
                if let token = try? RemoteDigest.token([account, try RemoteDigest.token(todo)]) {
                    card.actions = [.init(id: "markDone", kind: .markDone, token: token)]
                }
                return card
            case .job(let job):
                let url = job.mergeRequestURL
                var card = RemoteCard(id: "job:\(job.id)", title: job.title, project: url?.gitLabProjectPath ?? "", url: url,
                    detail: String(localized: .Remote.remoteAssistantPending))
                if MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state), job.taskPrompt != nil,
                   let token = try? RemoteDigest.token([account, try RemoteDigest.token(job)]) {
                    card.actions = [.init(id: "job:\(job.id)", kind: .retryJob, token: token)]
                }
                return card
            }
        }
        return .init(hostSession: session, account: account, lanes: [
            .init(id: .own, cards: board.own.map { card($0.item, account: account) }),
            .init(id: .reviewed, cards: board.reviewed.map { card($0.item, account: account) }),
            .init(id: .other, cards: others),
        ])
    }

    private static func detail(_ item: MergeRequestAttentionMonitor.Item) -> String {
        var reasons: [LocalizedStringResource] = []
        if item.mergeRequest?.draft == true { reasons.append(.Remote.remoteDraftMR) }
        if item.hasConflict { reasons.append(.Remote.remoteConflict) }
        if item.needsDiscussion || !item.feedback.isEmpty { reasons.append(.Remote.remoteDiscussion) }
        if item.needsChanges { reasons.append(.Remote.remoteChanges) }
        if item.failedPipeline || item.needsPipelineHandoff { reasons.append(.Remote.remotePipeline) }
        if item.needsMerge { reasons.append(.Remote.remoteMerge) }
        if item.requiresDiscussionRecheck || item.awaitingRemoteVerification { reasons.append(.Remote.remoteRecheck) }
        return reasons.map { String(localized: $0) }.joined(separator: " · ")
    }
}
