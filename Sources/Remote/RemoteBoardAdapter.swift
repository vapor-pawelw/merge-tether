import Foundation
import MergeTetherRemote

@MainActor enum RemoteBoardAdapter {
    static func card(_ completion: MergeRequestLifecycleLedger.CompletionReceipt, account: String) -> RemoteCard {
        let state = completion.kind == .merged ? MergeRequestFinishedState.merged : .closed
        var card = RemoteCard(id: "completion:\(completion.id)", title: completion.title,
            project: completion.url.gitLabProjectPath, url: completion.url,
            detail: String(localized: completion.kind == .merged ? .MRLifecycle.completionMerged : .MRLifecycle.completionClosed),
            needsAttention: false, mergeRequestIID: completion.target.iid,
            presentation: .init(author: completion.author?.name,
                repository: completion.url.gitLabProjectPath.split(separator: "/").last.map(String.init) ?? "",
                draftBadge: String(localized: state.badge)))
        if let token = try? RemoteDigest.token([account, try RemoteDigest.token(completion)]) {
            card.actions = [.init(id: "seen", kind: .markDone, token: token)]
        }
        return card
    }

    static func acknowledgeCompletion(_ card: RemoteCard, action: RemoteAction,
                                      monitor: TodoMonitorService, account: String) -> Bool {
        guard action.kind == .markDone, action.id == "seen", card.id.hasPrefix("completion:"),
              let id = UUID(uuidString: String(card.id.dropFirst("completion:".count))),
              let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername,
              account == "\(username)@\(host)",
              let completion = monitor.lifecycleCompletions.first(where: { $0.id == id }),
              self.card(completion, account: account) == card, card.actions.contains(action) else { return false }
        return monitor.acknowledgeLifecycleCompletion(id: id)
    }

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
        card.contextRevision = item.mergeRequest.flatMap(contextRevision)
        card.dependencies = dependencyPresentation(item.dependencies, projectID: item.id.projectID)
        var kinds = extraActions
        if item.mergeRequest?.sha != nil {
            if item.draftCount == drafts.count, !drafts.isEmpty, !item.requiresDiscussionRecheck,
               item.drafts.allSatisfy({ $0.id != nil && AICommentAssessmentStore.safeForAutomaticPublication($0) }) { kinds.append(.publish) }
            if item.canApprove { kinds.append(.approve) }
            if item.canConfirmReReview { kinds.append(.reReview) }
            if item.canFinishCommentReview { kinds.append(.finishCommentReview) }
        }
        let metadata = item.drafts.flatMap { draft in
            [String(draft.authorID), draft.discussionID ?? "", String(describing: draft.resolveDiscussion),
             draft.position?.newPath ?? "", String(describing: draft.position?.newLine),
             draft.position?.oldPath ?? "", String(describing: draft.position?.oldLine)]
        }
        if let content = try? RemoteDigest.token(card),
           let token = try? RemoteDigest.token([account, content, item.reReviewFingerprint ?? "",
               item.observedDiscussionFingerprint ?? "", item.mergeRequest?.semanticContextFingerprint ?? "",
               String(item.requiresCommentReview), item.commentReviewSnapshot?.discussionFingerprint ?? ""] + metadata + context) {
            card.actions = Array(Set(kinds.map(\.rawValue))).sorted().compactMap { raw in
                RemoteActionKind(rawValue: raw).map { RemoteAction(id: raw, kind: $0, token: token) }
            }
            card.actions += item.drafts.compactMap { draft in
                guard let id = draft.id, id > 0 else { return nil }
                return RemoteAction(id: "deleteDraft:\(id)", kind: .deleteDraft, token: token)
            }
        }
        card.approvals = item.approvalProgress.flatMap {
            // Older phones require completed <= required; optional approvals use an additive field.
            .init(completed: min($0.completed, $0.required), required: $0.required,
                  received: $0.completed, requirementsSatisfied: $0.requirementsSatisfied)
        }
        return card
    }

    private static func dependencyPresentation(_ summary: MergeRequestDependencySummary?, projectID: Int) -> RemoteMRDependencies? {
        guard let dependencies = summary, dependencies.hasPresentation else { return nil }
        return .init(stackPosition: dependencies.stackPosition,
            predecessors: dependencies.predecessors.map { .init(reference: $0.reference(relativeTo: projectID),
                title: $0.title, url: $0.url, isCurrent: $0.isCurrent) }, notice: dependencies.notice)
    }

    static func board(monitor: TodoMonitorService, session: UUID, account: String) -> RemoteBoard {
        let board = monitor.boardSnapshot
        let other = board.otherCards(jobs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost,
            username: monitor.glab.currentUsername, pinnedCards: monitor.settings.boardPins)
        var result = project(board: board, other: other, session: session, account: account,
            intents: monitor.settings.mrActionIntents, conflictReceipts: monitor.settings.conflictReceipts)
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
                    if item.reReviewReadiness == .failed || item.reReviewReadiness == .unavailable
                        || item.draftProofRecoveryFailure != nil { extras.append(.verify) }
                    card = self.card(item, account: account, extraActions: extras, context: handoffs.map(\.id).sorted() + [(try? RemoteDigest.token(monitor.settings.automation)) ?? ""])
                    let presentation = MRCardPresentation(row: row, monitor: monitor, allowsRemoval: result.lanes[lane].id == .reviewed)
                    card = self.presentation(card, model: presentation)
                    if row.displayRequest?.state == "merged" || row.displayRequest?.state == "closed" {
                        card.actions = []
                        result.lanes[lane].cards[index] = card
                        continue
                    }
                    let mergeStatus = monitor.authoredMergeRequests.hasSyncedCurrentCatalog
                        ? matchingMergeStatus(for: row, statuses: monitor.authoredMergeRequests.requests) : nil
                    card = mergePresentation(card, item: item, status: mergeStatus,
                        evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext,
                        hasCurrentCatalog: monitor.authoredMergeRequests.hasSyncedCurrentCatalog)
                    let busy = presentation.actionsBlocked
                    if busy { card.actions = [] }
                    else {
                        card = mergeActions(card, item: item, status: mergeStatus, monitor: monitor, account: account,
                            evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext)
                        let intent = row.attentionIntents.first { $0.state == .failed } ?? row.attentionIntents.first { $0.state == .pending }
                        if let intent, intent.kind == .refresh || monitor.availableAssistants.contains(monitor.settings.automation.assistant),
                           let token = try? RemoteDigest.token([account, try RemoteDigest.token(intent), try RemoteDigest.token(monitor.settings.automation)]) {
                            card.actions.append(.init(id: "intent:\(intent.id)", kind: .prepare, token: token))
                        }
                        if let job = row.latestJob, row.stoppedJobNeedsAttention,
                           job.taskPrompt != nil, job.mergeRequestURL != nil,
                           let token = try? RemoteDigest.token([account, try RemoteDigest.token(job), try RemoteDigest.token(monitor.settings.automation)]) {
                            card.actions.append(.init(id: "job:\(job.id)", kind: .retryJob, token: token))
                        }
                    }
                } else if let todo = board.otherTodos.first(where: { "todo:\($0.id)" == card.id }),
                          monitor.isAssessingNotice(todo) {
                    card.needsAttention = false
                    card.actions = []
                    card.primaryCTA = nil
                    card.presentation = .init(repository: todo.project.pathWithNamespace.split(separator: "/").last.map(String.init) ?? "",
                        status: String(localized: .AutomationProgress.progressNotice), working: true)
                }
                result.lanes[lane].cards[index] = card
            }
        }
        result.updatedAt = monitor.lastRefresh
        result.automationPaused = !monitor.settings.automaticActionsAllowed
        result.partial = monitor.boardRefreshState != .current || monitor.lastError != nil
            || monitor.attention.hasError || monitor.authoredMergeRequests.hasError || monitor.isLoading
            || monitor.attention.isLoading || monitor.authoredMergeRequests.isLoading
        if result.partial {
            for lane in result.lanes.indices { for card in result.lanes[lane].cards.indices { result.lanes[lane].cards[card].actions = [] } }
        }
        return result
    }

    static func matchingMergeStatus(for row: MergeRequestBoardSnapshot.Row,
                                    statuses: [AuthoredMergeRequestStatus]) -> AuthoredMergeRequestStatus? {
        guard row.evidenceMatchesCatalogContext, let request = row.displayRequest else { return nil }
        return statuses.first { $0.matchesCurrentRequest(request) }
    }

    static func mergePresentation(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                                  status: AuthoredMergeRequestStatus?, evidenceMatchesCatalogContext: Bool = true,
                                  hasCurrentCatalog: Bool = true) -> RemoteCard {
        guard item.isAuthored, let request = item.mergeRequest, request.state == "opened" else { return original }
        let checked = hasCurrentCatalog && evidenceMatchesCatalogContext && status?.matchesCurrentRequest(request) == true ? status : nil
        let title: LocalizedStringResource
        let detail: String?
        let blocker: ManualMergeBlocker
        if let conflict = checked?.request.mergeTrainConflict, conflict.matches(request) {
            title = .MergeActions.mergeActionsTrainRebaseConflict
            detail = conflict.noteURL.absoluteString
            blocker = .prerequisite(.conflicts)
        } else if checked?.request.mergeTrainEvidenceUnavailable == true {
            title = .MergeActions.mergeActionsTrainEvidenceUnavailable
            detail = nil
            blocker = .prerequisite(.unknown)
        } else if let stateTitle = checked?.submissionState.title {
            title = stateTitle
            detail = String(localized: .MergeActions.mergeActionsConfirmHelp)
            blocker = .submission
        } else {
            let currentBlocker: ManualMergeBlocker? = !evidenceMatchesCatalogContext ? .context
                : !hasCurrentCatalog ? .checking : item.manualMergeBlocker(using: status)
            guard let currentBlocker else { return original }
            if original.presentation?.working == true {
                var busy = original
                busy.actions.removeAll { [.merge, .enqueueMerge].contains($0.kind) }
                return busy
            }
            title = currentBlocker.title
            detail = nil
            blocker = currentBlocker
        }
        var card = original
        card.presentation = card.presentation ?? .init(repository: request.webURL.gitLabProjectPath.split(separator: "/").last.map(String.init) ?? "")
        card.presentation?.status = String(localized: title)
        if let detail { card.detail = detail }
        else if card.detail.isEmpty { card.detail = String(localized: title) }
        card.actions.removeAll { [.merge, .enqueueMerge].contains($0.kind) }
        if card.primaryCTA == nil {
            if case .feedback = blocker {
                card.primaryCTA = .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewFeedback), destination: .feedback)
            } else {
                card.primaryCTA = .init(title: String(localized: .Board.boardDetails), destination: .overview)
            }
        }
        return card
    }

    static func mergeActions(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                             status: AuthoredMergeRequestStatus?, monitor: TodoMonitorService, account: String,
                             evidenceMatchesCatalogContext: Bool = true) -> RemoteCard {
        var card = original
        guard item.isAuthored, item.mergeRequest?.author.username == monitor.glab.currentUsername,
              let request = item.mergeRequest, request.state == "opened",
              let token = try? RemoteDigest.token([account, try RemoteDigest.token(request),
                  item.observedDiscussionFingerprint ?? "", try MergeSubmissionFingerprint.configuration(monitor.settings)]) else { return card }
        if evidenceMatchesCatalogContext, let status, item.canOfferManualMerge(using: status), let action = status.action {
            let kind: RemoteActionKind = action == .mergeNow ? .merge : .enqueueMerge
            card.actions.append(.init(id: kind.rawValue, kind: kind, token: token,
                confirmationText: String(localized: .MergeActions.mergeActionsConfirmHelp)))
        }
        if item.draftCount == 0, item.drafts.isEmpty, !item.requiresDiscussionRecheck,
           item.needsDiscussion || item.hasOtherUnresolvedDiscussions || request.blockingDiscussionsResolved == false {
            card.actions.append(.init(id: "checkThreads", kind: .checkThreads, token: token,
                confirmationText: String(localized: .MergeActions.mergeActionsResolveHelp)))
        }
        return card
    }

    static func resolutionPreview(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                                  prepared: ManualDiscussionResolution.Prepared, monitor: TodoMonitorService) -> RemoteCard {
        guard let check = original.actions.first(where: { $0.kind == .checkThreads }),
              let request = item.authoredRequest, prepared.revision == monitor.glab.accountRevision,
              prepared.host == monitor.glab.resolvedHost, prepared.user.username == monitor.glab.currentUsername,
              MergeRequestDependencySummary.Context(request) == .init(prepared.request),
              request.semanticContextFingerprint == prepared.request.semanticContextFingerprint,
              prepared.reviewFingerprint != nil, prepared.reviewFingerprint == item.observedDiscussionFingerprint,
              (try? MergeSubmissionFingerprint.configuration(monitor.settings)) == prepared.configuration else { return original }
        var card = original
        let ids = prepared.plan.eligibleIDs
        card.detail = String(localized: .MergeActions.mergeActionsResolvePreview(ids.count, prepared.plan.heldIDs.count))
        guard !ids.isEmpty, let fingerprint = prepared.plan.fingerprint,
              let token = try? RemoteDigest.token([check.token, fingerprint, ids.joined(separator: ",")]) else { return card }
        card.actions.removeAll { $0.kind == .checkThreads }
        card.actions.append(.init(id: ManualDiscussionResolution.actionID(ids), kind: .resolveThreads, token: token,
            confirmationText: card.detail + "\n\n" + prepared.plan.confirmationDetails + "\n\n"
                + String(localized: .MergeActions.mergeActionsResolveHelp)))
        return card
    }

    static func project(board: MergeRequestBoardSnapshot, other: [MergeRequestBoardSnapshot.OtherCard], session: UUID, account: String,
                        intents: [MRTodoIntent] = [], conflictReceipts: Set<MergeConflictReceipt> = []) -> RemoteBoard {
        let others = other.compactMap { entry -> RemoteCard? in
            switch entry.content {
            case .completion(let completion): return card(completion, account: account)
            case .proposal(let proposal):
                var card = proposal.item.map { self.card($0, account: account) }
                    ?? RemoteCard(id: "mr:\(proposal.target.projectID):\(proposal.target.iid ?? 0)", title: proposal.title,
                        project: proposal.url.gitLabProjectPath, url: proposal.url)
                card.actions = []
                card.detail = String(localized: .Remote.remoteProposal)
                return jobProgress(card, job: proposal.latestJob, intents: proposal.intents + intents, conflictReceipts: conflictReceipts)
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
                return jobProgress(card, job: job, intents: intents, conflictReceipts: conflictReceipts)
            }
        }
        return .init(hostSession: session, account: account, lanes: [
            .init(id: .own, cards: board.own.map { presentation(card($0.item, account: account), row: $0, allowsRemoval: false) }),
            .init(id: .reviewed, cards: board.reviewed.map { presentation(card($0.item, account: account), row: $0, allowsRemoval: true) }),
            .init(id: .other, cards: others),
        ])
    }

    private static func jobProgress(_ original: RemoteCard, job: AssistantAutomationRunner.Handoff?,
                                    intents: [MRTodoIntent], conflictReceipts: Set<MergeConflictReceipt>) -> RemoteCard {
        guard let job, job.operationalExecution?.state.isActive == true else { return original }
        var card = original
        card.needsAttention = false
        card.actions = []
        card.primaryCTA = nil
        card.mergeRequestIID = job.key.work.iid
        card.presentation = .init(repository: card.project.split(separator: "/").last.map(String.init) ?? "",
            status: String(localized: job.progressTitle(intents: intents, conflictReceipts: conflictReceipts)), working: true)
        return card
    }

    static func presentation(_ original: RemoteCard, row: MergeRequestBoardSnapshot.Row,
                             assistantReady: Bool = true, allowsRemoval: Bool? = nil,
                             confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
                             automaticallyPublishedDraftIDs: Set<Int> = [],
                             reviewing: ReviewingContext? = nil, busy: Bool = false) -> RemoteCard {
        let model = MRCardPresentation(row: row,
            reviewingContext: reviewing ?? ReviewingContext(row: row, assistantReady: assistantReady),
            allowsRemoval: allowsRemoval ?? !row.item.isAuthored, assistantReady: assistantReady,
            confirmationState: confirmationState, automaticallyPublishedDraftIDs: automaticallyPublishedDraftIDs,
            automaticConflictProgress: busy)
        return presentation(original, model: model)
    }

    static func presentation(_ original: RemoteCard, model: MRCardPresentation) -> RemoteCard {
        var card = original
        card.title = model.row.displayTitle
        card.project = model.row.displayURL.gitLabProjectPath
        card.url = model.row.displayURL
        card.head = model.row.displayRequest?.sha
        card.contextRevision = model.row.displayRequest.flatMap(contextRevision)
        card.dependencies = dependencyPresentation(model.row.displayItem.dependencies, projectID: model.row.id.projectID)
        card.approvals = model.row.displayItem.approvalProgress.flatMap {
            .init(completed: min($0.completed, $0.required), required: $0.required,
                received: $0.completed, requirementsSatisfied: $0.requirementsSatisfied)
        }
        if !model.row.evidenceMatchesCatalogContext {
            card.actions.removeAll { [.publish, .approve, .reReview, .merge, .enqueueMerge].contains($0.kind) }
        }
        let human = model.humanAction
        card.needsAttention = human != nil
        card.mergeRequestIID = model.row.id.iid
        card.detail = model.message
        card.primaryCTA = model.actionLabel.map { label in
            let destination: RemoteCardCTA.Destination
            if let human { destination = human.remoteDestination }
            else {
                destination = switch model.reviewingContext.nextStep {
                case .reviewComments: .drafts
                case .viewRun: .assistantRuns
                case .setupAgent: .setup
                case .runReview: model.assistantReady ? .overview : .setup
                default: .feedback
                }
            }
            return .init(title: String(localized: label), destination: destination)
        }
        let author = ReviewingContext(row: model.row).author.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.username : $0.name
        }
        card.presentation = .init(author: author,
            repository: card.project.split(separator: "/").last.map(String.init) ?? card.project,
            draftBadge: MergeRequestFinishedState(model.row.displayRequest).map { String(localized: $0.badge) }
                ?? (model.row.isDraft ? String(localized: .Menu.menuMrDraftBadge) : nil),
            status: model.status, nextStep: model.nextStep, working: model.working,
            chips: model.chips.map { .init(title: String(localized: $0.title), symbol: $0.symbol) },
            secondaryCTA: human?.action == .retryRun ? .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewRun), destination: .assistantRuns) : nil)
        if model.actionsBlocked { card.actions = [] }
        return card
    }

    static func contextRevision(_ request: GitLabMergeRequest) -> String? {
        guard let identity = try? RemoteDigest.token(MergeRequestDependencySummary.Context(request)) else { return nil }
        return try? RemoteDigest.token([identity, request.semanticContextFingerprint, String(describing: request.draft),
            String(request.author.id), request.author.username])
    }

    static func detail(_ item: MergeRequestAttentionMonitor.Item) -> String {
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

private extension MRHumanAction {
    var remoteDestination: RemoteCardCTA.Destination {
        switch action {
        case .reviewDrafts: .drafts
        case .reviewApproval: .actions
        case .reviewRun, .retryRun: .assistantRuns
        case .retryDraftVerification: .drafts
        case .setupAssistant: .setup
        case .reviewDecision, .reviewFeedback, .handleFeedback, .verifyFeedback: .feedback
        case .reviewHandoff, .reviewMerge, .reviewIssue, .retryIntent: .overview
        }
    }
}
