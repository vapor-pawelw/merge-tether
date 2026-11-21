import Foundation
import MergeTetherRemote

@MainActor enum RemoteBoardAdapter {
    static func card(_ completion: MergeRequestLifecycleLedger.CompletionReceipt, account: String) -> RemoteCard {
        let state = completion.kind == .merged ? MergeRequestFinishedState.merged : .closed
        var card = RemoteCard(id: "completion:\(completion.id)", title: completion.title,
            project: completion.url.gitLabProjectPath, url: completion.url,
            detail: String(localized: completion.kind == .merged ? .MRLifecycle.completionMerged : .MRLifecycle.completionClosed),
            needsAttention: false, mergeRequestIID: completion.target.iid,
            presentation: .init(author: completion.author?.person.displayName,
                repository: completion.url.gitLabProjectPath.split(separator: "/").last.map(String.init) ?? "",
                draftBadge: String(localized: state.badge),
                authorUsername: completion.author?.username, authorAvatarURL: completion.author?.avatarURL),
            completionObservedAt: completion.observedAt)
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
            let recipients = draft.discussionID.flatMap { item.replyRecipients[$0] }?.map(\.remotePerson)
            return RemoteDraft(id: draft.id ?? (-1 - index), body: draft.note ?? "", context: context,
                publicationWarnings: DraftPublicationRisk(draft: draft)?.messages.map { String(localized: $0) },
                replyRecipients: recipients?.isEmpty == false ? recipients : nil)
        }
        var card = RemoteCard(id: "mr:\(item.id.projectID):\(item.id.iid)", title: item.title,
            project: item.url.gitLabProjectPath, url: item.url,
            head: item.mergeRequest?.sha, detail: detail(item), drafts: drafts)
        card.contextRevision = item.mergeRequest.flatMap(contextRevision)
        card.dependencies = .init(summary: item.dependencies, projectID: item.id.projectID)
        let publishable = item.publishAllDrafts
        var kinds = extraActions.filter { $0 != .verify }
        if item.mergeRequest?.sha != nil {
            if item.draftCount == drafts.count, !publishable.isEmpty, !item.requiresDiscussionRecheck,
               item.drafts.allSatisfy({ $0.id != nil && AICommentAssessmentStore.safeForAutomaticPublication($0) }) { kinds.append(.publish) }
            if item.canApprove { kinds.append(.approve) }
            if item.canConfirmReReview, item.reReviewReadiness?.canConfirm == true { kinds.append(.reReview) }
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
                guard let kind = RemoteActionKind(rawValue: raw) else { return nil }
                if kind == .publish {
                    let draftIDs = publishable.compactMap(\.id).map(String.init)
                    guard let publicationToken = try? RemoteDigest.token([token] + draftIDs) else { return nil }
                    return RemoteAction(id: raw, kind: kind, token: publicationToken)
                }
                if kind == .reReview {
                    let message = ([String(localized: .Menu.menuReReviewConfirmMessage)]
                        + (item.reReviewReadiness?.manualConfirmationDetails ?? [])).joined(separator: "\n\n")
                    guard let readinessToken = try? RemoteDigest.token([token, message]) else { return nil }
                    return RemoteAction(id: raw, kind: kind, token: readinessToken, confirmationText: message,
                        label: String(localized: .Menu.menuReReviewConfirm))
                }
                return RemoteAction(id: raw, kind: kind, token: token)
            }
            for retry in MRVerificationRetry.allCases where retry.isAvailable(for: item) {
                guard let retryToken = try? RemoteDigest.token([token, retry.rawValue]) else { continue }
                card.actions.append(.init(id: retry.rawValue, kind: .verify, token: retryToken,
                    confirmationText: retry.effect.help, label: String(localized: retry.label)))
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
        if item.approvalProgress != nil || item.mergeRequest != nil {
            let username = String(account.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let approvals = RemoteApprovalDetails(progress: item.approvalProgress,
                reviewers: item.mergeRequest?.reviewers ?? [], viewerUsername: username,
                isOwnMergeRequest: item.isAuthored || item.mergeRequest == nil
                    || item.mergeRequest?.author.username.lowercased() == username.lowercased())
            card.presentation = .init(repository: card.project.split(separator: "/").last.map(String.init) ?? card.project,
                approvalPeople: approvals.people, viewerApprovalID: approvals.viewerApprovalID,
                assignedReviewerCount: MergeRequestApprovalProgress.assignedReviewerCount(item.mergeRequest?.reviewers))
        }
        return card
    }

    static func boardOrderCardID(_ target: MRAutomationScope.Target) -> String {
        "mr:\(target.projectID):\(target.iid ?? 0)"
    }

    static func board(monitor: TodoMonitorService, session: UUID, account: String,
                      includesBoardOrder: Bool = false) -> RemoteBoard {
        let board = monitor.boardSnapshot
        let other = board.otherCards(jobs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost,
            username: monitor.glab.currentUsername, pinnedCards: monitor.settings.boardPins)
        var result = project(board: board, other: other, session: session, account: account,
            intents: monitor.settings.mrActionIntents, conflictReceipts: monitor.settings.conflictReceipts)
        var orderGroups: [String: RemoteBoardOrderGroup] = [:]
        if includesBoardOrder {
            for (group, entries) in Dictionary(grouping: board.manualOrderEntries, by: \.group) {
                let ids = entries.map { boardOrderCardID($0.target) }
                let orderGroup = RemoteBoardOrderGroup(lane: group.reviewing ? .reviewed : .own,
                    automationEnabled: group.automationEnabled, pinned: group.pinned, cardIDs: ids)
                for id in ids { orderGroups[id] = orderGroup }
            }
        }
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
                    let presentation = MRCardPresentation(row: row, monitor: monitor, allowsRemoval: result.lanes[lane].id == .reviewed)
                    let humanAction = presentation.humanAction
                    let feedbackIDs = item.authorFeedbackStatus?.followUpNoteIDs.sorted().map(String.init) ?? []
                    if humanAction?.action == .handleFeedback, !feedbackIDs.isEmpty { extras.append(.prepare) }
                    let context = handoffs.map(\.id).sorted() + [(try? RemoteDigest.token(monitor.settings.automation)) ?? "",
                        item.authorFeedbackStatus?.fingerprint ?? ""] + feedbackIDs
                    card = self.card(item, account: account, extraActions: extras, context: context)
                    card = self.presentation(card, model: presentation)
                    if let head = card.head, let host = monitor.glab.resolvedHost,
                       let username = monitor.glab.currentUsername, account == "\(username)@\(host)" {
                        let target = MRAutomationScope.Target(host: host, username: username, projectID: item.id.projectID, iid: item.id.iid)
                        if monitor.settings.hasAutomaticApprovalWithOpenFindings(for: target, head: head) {
                            card.presentation?.approvedWithOpenFindings = true
                        }
                        if monitor.settings.independentApprovalPreferences[target] == .off {
                            card.presentation?.automaticApprovalOff = true
                        }
                    }
                    if row.displayRequest?.state == "merged" || row.displayRequest?.state == "closed" {
                        card.actions = []
                        result.lanes[lane].cards[index] = card
                        continue
                    }
                    let mergeStatus = monitor.authoredMergeRequests.hasSyncedCurrentCatalog
                        ? matchingMergeStatus(for: row, statuses: monitor.authoredMergeRequests.requests) : nil
                    card = mergePresentation(card, item: item, status: mergeStatus,
                        evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext,
                        hasCurrentCatalog: monitor.authoredMergeRequests.hasSyncedCurrentCatalog,
                        waitingStatus: presentation.waitingStatus)
                    let busy = presentation.actionsBlocked
                    if busy { card.actions = [] }
                    else {
                        if let action = personalApprovalAction(for: row, monitor: monitor, account: account) {
                            card.actions.append(action)
                        }
                        if let request = row.displayRequest, monitor.canEditReviewers(of: request),
                           let context = contextRevision(request), let token = try? RemoteDigest.token([account, context]) {
                            card.actions.append(.init(id: RemoteActionKind.editReviewers.rawValue, kind: .editReviewers, token: token))
                        }
                        let jobPublication = monitor.manualReviewConsent(for: item).publicationMode
                        card = mergeActions(card, item: item, status: mergeStatus, monitor: monitor, account: account,
                            evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext)
                        let intent = humanAction?.retryIntent
                            ?? row.attentionIntents.first { $0.state == .failed && !row.isReconciling($0) }
                            ?? row.attentionIntents.first { $0.state == .pending && !$0.isDeferredReview }
                        if let intent,
                           intent.kind == .refresh || monitor.availableAssistants.contains(monitor.settings.automation.assistant),
                           let configuration = try? RemoteDigest.token(monitor.settings.automation) {
                            let publication = monitor.manualReviewConsent(for: monitor.reviewRequest(for: intent)).publicationMode
                            if let token = try? RemoteDigest.token([account, try RemoteDigest.token(intent), configuration, publication.rawValue]) {
                                let label = String(localized: MRHumanAction.intentLabel(intent))
                                let effect = MRActionCTA(intent: intent.kind) ?? .refreshFromGitLab
                                let variant = intent.state == .failed ? "retry" : "start"
                                let reviewMode = intent.kind == .review ? publication.rawValue : nil
                                let confirmation = effect.help + (intent.kind == .review
                                    ? "\n\n" + String(localized: publication.reviewConfirmation) : "")
                                card.actions.append(.init(id: "intent:\(intent.id)", kind: .prepare, token: token,
                                    confirmationText: confirmation, label: label,
                                    confirmationID: effect.confirmationID(variant: [variant, reviewMode].compactMap { $0 }.joined(separator: "."))))
                            }
                        }
                        if let job = humanAction?.retryJob ?? row.latestJob, row.stoppedJobNeedsAttention,
                           job.taskPrompt != nil, job.mergeRequestURL != nil,
                           let token = try? RemoteDigest.token([account, try RemoteDigest.token(job),
                               try RemoteDigest.token(monitor.settings.automation), jobPublication.rawValue]) {
                            let label = String(localized: MRHumanAction.retryLabel(job))
                            let reviewMode = job.workflow == .review ? jobPublication.rawValue : nil
                            let confirmation = MRActionCTA.retryRun.help + (job.workflow == .review
                                ? "\n\n" + String(localized: jobPublication.reviewConfirmation) : "")
                            card.actions.append(.init(id: "job:\(job.id)", kind: .retryJob, token: token,
                                confirmationText: confirmation, label: label,
                                confirmationID: MRActionCTA.retryRun.confirmationID(variant:
                                    [job.retryConfirmationVariant, reviewMode].compactMap { $0 }.joined(separator: "."))))
                        }
                    }
                    card.actions += mrControls(item: item, row: row, monitor: monitor, account: account, busy: busy)
                    if let control = commentOriginControl(item: item, monitor: monitor, account: account) { card.actions.append(control) }
                    card = bindingPrimaryAction(card, humanAction: humanAction?.action,
                        actionID: humanAction?.executableActionID, nextStep: presentation.reviewingContext.nextStep)
                } else if let todo = board.otherTodos.first(where: { "todo:\($0.id)" == card.id }),
                          monitor.isAssessingNotice(todo) {
                    card.needsAttention = false
                    card.actions = []
                    card.primaryCTA = nil
                    card.presentation = .init(repository: todo.project.pathWithNamespace.split(separator: "/").last.map(String.init) ?? "",
                        status: MRActivity.agentStatus(.AutomationProgress.progressNotice, assistant: monitor.settings.automation.assistant),
                        working: true, statusSymbol: MRActionEffect.aiCheck.symbol)
                }
                card.orderGroup = orderGroups[card.id]
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

    static func personalApprovalAction(for row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService,
                                       account: String) -> RemoteAction? {
        guard row.evidenceMatchesCatalogContext, let request = row.displayRequest,
              let change = monitor.attention.personalApprovalAction(for: row),
              let context = contextRevision(request) else { return nil }
        let kind: RemoteActionKind = change == .approve ? .personalApprove : .removeApproval
        guard let token = try? RemoteDigest.token([account, context, kind.rawValue]) else { return nil }
        return .init(id: kind.rawValue, kind: kind, token: token, confirmationText: String(localized: change.confirmation))
    }

    static func mergePresentation(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                                  status: AuthoredMergeRequestStatus?, evidenceMatchesCatalogContext: Bool = true,
                                  hasCurrentCatalog: Bool = true, waitingStatus: MRWaitingStatus? = nil) -> RemoteCard {
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
        } else if let stateTitle = checked?.displayedSubmissionState.title {
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
        let dependencyHold = waitingStatus?.hasCurrentDependencyHold == true
            && checked?.request.detailedMergeStatus == "merge_request_blocked"
        let knownMergeFailure = checked?.blockers.contains { reason in
            switch reason {
            case .draft, .unpublishedDrafts, .commentReview, .conflictTaskFailed, .conflicts, .pipeline,
                 .stackTarget, .dependencyEvidence, .checking: true
            case .other: !dependencyHold
            default: false
            }
        } == true
        let ordinaryWait: Bool
        switch blocker {
        case .checking, .capability, .prerequisite(.approvals), .prerequisite(.discussions),
             .prerequisite(.changesRequested), .prerequisite(.dependencies): ordinaryWait = true
        case .prerequisite(.other): ordinaryWait = dependencyHold
        default: ordinaryWait = false
        }
        let showsWaiting = ordinaryWait && !knownMergeFailure && hasCurrentCatalog && evidenceMatchesCatalogContext
        let status = String(localized: showsWaiting ? waitingStatus?.title ?? title : title)
        card.presentation?.status = status
        card.presentation?.statusPeopleMessage = nil
        if showsWaiting, let waitingStatus, !waitingStatus.requirements.isEmpty {
            // Like the Mac card: one requirement per line, with an uncovered blocker joining the list.
            var lines = waitingStatus.requirements.map { String(localized: $0) }
            let covered: Bool = if case .prerequisite(let reason) = blocker { waitingStatus.coveredBlockers.contains(reason) } else { false }
            if !covered, !lines.contains(String(localized: title)) { lines.append(String(localized: title)) }
            card.presentation?.requirements = lines
            card.presentation?.requirementPeopleMessage = waitingStatus.reviewerPeopleMessage
            let people = waitingStatus.threadResolutionPeople
            card.presentation?.threadResolutionPeople = people.isEmpty ? nil : people.map(\.remotePerson)
        }
        if let detail { card.detail = detail }
        // The status line or requirement list already carries the blocker; the phone must not print it twice.
        else if card.presentation?.requirements == nil, card.detail.isEmpty, String(localized: title) != status {
            card.detail = String(localized: title)
        }
        card.actions.removeAll { [.merge, .enqueueMerge].contains($0.kind) }
        if card.primaryCTA == nil {
            if case .feedback = blocker {
                card.primaryCTA = .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewFeedback), destination: .feedback)
            } else {
                card.primaryCTA = .init(title: String(localized: .Board.boardDetails), destination: .overview)
            }
        }
        if evidenceMatchesCatalogContext, hasCurrentCatalog,
           let recovery = item.manualFeedbackRecovery(), recovery.recoveryAction != nil,
           checked?.submissionState.title == nil {
            if card.primaryCTA?.destination != .feedback, card.presentation?.secondaryCTA == nil {
                card.presentation?.secondaryCTA = .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewFeedback), destination: .feedback)
            }
            if !recovery.replySourceIDs.isEmpty {
                card.detail += "\n\n" + String(localized: .MergeActions.mergeActionsReplySources(recovery.replySourceIDs.count))
                if checked?.blockers.contains(.discussions) == true || request.blockingDiscussionsResolved == false {
                    card.detail += "\n\n" + String(localized: .MergeActions.mergeActionsResolveScope)
                }
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
                confirmationText: String(localized: .MergeActions.mergeActionsConfirmHelp) + "\n\n"
                    + String(localized: monitor.settings.automation.assistant.manualMergeVerificationDisclosure)))
        }
        if item.draftCount == 0, item.drafts.isEmpty, !item.requiresDiscussionRecheck,
           item.needsDiscussion || item.hasOtherUnresolvedDiscussions || request.blockingDiscussionsResolved == false {
            card.actions.append(.init(id: "checkThreads", kind: .checkThreads, token: token,
                confirmationText: String(localized: .MergeActions.mergeActionsResolveHelp)))
        }
        return card
    }

    /// One entry point for correcting comment origins. It writes only local evidence and stays available
    /// while the card is busy; the command names its comments and the host re-reads GitLab to match them.
    static func commentOriginControl(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService,
                                     account: String) -> RemoteAction? {
        guard let request = item.mergeRequest, request.state == "opened",
              monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) != nil,
              let token = try? RemoteDigest.token([account, "commentOrigin", String(request.projectID), String(request.iid)])
        else { return nil }
        return .init(id: "commentOrigin", kind: .setCommentOrigin, token: token)
    }

    /// Mac-detail controls offered to the phone. Each token binds the MR, its conversation and the
    /// automation settings, so any change since the phone's snapshot rejects the command as changed.
    static func mrControls(item: MergeRequestAttentionMonitor.Item, row: MergeRequestBoardSnapshot.Row,
                           monitor: TodoMonitorService, account: String, busy: Bool) -> [RemoteAction] {
        guard let request = item.mergeRequest, request.state == "opened", row.evidenceMatchesCatalogContext,
              let base = try? RemoteDigest.token([account, try RemoteDigest.token(request),
                  item.observedDiscussionFingerprint ?? "", try RemoteDigest.token(monitor.settings.automation)]) else { return [] }
        func token(_ parts: [String]) -> String? { try? RemoteDigest.token([base] + parts) }
        var actions: [RemoteAction] = []
        // Stopping stays available while the run makes the card busy; it never writes to GitLab.
        if let job = row.latestJob, job.execution?.state.isActive == true, let token = token(["stop", job.id.uuidString]) {
            actions.append(.init(id: "stopJob:\(job.id)", kind: .stopJob, token: token,
                confirmationText: String(localized: .Remote.remoteStopJobHelp)))
        }
        guard !busy, row.latestJob?.execution?.state.isActive != true else { return actions }
        if monitor.canMarkMergeRequestReady(item), let token = token(["markReady"]) {
            actions.append(.init(id: "markReady", kind: .markReady, token: token,
                confirmationText: String(localized: .Remote.remoteMarkReadyHelp)))
        }
        let reviewConsent = monitor.manualReviewConsent(for: item)
        if monitor.canRunReview(for: item), let token = token(["review", request.sha ?? "", reviewConsent.publicationMode.rawValue]) {
            actions.append(.init(id: "runReview", kind: .runReview, token: token,
                confirmationText: String(localized: .Remote.remoteRunReviewHelp) + "\n\n"
                    + String(localized: reviewConsent.publicationMode.reviewConfirmation),
                confirmationID: MRActionCTA.runReview.confirmationID(variant: reviewConsent.publicationMode.rawValue)))
        }
        if item.commentReviewSnapshot != nil {
            for draft in item.drafts {
                // Quick actions and thread resolution stay a Mac decision, where every effect is shown.
                guard let id = draft.id, id > 0, DraftPublicationRisk(draft: draft) == nil,
                      !(draft.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let draftToken = try? RemoteDigest.token(draft), let token = token(["draft", draftToken]) else { continue }
                actions.append(.init(id: "publishDraft:\(id)", kind: .publishDraft, token: token,
                    confirmationText: String(localized: .Remote.remotePublishDraftHelp)))
            }
        }
        guard request.sha?.isEmpty == false, item.observedDiscussionFingerprint != nil,
              let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return actions }
        let ignored = monitor.settings.feedbackSuggestionDecisions.entries(for: target)
        for suggestion in ignorableSuggestions(item) where !ignored.contains(where: { $0.sourceNoteID == suggestion.noteID }) {
            guard let token = token(["ignore", String(suggestion.findingID), String(suggestion.noteID),
                                     suggestion.summary, suggestion.reason]) else { continue }
            actions.append(.init(id: "ignoreSuggestion:\(suggestion.findingID)", kind: .ignoreSuggestion, token: token,
                confirmationText: suggestion.summary + "\n\n" + suggestion.reason + "\n\n" + String(localized: .Remote.remoteIgnoreSuggestionHelp),
                label: suggestion.summary))
        }
        for decision in ignored {
            guard let token = token(["restore", decision.id.uuidString, decision.sourceRevision]) else { continue }
            actions.append(.init(id: "restoreSuggestion:\(decision.id)", kind: .restoreSuggestion, token: token,
                confirmationText: decision.concernSummary + "\n\n" + String(localized: .Remote.remoteRestoreSuggestionHelp),
                label: decision.concernSummary))
        }
        return actions
    }

    struct IgnorableSuggestion: Equatable {
        let findingID: Int, noteID: Int, summary: String, reason: String
    }

    /// The same findings the Mac detail offers to ignore: current, explained, and still asking for work.
    static func ignorableSuggestions(_ item: MergeRequestAttentionMonitor.Item) -> [IgnorableSuggestion] {
        guard let request = item.mergeRequest, let status = item.authorFeedbackStatus,
              status.phase == .complete || status.phase == .waitingPublication,
              !status.head.isEmpty, status.head == request.sha,
              status.semanticContextFingerprint == request.semanticContextFingerprint,
              status.fingerprint == item.observedDiscussionFingerprint else { return [] }
        return status.displayFindings.compactMap { finding in
            guard let noteID = finding.sourceNoteID,
                  let reason = finding.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty,
                  finding.state == .needsChanges || finding.state == .needsVerification
                    || status.followUpNoteIDs.contains(noteID) || status.replyNoteIDs.contains(noteID) else { return nil }
            return .init(findingID: finding.id, noteID: noteID,
                summary: AgentExplanation.summary(finding.summary) ?? reason, reason: reason)
        }
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
            status: job.progressStatus(intents: intents, conflictReceipts: conflictReceipts),
            working: true, statusSymbol: MRActionEffect.agent.symbol,
            assignedReviewerCount: original.presentation?.assignedReviewerCount)
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
        card.dependencies = .init(summary: model.row.displayItem.dependencies, projectID: model.row.id.projectID)
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
                case .runReview: model.assistantReady ? .actions : .setup
                case .viewDiscussions, .monitoring: .discussions
                default: .feedback
                }
            }
            return .init(title: String(localized: destination == .setup ? .Remote.remoteSetupActionOnMac : label), destination: destination)
        }
        let author: Todo.Author? = ReviewingContext(row: model.row).author
        let authorName: String? = author?.person.displayName
        let authorUsername: String? = author?.username
        let authorAvatarURL: URL? = author?.avatarURL
        let draftBadge = MergeRequestFinishedState(model.row.displayRequest).map { String(localized: $0.badge) }
            ?? (model.row.isDraft ? String(localized: .Menu.menuMrDraftBadge) : nil)
        let chips: [RemoteCardChip] = model.chips.map { .init(title: String(localized: $0.title), symbol: $0.symbol) }
        let steps = model.stepChain.map { $0.steps.map { String(localized: $0) } }
        let pendingDrafts = model.working ? nil : MRPendingDraftsSummary(item: model.row.item)
        card.presentation = .init(author: authorName,
            repository: card.project.split(separator: "/").last.map(String.init) ?? card.project,
            draftBadge: draftBadge,
            status: model.status, nextStep: model.nextStep, working: model.working,
            chips: chips,
            secondaryCTA: human?.action == .retryRun ? .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewRun), destination: .assistantRuns) : nil,
            authorUsername: authorUsername, authorAvatarURL: authorAvatarURL,
            steps: steps, currentStep: model.stepChain?.current,
            pendingDrafts: pendingDrafts.map { String(localized: $0.message) }, statusSymbol: model.activityEffect?.symbol,
            approvalPeople: model.row.evidenceMatchesCatalogContext ? original.presentation?.approvalPeople : nil,
            viewerApprovalID: model.row.evidenceMatchesCatalogContext ? original.presentation?.viewerApprovalID : nil,
            assignedReviewerCount: MergeRequestApprovalProgress.assignedReviewerCount(model.row.displayRequest?.reviewers))
        card.presentation?.statusPeopleMessage = model.statusPeopleMessage
        card.presentation?.pendingDraftsPeopleMessage = pendingDrafts?.peopleMessage
        if model.actionsBlocked { card.actions = [] }
        return card
    }

    static func bindingPrimaryAction(_ original: RemoteCard, humanAction: MRHumanAction.Action?,
                                     actionID: String? = nil, nextStep: ReviewingContext.NextStep) -> RemoteCard {
        var card = bindingExecutableAction(original, humanAction: humanAction, actionID: actionID, nextStep: nextStep)
        if let ready = card.actions.first(where: { $0.kind == .markReady }) {
            let cta = RemoteCardCTA(title: String(localized: .Remote.remoteMarkReady), destination: .actions, actionID: ready.id)
            if card.primaryCTA == nil || card.primaryCTA?.destination == .overview { card.primaryCTA = cta }
            else if card.presentation?.secondaryCTA == nil {
                card.presentation = card.presentation ?? .init(repository: card.project)
                card.presentation?.secondaryCTA = cta
            }
        }
        return card
    }

    private static func bindingExecutableAction(_ original: RemoteCard, humanAction: MRHumanAction.Action?,
                                                actionID: String?, nextStep: ReviewingContext.NextStep) -> RemoteCard {
        guard let cta = original.primaryCTA, cta.destination != .setup else { return original }
        let kind: RemoteActionKind
        switch humanAction {
        case .retryRun: kind = .retryJob
        case .verifyFeedback, .retryDraftVerification, .retryReReview: kind = .verify
        case .handleFeedback, .retryIntent: kind = .prepare
        case nil where nextStep == .runReview: kind = .runReview
        default: return original
        }
        var card = original
        let expectedID = actionID ?? (humanAction == nil && nextStep == .runReview ? "runReview" : nil)
        let matches = card.actions.filter { $0.kind == kind && $0.id == expectedID }
        card.primaryCTA?.destination = .actions
        if matches.count == 1 {
            card.primaryCTA?.actionID = matches[0].id
        } else {
            card.primaryCTA?.title = String(localized: .Remote.remoteActionOnMac)
        }
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

extension RemoteMRDependencies {
    init?(summary: MergeRequestDependencySummary?, projectID: Int) {
        guard let summary, summary.hasPresentation else { return nil }
        self.init(stackPosition: summary.stackPosition, predecessors: summary.predecessors.map { predecessor in
            var sources: [RemoteMRPredecessor.Source] = []
            if predecessor.sources.contains(.stack) { sources.append(.stack) }
            if predecessor.sources.contains(.gitLab) { sources.append(.gitLab) }
            return .init(reference: predecessor.reference(relativeTo: projectID), title: predecessor.title,
                url: predecessor.url, isCurrent: predecessor.isCurrent, sources: sources)
        }, notice: summary.notice)
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
        case .reviewDecision, .reviewFeedback, .handleFeedback, .verifyFeedback, .retryReReview: .feedback
        case .reviewHandoff, .reviewMerge, .retryIntent: .actions
        case .reviewIssue: .overview
        }
    }
}
