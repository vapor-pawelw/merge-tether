import Foundation
import MergeTetherRemote

@MainActor enum RemoteBoardAdapter {
    static func card(_ completion: MergeRequestLifecycleLedger.CompletionReceipt, account: String) -> RemoteCard {
        let state = completion.kind == .merged ? MergeRequestFinishedState.merged : .closed
        let project = completion.url.gitLabProjectPath
        let repository = String(project.split(separator: "/").last ?? "")
        let detail: LocalizedStringResource = completion.kind == .merged ? .MRLifecycle.completionMerged : .MRLifecycle.completionClosed
        let presentation = RemoteCardText(author: completion.author?.person.displayName, repository: repository,
            draftBadge: String(localized: state.badge),
            authorUsername: completion.author?.username, authorAvatarURL: completion.author?.avatarURL)
        var card = RemoteCard(id: "completion:\(completion.id)", title: completion.title,
            project: project, url: completion.url, detail: String(localized: detail),
            needsAttention: false, mergeRequestIID: completion.target.iid, presentation: presentation,
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

    static func card(_ review: HiddenReview, notice: HiddenReview.InboxNotification, account: String) -> RemoteCard {
        let project = review.url.gitLabProjectPath
        let title = String(localized: .Board.boardReviewAssignmentRestore)
        let detail = [String(localized: .ReviewIntake.reviewIntakeHiddenByVerifier), notice.reason ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        // Paired devices already display completion receipts in Inbox updates.
        var card = RemoteCard(id: "completion:\(notice.id)", title: review.title, project: project, url: review.url,
            detail: detail, needsAttention: false, mergeRequestIID: review.target.iid, completionObservedAt: notice.observedAt)
        if let token = try? RemoteDigest.token([account, card.id, try RemoteDigest.token(review)]) {
            card.actions = [
                .init(id: "seen", kind: .markDone, token: token, label: String(localized: .ReviewIntake.reviewIntakeMarkSeen)),
                .init(id: "restore", kind: .markDone, token: token, label: title),
            ]
            card.presentation = .init(repository: project.split(separator: "/").last.map(String.init) ?? project,
                secondaryCTA: .init(title: title, destination: .actions, actionID: "restore"))
        }
        return card
    }

    static func handleHiddenReviewNotification(_ card: RemoteCard, action: RemoteAction,
                                                monitor: TodoMonitorService, account: String) -> Bool {
        guard action.kind == .markDone, card.id.hasPrefix("completion:"),
              let id = UUID(uuidString: String(card.id.dropFirst("completion:".count))),
              let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername, account == "\(username)@\(host)",
              let review = monitor.hiddenReviewNotifications.first(where: { $0.inboxNotification?.id == id }),
              let notice = review.inboxNotification, self.card(review, notice: notice, account: account).actions.contains(action)
        else { return false }
        switch action.id {
        case "seen": return monitor.acknowledgeHiddenReviewNotifications([id])
        case "restore": return monitor.restoreHiddenReviewNotification(id: id)
        default: return false
        }
    }

    private static func hiddenAssignmentCard(_ review: HiddenReview, account: String, monitor: TodoMonitorService,
                                             includesCardActions: Bool = false) -> RemoteCard {
        let display = monitor.hiddenReviewDisplay(review)
        let request = display.request
        var card = RemoteCard(id: hiddenAssignmentCardID(review),
            title: request?.title ?? review.title, project: review.url.gitLabProjectPath, url: review.url,
            mergeRequestIID: review.target.iid)
        if let request {
            card.presentation = .init(author: request.author.name, repository: card.project.split(separator: "/").last.map(String.init) ?? card.project,
                authorUsername: request.author.username, authorAvatarURL: request.author.avatarURL,
                assignedReviewerCount: MergeRequestApprovalProgress.assignedReviewerCount(request.reviewers))
        }
        card.approvals = display.approvals.flatMap {
            .init(completed: min($0.completed, $0.required), required: $0.required,
                received: $0.completed, requirementsSatisfied: $0.requirementsSatisfied)
        }
        if monitor.canRestoreHiddenReview(review), let token = try? RemoteDigest.token([account, card.id, card.title,
                                               review.url.absoluteString, review.hideID?.uuidString ?? ""]) {
            card.actions = [.init(id: RemoteAction.restoreHiddenReviewID, kind: .markDone, token: token)]
        }
        if includesCardActions {
            RemoteCardActionContext(hiddenReview: review, monitor: monitor)?.project(&card)
        }
        return card
    }

    static func hiddenAssignmentCardID(_ review: HiddenReview) -> String {
        "hidden-review:\(review.target.projectID):\(review.target.iid ?? 0)"
    }

    static func restoreHiddenReview(_ card: RemoteCard, action: RemoteAction, monitor: TodoMonitorService,
                                    account: String) -> RemoteCommandResult.Status {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername,
              account == "\(username)@\(host)",
              let review = monitor.hiddenReviewAssignments.first(where: { hiddenAssignmentCardID($0) == card.id })
        else { return .changed }
        let current = hiddenAssignmentCard(review, account: account, monitor: monitor)
        guard current.hasSameActionContext(as: card), current.actions.contains(action) else { return .changed }
        return monitor.restoreReviewedMergeRequests([review]) ? .completed : .failed
    }

    private static func reviewAssignmentAction(for row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService,
                                               account: String) -> RemoteAction? {
        guard monitor.isNewReviewAssignment(row),
              let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL),
              account == "\(target.username)@\(target.host)",
              let token = try? RemoteDigest.token([account, boardOrderCardID(target), row.displayURL.absoluteString,
                  row.displayTitle, row.displayRequest.flatMap(contextRevision) ?? "",
                  try RemoteDigest.token(row.newReviewAssignedAt), monitor.settings.newReviewGenerations[target]?.uuidString ?? ""])
        else { return nil }
        return .init(id: RemoteAction.reviewSeenID, kind: .markDone, token: token)
    }

    static func acknowledgeReviewAssignment(_ card: RemoteCard, action: RemoteAction, monitor: TodoMonitorService,
                                            account: String) -> RemoteCommandResult.Status {
        guard let row = monitor.boardSnapshot.reviewed.first(where: { "mr:\($0.id.projectID):\($0.id.iid)" == card.id }),
              card.url == row.displayURL, reviewAssignmentAction(for: row, monitor: monitor, account: account) == action
        else { return .changed }
        return monitor.markReviewAssignmentSeen(row.displayItem) ? .completed : .failed
    }

    private static func aiReplyDecisions(for draft: GitLabDraftNote, item: MergeRequestAttentionMonitor.Item,
                                         account: String) -> [RemoteAIReplyDecision]? {
        guard let draftID = draft.id, let offered = item.aiReplyDecisions[draftID], !offered.isEmpty,
              let request = item.mergeRequest, let fingerprint = item.observedDiscussionFingerprint,
              let draftToken = try? RemoteDigest.token(draft), let requestToken = try? RemoteDigest.token(request) else { return nil }
        let decisions: [RemoteAIReplyDecision] = offered.compactMap { source in
            let parts = [account, requestToken, fingerprint, draftToken, String(source.id),
                         String(source.authorID), source.bodyDigest, String(item.observationSession?.revision ?? 0)]
            guard let reply = try? RemoteDigest.token(parts + ["reply"]),
                  let human = try? RemoteDigest.token(parts + ["human"]) else { return nil }
            return .init(id: source.id, authorLabel: source.authorLabel, excerpt: source.excerpt,
                reply: .init(id: "confirmAIReply:\(draftID):\(source.id)", kind: .confirmAIReply, token: reply),
                human: .init(id: "markReplyHuman:\(draftID):\(source.id)", kind: .markReplyHuman, token: human))
        }
        return decisions.isEmpty ? nil : decisions
    }

    static func card(_ item: MergeRequestAttentionMonitor.Item, account: String,
                     extraActions: [RemoteActionKind] = [], context: [String] = [],
                     failedFollowUp: MRHumanAction.FailedFollowUp? = nil,
                     confirmations: MRCardPresentation.ConfirmationOffers? = nil) -> RemoteCard {
        let drafts = item.drafts.enumerated().map { index, draft in
            let context: String?
            if case let .line(location) = draft.kind { context = location }
            else { context = draft.discussionID }
            let recipients = draft.discussionID.flatMap { item.replyRecipients[$0] }?.map(\.remotePerson)
            return RemoteDraft(id: draft.id ?? (-1 - index), body: draft.note ?? "", context: context,
                publicationWarnings: DraftPublicationRisk(draft: draft)?.messages.map { String(localized: $0) },
                replyRecipients: recipients?.isEmpty == false ? recipients : nil,
                aiReplyDecisions: aiReplyDecisions(for: draft, item: item, account: account))
        }
        var card = RemoteCard(id: mergeRequestCardID(item.id), title: item.title,
            project: item.url.gitLabProjectPath, url: item.url,
            head: item.mergeRequest?.sha, detail: detail(item), drafts: drafts)
        card.contextRevision = item.mergeRequest.flatMap(contextRevision)
        card.dependencies = .init(summary: item.dependencies, projectID: item.id.projectID)
        let offers = confirmations ?? .init(evidence: item, offersPublishShortcut: true)
        var kinds = extraActions.filter { $0 != .verify }
        if item.mergeRequest?.sha != nil {
            if !offers.publishableDraftIDs.isEmpty { kinds.append(.publish) }
            if offers.approve { kinds.append(.approve) }
            if offers.confirmReReview { kinds.append(.reReview) }
            if offers.finishCommentReview { kinds.append(.finishCommentReview) }
        }
        let metadata = item.drafts.flatMap { draft -> [String] in
            [String(draft.authorID), draft.discussionID ?? "", String(describing: draft.resolveDiscussion),
             draft.position?.newPath ?? "", String(describing: draft.position?.newLine),
             draft.position?.oldPath ?? "", String(describing: draft.position?.oldLine)]
        }
        let actionToken = (try? RemoteDigest.token(card)).flatMap { content -> String? in
            var parts: [String] = [account, content, item.reReviewFingerprint ?? "",
                item.observedDiscussionFingerprint ?? "", item.mergeRequest?.semanticContextFingerprint ?? "",
                String(item.requiresCommentReview), item.commentReviewSnapshot?.discussionFingerprint ?? ""]
            parts.append(contentsOf: metadata)
            parts.append(contentsOf: context)
            return try? RemoteDigest.token(parts)
        }
        if let token = actionToken {
            card.actions = Array(Set(kinds.map(\.rawValue))).sorted().compactMap { raw in
                guard let kind = RemoteActionKind(rawValue: raw) else { return nil }
                if kind == .publish {
                    let draftIDs = offers.publishableDraftIDs.map(String.init)
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
            for retry in MRVerificationRetry.allCases where retry.isAvailable(for: item, failedFollowUp: failedFollowUp) {
                let recovery = retry == .authorFeedback ? failedFollowUp : nil
                var identity = [token, retry.rawValue]
                if let recovery {
                    guard let evidence = try? followUpEvidenceToken(recovery, item: item) else { continue }
                    identity.append(evidence)
                }
                guard let retryToken = try? RemoteDigest.token(identity) else { continue }
                let label: LocalizedStringResource = recovery == nil ? retry.label : .AuthorFeedback.authorFeedbackRecheck
                card.actions.append(.init(id: retry.rawValue, kind: .verify, token: retryToken,
                    confirmationText: retry.effect.help, label: String(localized: label)))
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
                    || item.mergeRequest.map { GitLabAccountIdentity.normalize($0.author.username) } == GitLabAccountIdentity.normalize(username))
            card.presentation = .init(repository: card.project.split(separator: "/").last.map(String.init) ?? card.project,
                approvalPeople: approvals.people, viewerApprovalID: approvals.viewerApprovalID,
                assignedReviewerCount: MergeRequestApprovalProgress.assignedReviewerCount(item.mergeRequest?.reviewers))
        }
        return card
    }

    static func boardOrderCardID(_ target: MRAutomationScope.Target) -> String {
        "mr:\(target.projectID):\(target.iid ?? 0)"
    }

    static func card(_ todo: Todo, account: String) -> RemoteCard {
        var card = RemoteCard(id: "todo:\(todo.id)", title: todo.displayTitle, project: todo.project.nameWithNamespace,
            url: todo.targetURL, detail: todo.body)
        if let token = try? RemoteDigest.token([account, try RemoteDigest.token(todo)]) {
            card.actions = [.init(id: "markDone", kind: .markDone, token: token)]
        }
        return card
    }

    static func board(monitor: TodoMonitorService, session: UUID, account: String,
                      includesBoardOrder: Bool = false, includesCardActions: Bool = false,
                      includesReviewBoard: Bool = false) -> RemoteBoard {
        let board = monitor.boardSnapshot
        let other = board.otherCards(jobs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost,
            username: monitor.glab.currentUsername, pinnedCards: monitor.settings.boardPins)
        var result = project(board: board, other: other, session: session, account: account,
            intents: monitor.settings.mrActionIntents, conflictReceipts: monitor.settings.conflictReceipts) { row, _ in
                .init(id: mergeRequestCardID(row.id), title: row.displayTitle,
                    project: row.displayURL.gitLabProjectPath, url: row.displayURL)
            }
        result.codingProvider = monitor.settings.automation.selectedAssistant?.rawValue
        if includesReviewBoard {
            result.hiddenReviews = monitor.hiddenReviewAssignments.filter { account == "\($0.target.username)@\($0.target.host)" }
                .map { hiddenAssignmentCard($0, account: account, monitor: monitor, includesCardActions: includesCardActions) }
        }
        var orderGroups: [String: RemoteBoardOrderGroup] = [:]
        if includesBoardOrder {
            for (group, entries) in Dictionary(grouping: board.manualOrderEntries, by: \.group) {
                let ids = entries.map { boardOrderCardID($0.target) }
                let orderGroup = RemoteBoardOrderGroup(lane: group.reviewing ? .reviewed : .own,
                    automationEnabled: group.automationEnabled, pinned: group.pinned, cardIDs: ids)
                for id in ids { orderGroups[id] = orderGroup }
            }
        }
        let rows = Dictionary((board.own + board.reviewed).map { (mergeRequestCardID($0.id), $0) },
            uniquingKeysWith: { first, _ in first })
        let proposals = Dictionary(board.proposals.map { (boardOrderCardID($0.target), $0.target) },
            uniquingKeysWith: { first, _ in first })
        for lane in result.lanes.indices {
            for index in result.lanes[lane].cards.indices {
                var card = result.lanes[lane].cards[index]
                var noticeTarget = proposals[card.id]
                if let row = rows[card.id] {
                    let item = row.item
                    if row.newReviewAssignedAt != nil {
                        noticeTarget = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL)
                    }
                    var extras: [RemoteActionKind] = []
                    let handoffs = monitor.pipelineHandoffs.filter { $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid }
                    if !handoffs.isEmpty { extras.append(.handoff) }
                    switch monitor.attentionFeedbackAction(for: item) {
                    case .ready, .failed: extras.append(.prepare)
                    default: break
                    }
                    let reviewing = result.lanes[lane].id == .reviewed
                    let presentation = MRCardPresentation(row: row, monitor: monitor, allowsRemoval: reviewing)
                    let humanAction = presentation.humanAction
                    let followUp = failedFollowUp(in: row, monitor: monitor, presentation: presentation)
                    let feedbackIDs = item.authorFeedbackStatus?.followUpNoteIDs.sorted().map(String.init) ?? []
                    if humanAction?.action == .handleFeedback, !feedbackIDs.isEmpty { extras.append(.prepare) }
                    let context = handoffs.map(\.id).sorted() + [(try? RemoteDigest.token(monitor.settings.automation)) ?? "",
                        item.authorFeedbackStatus?.fingerprint ?? ""] + feedbackIDs
                    card = self.card(item, account: account, extraActions: extras, context: context,
                        failedFollowUp: followUp, confirmations: presentation.confirmationOffers)
                    card = self.presentation(card, model: presentation)
                    projectActivity(&card, presentation: presentation, monitor: monitor)
                    if includesReviewBoard {
                        card.boardTraits = .init(needsAttention: row.needsAttention,
                            isNew: reviewing && monitor.isNewReviewAssignment(row),
                            isInactive: monitor.boardActivityGroup(for: row) == .inactive)
                        if let pin = BoardCardPin.mergeRequest(host: monitor.glab.resolvedHost, username: monitor.glab.currentUsername,
                            projectID: row.id.projectID, iid: row.id.iid) {
                            card.pinned = monitor.settings.boardPins.contains(pin)
                        }
                    }
                    let issues = monitor.issueTags(for: row.displayRequest)
                    if !issues.isEmpty { card.issues = issues }
                    if let head = card.head, let host = monitor.glab.resolvedHost,
                       let username = monitor.glab.currentUsername, account == "\(username)@\(host)" {
                        let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: item.id.projectID, iid: item.id.iid)
                        if monitor.settings.hasAutomaticApprovalWithOpenFindings(for: target, head: head) {
                            card.presentation?.approvedWithOpenFindings = true
                        }
                        if monitor.settings.independentApprovalPreferences[target] == .off {
                            card.presentation?.automaticApprovalOff = true
                        }
                    }
                    if row.displayRequest?.state == .merged || row.displayRequest?.state == .closed {
                        card.actions = []
                        if let action = finishedAcknowledgement(for: row, monitor: monitor, account: account) {
                            card.actions.append(action)
                            card.primaryCTA = .init(title: String(localized: .MRLifecycle.seen), destination: .actions, actionID: action.id)
                        }
                        if includesCardActions {
                            RemoteCardActionContext(card: card, board: board, monitor: monitor)?.project(&card)
                        }
                        result.lanes[lane].cards[index] = card
                        continue
                    }
                    card = mergePresentation(card, item: item, controls: presentation.mergeControls,
                        waitingStatus: presentation.cardWaitingRequirements)
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
                        card = mergeActions(card, item: item, controls: presentation.mergeControls, monitor: monitor, account: account)
                        let followUpInProgress = row.hasFollowUpInProgress
                        let workerRetryIntentID = followUp?.retriesWorker == true ? followUp?.intent.id : nil
                        let eligibleIntents = row.attentionIntents.filter { intent in
                            let canRetry = intent.state == .failed && !row.isReconciling(intent)
                            let canStart = intent.state == .pending && !intent.isDeferredReview
                            return (canRetry || canStart) && intent.id != workerRetryIntentID
                                && (intent.kind != .followUp || !followUpInProgress)
                        }
                        let pendingReview = presentation.reviewingContext.nextStep == .runReview
                            && humanAction == nil ? row.reviewIntentForManualStart : nil
                        let primaryIntent = pendingReview
                            ?? humanAction?.retryIntent.flatMap { selected in eligibleIntents.first { $0.id == selected.id } }
                            ?? eligibleIntents.first { $0.state == .failed }
                            ?? eligibleIntents.first
                        let visibleIntents = BoardMRIntentActions.visibleIntents(row.attentionIntents)
                        let intents = [primaryIntent].compactMap { $0 } + visibleIntents.filter { visible in
                            visible.kind != primaryIntent?.kind && eligibleIntents.contains { $0.id == visible.id }
                        }
                        if let configuration = try? RemoteDigest.token(monitor.settings.automation) {
                            card.actions += intents.compactMap {
                                intentAction($0, item: item, monitor: monitor, account: account,
                                    configuration: configuration, failedFollowUp: followUp)
                            }
                        }
                        if let job = humanAction?.retryJob ?? row.latestJob, row.stoppedJobNeedsAttention,
                           !followUpInProgress || job.selectedFollowUpNotes.isEmpty,
                           job.taskPrompt != nil, job.mergeRequestURL != nil,
                           let token = try? jobRetryToken(job, item: item, account: account,
                               configuration: monitor.settings.automation, publication: jobPublication.rawValue,
                               failedFollowUp: followUp) {
                            let label = String(localized: MRHumanAction.retryLabel(job))
                            let reviewMode = job.workflow == .review ? jobPublication.rawValue : nil
                            let confirmation = MRActionCTA.retryRun.help + (job.workflow == .review
                                ? "\n\n" + String(localized: jobPublication.reviewConfirmation) : "")
                            card.actions.append(.init(id: "job:\(job.id)", kind: .retryJob, token: token,
                                confirmationText: confirmation, label: label,
                                confirmationID: MRActionCTA.retryRun.confirmationID(variant:
                                    [job.retryConfirmationVariant, reviewMode].compactMap { $0 }.joined(separator: ".")),
                                codingProvider: job.key.assistant.rawValue))
                        }
                    }
                    card.actions += mrControls(item: item, row: row, monitor: monitor, account: account, busy: busy)
                    if let control = commentOriginControl(item: item, monitor: monitor, account: account) { card.actions.append(control) }
                    card = bindingPrimaryAction(card, humanAction: humanAction?.action,
                        actionID: humanAction?.executableActionID, nextStep: presentation.reviewingContext.nextStep,
                        pendingReviewID: row.reviewIntentForManualStart?.id)
                    if let claim = assignmentClaim(for: row, monitor: monitor, account: account) {
                        card.actions.append(claim)
                    }
                    projectBoardActions(&card, humanAction: humanAction?.action)
                    projectPolicyHolds(&card, row: row, monitor: monitor)
                    if card.boardTraits?.isNew == true, let action = reviewAssignmentAction(for: row, monitor: monitor, account: account) {
                        card.actions.append(action)
                    }
                } else if let todo = board.otherTodos.first(where: { "todo:\($0.id)" == card.id }),
                          monitor.isAssessingNotice(todo) {
                    card.needsAttention = false
                    card.actions = []
                    card.primaryCTA = nil
                    card.presentation = .init(repository: todo.project.pathWithNamespace.split(separator: "/").last.map(String.init) ?? "",
                        status: MRActivity.agentStatus(.AutomationProgress.progressNotice, assistant: monitor.settings.automation.assistant),
                        working: true, statusSymbol: MRActionEffect.aiCheck.symbol)
                }
                if let noticeTarget,
                   let notice = monitor.settings.reviewAssignments.incomingReviewFilter.notice(for: noticeTarget) {
                    card.detail = [card.detail, String(localized: notice.localizedMessage)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
                card.orderGroup = orderGroups[card.id]
                if includesCardActions {
                    RemoteCardActionContext(card: card, board: board, monitor: monitor)?.project(&card)
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
            for lane in result.lanes.indices {
                for card in result.lanes[lane].cards.indices { result.lanes[lane].cards[card].removeActions { _ in true } }
            }
            result.hiddenReviews = result.hiddenReviews?.map { card in
                var readOnly = card
                readOnly.actions = []
                return readOnly
            }
        } else {
            result.inboxReadAction = RemoteInboxReadSelection(other)?.action(hostSession: session, account: account)
        }
        return result
    }

    private static func projectActivity(_ card: inout RemoteCard, presentation: MRCardPresentation, monitor: TodoMonitorService) {
        guard let activity = presentation.activity else { return }
        var state = card.presentation?.statusContext ?? .init()
        let startedAt = monitor.activityStartedAt(for: presentation.row.item, activity: activity)
        if presentation.mergeActivity != nil, let stage = state.mergeStage {
            state.mergeStage = .init(kind: stage.kind, title: stage.title, startedAt: startedAt)
        } else {
            state.activityStartedAt = startedAt
            state.activityDetail = presentation.reviewLaunchReason(workflows: monitor.settings.workflowActivity,
                intents: monitor.settings.mrActionIntents)
        }
        card.presentation?.statusContext = state.isEmpty ? nil : state
    }

    private static func projectPolicyHolds(_ card: inout RemoteCard, row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService) {
        var state = card.presentation?.statusContext ?? .init()
        var notices = state.notices ?? []
        let policy = MREffectivePolicySummary.presentation(row: row, monitor: monitor).0.cardClauses
        let displayed = Set(notices.map(\.title) + (card.presentation?.requirements ?? [])
            + [card.detail, card.presentation?.status, card.presentation?.nextStep, state.mergeStage?.title].compactMap { $0 })
        for clause in policy {
            let title = String(localized: clause.message)
            if !displayed.contains(title) { notices.append(.init(title: title, symbol: clause.symbol)) }
        }
        if let job = row.latestJob, let notice = monitor.assistantJobActionNotices[job.id] {
            notices.append(.init(title: notice, symbol: "exclamationmark.triangle"))
        }
        state.notices = notices.isEmpty ? nil : notices
        card.presentation?.statusContext = state.isEmpty ? nil : state
    }

    static func assignmentClaim(for row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, account: String) -> RemoteAction? {
        guard row.waitsForAssignmentClaim, let request = row.displayRequest, request.isOpen,
              let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL),
              account == "\(target.username)@\(target.host)", let context = contextRevision(request),
              let token = try? RemoteDigest.token([account, context, RemoteActionKind.claimAssignment.rawValue]) else { return nil }
        return .init(id: RemoteActionKind.claimAssignment.rawValue, kind: .claimAssignment, token: token,
            confirmationText: String(localized: .Remote.remoteClaimAssignmentHelp),
            label: String(localized: .Board.boardAssignmentClaim))
    }

    static func finishedAcknowledgement(for row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService,
                                        account: String) -> RemoteAction? {
        let item = row.displayItem
        guard monitor.canAcknowledgeFinishedMergeRequest(item), let id = item.lifecycleCompletionID,
              let token = try? RemoteDigest.token([account, item.url.absoluteString, id.uuidString]) else { return nil }
        return .init(id: RemoteAction.finishedSeenID, kind: .markDone,
            token: token, label: String(localized: .MRLifecycle.seen))
    }

    static func failedFollowUp(in row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService,
                               presentation: MRCardPresentation) -> MRHumanAction.FailedFollowUp? {
        guard !presentation.actionsBlocked,
              let recovery = presentation.humanAction?.failedFollowUp(in: row, jobs: monitor.assistantHandoffs),
              recovery.intent.target.host == monitor.glab.resolvedHost,
              recovery.intent.target.username == monitor.glab.currentUsername else { return nil }
        return recovery
    }

    static func intentActionToken(_ intent: MRTodoIntent, item: MergeRequestAttentionMonitor.Item,
                                  account: String, configuration: String, publication: String,
                                  failedFollowUp: MRHumanAction.FailedFollowUp?) -> String? {
        let identity = if let recovery = failedFollowUp, recovery.intent.id == intent.id {
            try? followUpEvidenceToken(recovery, item: item)
        } else {
            try? RemoteDigest.token(intent)
        }
        guard let identity else { return nil }
        return try? RemoteDigest.token([account, identity, configuration, publication])
    }

    private static func intentAction(_ intent: MRTodoIntent, item: MergeRequestAttentionMonitor.Item,
                                     monitor: TodoMonitorService, account: String, configuration: String,
                                     failedFollowUp: MRHumanAction.FailedFollowUp?) -> RemoteAction? {
        guard intent.kind == .refresh || monitor.selectedAssistantReady else { return nil }
        let publication = monitor.manualReviewConsent(for: monitor.reviewRequest(for: intent)).publicationMode
        guard let token = intentActionToken(intent, item: item, account: account, configuration: configuration,
            publication: publication.rawValue, failedFollowUp: failedFollowUp) else { return nil }
        let effect = MRActionCTA(intent: intent.kind) ?? .refreshFromGitLab
        let variant = intent.state == .failed ? "retry" : "start"
        let reviewMode = intent.kind == .review ? publication.rawValue : nil
        let confirmation = effect.help + (intent.kind == .review ? "\n\n" + String(localized: publication.reviewConfirmation) : "")
        return .init(id: "intent:\(intent.id)", kind: .prepare, token: token,
            confirmationText: confirmation, label: String(localized: MRHumanAction.intentLabel(intent)),
            confirmationID: effect.confirmationID(variant: [variant, reviewMode].compactMap { $0 }.joined(separator: ".")),
            codingProvider: effect.requiresCodingAssistant ? monitor.settings.automation.selectedAssistant?.rawValue : nil)
    }

    private static func jobRetryToken(_ job: AssistantAutomationRunner.Handoff, item: MergeRequestAttentionMonitor.Item,
                                      account: String, configuration: AutomationSettings, publication: String,
                                      failedFollowUp: MRHumanAction.FailedFollowUp?) throws -> String {
        var parts = [account, try RemoteDigest.token(job), try RemoteDigest.token(configuration), publication]
        if let recovery = failedFollowUp, recovery.retriesWorker, recovery.job?.id == job.id {
            parts.append(try followUpEvidenceToken(recovery, item: item))
        }
        return try RemoteDigest.token(parts)
    }

    private static func followUpEvidenceToken(_ recovery: MRHumanAction.FailedFollowUp,
                                              item: MergeRequestAttentionMonitor.Item) throws -> String {
        let intent = recovery.intent
        let job = recovery.job
        let feedback = recovery.feedback
        // Reconciliation refreshes the intent timestamp even when a stopped attempt's evidence is unchanged.
        let intentEvidence = [intent.id.uuidString, try RemoteDigest.token(intent.target), intent.headSHA,
            intent.request.semanticContextFingerprint, try RemoteDigest.token(intent.noteIDs.sorted()),
            try RemoteDigest.token(intent.todoIDs.sorted()), try RemoteDigest.token(intent.sourceEvents),
            intent.jobID?.uuidString ?? "", intent.state.rawValue, intent.error ?? ""]
        let jobEvidence = [job?.operationalExecution?.state.rawValue ?? "", job?.expectedHeadSHA ?? "",
            recovery.retryActionID, recovery.diagnostics ?? "", try RemoteDigest.token(job?.operationalExecution?.finishedAt),
            try RemoteDigest.token((job?.verifiedFeedbackNotes ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" })]
        let currentContext = item.mergeRequest.flatMap(contextRevision)
        let reviewEvidence: [String?] = [currentContext, recovery.discussionFingerprint,
            feedback?.head, feedback?.semanticContextFingerprint, feedback?.fingerprint,
            feedback?.phase.rawValue, feedback?.completedFollowUpJobID?.uuidString,
            feedback?.feedbackDecisionRevision, feedback?.reviewParticipationRevision]
        return try RemoteDigest.token(intentEvidence + jobEvidence + reviewEvidence.map { $0 ?? "" })
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
        let controls = MRManualMergePresentation(item: item, candidate: status,
            evidenceMatchesCatalogContext: evidenceMatchesCatalogContext, hasCurrentCatalog: hasCurrentCatalog)
        return mergePresentation(original, item: item, controls: controls, waitingStatus: waitingStatus)
    }

    private static func mergePresentation(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                                          controls: MRManualMergePresentation, waitingStatus: MRWaitingStatus?) -> RemoteCard {
        guard item.isAuthored, let request = item.mergeRequest, request.isOpen else { return original }
        let checked = controls.status
        var state = original.presentation?.statusContext ?? .init()
        state.checkGitLab = checked.map {
            let submission = $0.displayedSubmissionState
            return submission == .uncertain || submission == .changed || $0.action == nil
        } == true ? true : nil
        var card = original
        if card.presentation == nil {
            card.presentation = .init(repository: String(request.webURL.gitLabProjectPath.split(separator: "/").last ?? ""))
        }
        card.presentation?.statusContext = state.isEmpty ? nil : state
        let title: LocalizedStringResource
        let detail: String?
        let blocker: ManualMergeBlocker
        if let conflict = checked?.request.mergeTrainConflict, conflict.matches(request) {
            title = .MergeActions.mergeActionsTrainRebaseConflict
            detail = conflict.noteURL.absoluteString
            state.trainConflictNoteURL = conflict.noteURL
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
            guard let currentBlocker = controls.blocker else { return card }
            title = currentBlocker.title
            detail = nil
            blocker = currentBlocker
        }
        card.presentation?.statusContext = state.isEmpty ? nil : state
        card.removeActions { [.merge, .enqueueMerge].contains($0.kind) }
        if card.presentation?.working == true || state.refreshFailureHelp != nil {
            return card
        }
        let dependencyHold = waitingStatus?.hasCurrentDependencyHold == true
            && checked?.request.detailedMergeStatus == .mergeRequestBlocked
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
        let showsWaiting = ordinaryWait && !knownMergeFailure && controls.hasCurrentCatalog && controls.evidenceMatchesCatalogContext
        let status = String(localized: showsWaiting ? waitingStatus?.title ?? title : title)
        card.presentation?.status = status
        card.presentation?.statusPeopleMessage = nil
        if let waitingStatus, !waitingStatus.requirements.isEmpty {
            // Like the Mac card: one requirement per line, with an uncovered blocker joining the list.
            var lines = waitingStatus.requirements.map { String(localized: $0) }
            let covered: Bool = if case .prerequisite(let reason) = blocker { waitingStatus.coveredBlockers.contains(reason) } else { false }
            if !covered, !lines.contains(String(localized: title)) { lines.append(String(localized: title)) }
            card.presentation?.requirements = lines
            card.presentation?.requirementPeopleMessage = waitingStatus.reviewerPeopleMessage
            let people = waitingStatus.threadResolutionPeople
            card.presentation?.threadResolutionPeople = people.isEmpty ? nil : people.map(\.remotePerson)
        }
        if let detail, card.detail.isEmpty { card.detail = detail }
        // The status line or requirement list already carries the blocker; the phone must not print it twice.
        else if card.presentation?.requirements == nil, card.detail.isEmpty, String(localized: title) != status {
            card.detail = String(localized: title)
        }
        if card.primaryCTA == nil {
            if case .feedback = blocker {
                card.primaryCTA = .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewFeedback), destination: .feedback)
            } else {
                card.primaryCTA = .init(title: String(localized: .Board.boardDetails), destination: .overview)
            }
        }
        if let recovery = controls.feedbackRecovery, recovery.recoveryAction != nil,
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
        let controls = MRManualMergePresentation(item: item, candidate: status,
            evidenceMatchesCatalogContext: evidenceMatchesCatalogContext, hasCurrentCatalog: true)
        return mergeActions(original, item: item, controls: controls, monitor: monitor, account: account)
    }

    private static func mergeActions(_ original: RemoteCard, item: MergeRequestAttentionMonitor.Item,
                                     controls: MRManualMergePresentation, monitor: TodoMonitorService, account: String) -> RemoteCard {
        var card = original
        guard item.isAuthored, let request = item.mergeRequest, let username = monitor.glab.currentUsername,
              monitor.settings.owns(request, username: username),
              request.isOpen,
              let token = try? RemoteDigest.token([account, try RemoteDigest.token(request),
                  item.observedDiscussionFingerprint ?? "", try MergeSubmissionFingerprint.configuration(monitor.settings)]) else { return card }
        if let action = controls.action {
            let kind: RemoteActionKind = action == .mergeNow ? .merge : .enqueueMerge
            card.actions.append(.init(id: kind.rawValue, kind: kind, token: token,
                confirmationText: String(localized: .MergeActions.mergeActionsConfirmHelp) + "\n\n"
                    + String(localized: monitor.settings.automation.assistant.manualMergeVerificationDisclosure),
                label: String(localized: action.title)))
        }
        if controls.hasDiscussionBlock {
            card.actions.append(.init(id: "checkThreads", kind: .checkThreads, token: token,
                confirmationText: String(localized: .MergeActions.mergeActionsResolveHelp),
                label: String(localized: .MergeActions.mergeActionsResolveAll)))
        }
        return card
    }

    /// One entry point for correcting comment origins. It writes only local evidence and stays available
    /// while the card is busy; the command names its comments and the host re-reads GitLab to match them.
    static func commentOriginControl(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService,
                                     account: String) -> RemoteAction? {
        guard let request = item.mergeRequest, request.isOpen,
              monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) != nil,
              let token = try? RemoteDigest.token([account, "commentOrigin", String(request.projectID), String(request.iid)])
        else { return nil }
        return .init(id: "commentOrigin", kind: .setCommentOrigin, token: token)
    }

    /// Mac-detail controls offered to the phone. Each token binds the MR, its conversation and the
    /// automation settings, so any change since the phone's snapshot rejects the command as changed.
    static func mrControls(item: MergeRequestAttentionMonitor.Item, row: MergeRequestBoardSnapshot.Row,
                           monitor: TodoMonitorService, account: String, busy: Bool) -> [RemoteAction] {
        guard let request = item.mergeRequest, request.isOpen, row.evidenceMatchesCatalogContext,
              let base = try? RemoteDigest.token([account, try RemoteDigest.token(request),
                  item.observedDiscussionFingerprint ?? "", try RemoteDigest.token(monitor.settings.automation)]) else { return [] }
        func token(_ parts: [String]) -> String? { try? RemoteDigest.token([base] + parts) }
        var actions: [RemoteAction] = []
        // Stopping stays available while the run makes the card busy; it never writes to GitLab.
        if let job = row.latestJob, job.execution?.state.isActive == true, let token = token(["stop", job.id.uuidString]) {
            actions.append(.init(id: "stopJob:\(job.id)", kind: .stopJob, token: token,
                confirmationText: String(localized: .Remote.remoteStopJobHelp),
                label: String(localized: .AssistantJobs.assistantJobsStop)))
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

    private static func mergeRequestCardID(_ id: GitLabMergeRequestID) -> String { "mr:\(id.projectID):\(id.iid)" }

    static func project(board: MergeRequestBoardSnapshot, other: [MergeRequestBoardSnapshot.OtherCard], session: UUID, account: String,
                        intents: [MRTodoIntent] = [], conflictReceipts: Set<MergeConflictReceipt> = [],
                        rowCard: ((MergeRequestBoardSnapshot.Row, Bool) -> RemoteCard)? = nil) -> RemoteBoard {
        let viewerUsername = String(account.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        func projectedRow(_ row: MergeRequestBoardSnapshot.Row, allowsRemoval: Bool) -> RemoteCard {
            rowCard?(row, allowsRemoval) ?? presentation(card(row.item, account: account), row: row,
                allowsRemoval: allowsRemoval, viewerUsername: viewerUsername)
        }
        let others = other.compactMap { entry -> RemoteCard? in
            switch entry.content {
            case .completion(let completion): return card(completion, account: account)
            case .hiddenReview(let review, let notice): return card(review, notice: notice, account: account)
            case .proposal(let proposal):
                var card = proposal.item.map { self.card($0, account: account) }
                    ?? RemoteCard(id: "mr:\(proposal.target.projectID):\(proposal.target.iid ?? 0)", title: proposal.title,
                        project: proposal.url.gitLabProjectPath, url: proposal.url)
                card.actions = []
                card.detail = String(localized: .Remote.remoteProposal)
                return jobProgress(card, job: proposal.latestJob, intents: proposal.intents + intents, conflictReceipts: conflictReceipts)
            case .todo(let todo): return card(todo, account: account)
            case .job(let job):
                let url = job.mergeRequestURL
                var card = RemoteCard(id: "job:\(job.id)", title: job.title, project: url?.gitLabProjectPath ?? "", url: url,
                    detail: String(localized: .Remote.remoteAssistantPending))
                if MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state), job.taskPrompt != nil,
                   let token = try? RemoteDigest.token([account, try RemoteDigest.token(job)]) {
                    card.actions = [.init(id: "job:\(job.id)", kind: .retryJob, token: token,
                        codingProvider: job.key.assistant.rawValue)]
                }
                return jobProgress(card, job: job, intents: intents, conflictReceipts: conflictReceipts)
            }
        }
        return .init(hostSession: session, account: account, lanes: [
            .init(id: .own, cards: board.own.map { projectedRow($0, allowsRemoval: false) }),
            .init(id: .reviewed, cards: board.reviewed.map { projectedRow($0, allowsRemoval: true) }),
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
                             viewerUsername: String? = nil,
                             confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
                             automaticallyPublishedDraftIDs: Set<Int> = [],
                             reviewing: ReviewingContext? = nil, busy: Bool = false) -> RemoteCard {
        let model = MRCardPresentation(row: row,
            reviewingContext: reviewing ?? ReviewingContext(row: row, assistantReady: assistantReady, viewerUsername: viewerUsername),
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
        if model.confirmationOffers.publishableDraftIDs.isEmpty {
            card.actions.removeAll { $0.kind == .publish }
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
            return .init(title: String(localized: destination == .setup ? .Remote.remoteSetupActionOnMac : label),
                destination: destination, showsOnCard: human?.action == .reviewIssue ? true : nil)
        }
        if model.actionLabel != nil, human?.action == .reviewDrafts {
            if human?.kind == .commentReview,
               let finish = card.actions.first(where: { $0.kind == .finishCommentReview }) {
                card.primaryCTA = .init(title: String(localized: .CommentReview.commentReviewFinish),
                    destination: .actions, actionID: finish.id)
            } else if model.draftPublicationShortcut == .review {
                card.primaryCTA = .init(title: String(localized: .CommentReview.commentReviewReviewBeforePublishing), destination: .drafts)
            } else if let publish = card.actions.first(where: { $0.kind == .publish }) {
                card.primaryCTA = .init(title: String(localized: .CommentReview.commentReviewPublishAll),
                    destination: .actions, actionID: publish.id)
            }
        }
        let author: Todo.Author? = ReviewingContext(row: model.row).author
        let authorName: String? = author?.person.displayName
        let authorUsername: String? = author?.username
        let authorAvatarURL: URL? = author?.avatarURL
        let finished = MergeRequestFinishedState(model.row.displayRequest)
        let draftBadge = finished.map { String(localized: $0.badge) }
            ?? (model.row.isDraft ? String(localized: .Menu.menuMrDraftBadge) : nil)
        let chips: [RemoteCardChip] = model.chips.map { .init(title: String(localized: $0.title), symbol: $0.symbol) }
        let steps = model.stepChain.map { $0.steps.map { String(localized: $0) } }
        let pendingDrafts = finished != nil || model.working ? nil : MRPendingDraftsSummary(item: model.row.item)
        let repository = card.project.split(separator: "/").last ?? Substring(card.project)
        let retryCTA: RemoteCardCTA? = human?.action == .retryRun
            ? .init(title: String(localized: .MRHumanAction.mrHumanActionActionReviewRun), destination: .assistantRuns) : nil
        let refreshFailed = finished == nil && !model.working && model.refreshFailed
        let status = refreshFailed
            ? model.refreshFailureLabel ?? String(localized: .AutomationProgress.progressRefreshFailed) : model.status
        let waiting = model.cardWaitingRequirements
        card.presentation = .init(author: authorName,
            repository: String(repository),
            draftBadge: draftBadge, isDraft: finished == nil && model.row.isDraft,
            status: status, nextStep: model.nextStep, working: model.working,
            chips: chips,
            secondaryCTA: retryCTA,
            authorUsername: authorUsername, authorAvatarURL: authorAvatarURL,
            requirements: waiting?.requirements.map { String(localized: $0) },
            steps: steps, currentStep: model.stepChain?.current,
            pendingDrafts: pendingDrafts.map { String(localized: $0.message) },
            statusSymbol: refreshFailed ? "arrow.clockwise" : model.activityEffect?.symbol,
            approvalPeople: model.row.evidenceMatchesCatalogContext ? original.presentation?.approvalPeople : nil,
            viewerApprovalID: model.row.evidenceMatchesCatalogContext ? original.presentation?.viewerApprovalID : nil,
            assignedReviewerCount: MergeRequestApprovalProgress.assignedReviewerCount(model.row.displayRequest?.reviewers))
        card.presentation?.statusPeopleMessage = model.statusPeopleMessage
        card.presentation?.reviewCompletionInDetailsOnly = model.reviewCompletionInDetailsOnly ? true : nil
        card.presentation?.pendingDraftsPeopleMessage = pendingDrafts?.peopleMessage
        card.presentation?.requirementPeopleMessage = waiting?.reviewerPeopleMessage
        var state = RemoteCardStatusContext()
        state.finished = finished.flatMap { .init(rawValue: $0.rawValue) }
        if let stage = model.mergeStage {
            let kind: RemoteCardStatusContext.MergeStage.Kind = switch stage {
            case .merging: .merging
            case .queued: .queued
            case .inTrain: .inTrain
            }
            state.mergeStage = .init(kind: kind, title: String(localized: stage.title))
        }
        state.refreshFailureHelp = refreshFailed ? model.refreshFailureHelp : nil
        if finished == nil {
            var notices: [RemoteCardChip] = []
            if model.row.waitsForAssignmentClaim {
                notices.append(.init(title: String(localized: .Board.boardAssignmentAwaitingClaim),
                    symbol: "person.crop.circle.badge.exclamationmark"))
            }
            if let confirmation = model.confirmationState, confirmation == .failed || confirmation == .changed {
                notices.append(.init(title: String(localized: confirmation == .failed ? .Menu.menuConfirmFailed : .Menu.menuConfirmChanged),
                    symbol: "exclamationmark.triangle"))
            }
            state.notices = notices.isEmpty ? nil : notices
        }
        card.presentation?.statusContext = state.isEmpty ? nil : state
        if model.actionsBlocked { card.removeActions { _ in true } }
        return card
    }

    static func bindingPrimaryAction(_ original: RemoteCard, humanAction: MRHumanAction.Action?,
                                     actionID: String? = nil, nextStep: ReviewingContext.NextStep,
                                     pendingReviewID: UUID? = nil) -> RemoteCard {
        var card = bindingExecutableAction(original, humanAction: humanAction, actionID: actionID,
            nextStep: nextStep, pendingReviewID: pendingReviewID)
        if let ready = card.actions.first(where: { $0.kind == .markReady }) {
            let cta = RemoteCardCTA(title: String(localized: .Remote.remoteMarkReady), destination: .actions, actionID: ready.id)
            if card.primaryCTA == nil || card.primaryCTA?.duplicatesCardTap == true { card.primaryCTA = cta }
            else { addBoardCTA(cta, to: &card) }
        }
        return card
    }

    private static func bindingExecutableAction(_ original: RemoteCard, humanAction: MRHumanAction.Action?,
                                                actionID: String?, nextStep: ReviewingContext.NextStep,
                                                pendingReviewID: UUID?) -> RemoteCard {
        guard let cta = original.primaryCTA, cta.destination != .setup else { return original }
        let kind: RemoteActionKind
        switch humanAction {
        case .retryRun: kind = .retryJob
        case .verifyFeedback, .retryDraftVerification, .retryReReview: kind = .verify
        case .handleFeedback, .retryIntent: kind = .prepare
        case nil where nextStep == .runReview: kind = pendingReviewID == nil ? .runReview : .prepare
        default: return original
        }
        var card = original
        let expectedID = actionID ?? (humanAction == nil && nextStep == .runReview
            ? pendingReviewID.map { "intent:\($0)" } ?? "runReview" : nil)
        let matches = card.actions.filter { $0.kind == kind && $0.id == expectedID }
        card.primaryCTA?.destination = .actions
        if matches.count == 1 {
            card.primaryCTA?.actionID = matches[0].id
        } else {
            card.primaryCTA?.title = String(localized: .Remote.remoteActionOnMac)
        }
        return card
    }

    static func projectBoardActions(_ card: inout RemoteCard, humanAction: MRHumanAction.Action?) {
        if let action = card.actions.first(where: { $0.kind == .claimAssignment })
            ?? card.actions.first(where: { $0.kind == .stopJob }), let title = action.label {
            card.primaryCTA = .init(title: title, destination: .actions, actionID: action.id)
        }
        for action in card.actions {
            guard let title = action.label else { continue }
            let cta = RemoteCardCTA(title: title, destination: .actions, actionID: action.id)
            switch action.kind {
            case .merge, .enqueueMerge:
                let replacesMergeReview = card.primaryCTA?.actionID == nil
                    && (humanAction == .reviewMerge || humanAction == .reviewDecision)
                if card.primaryCTA == nil || card.primaryCTA?.duplicatesCardTap == true || replacesMergeReview {
                    card.primaryCTA = cta
                } else { addBoardCTA(cta, to: &card) }
            case .checkThreads:
                addBoardCTA(cta, to: &card)
            default: break
            }
        }
    }

    private static func addBoardCTA(_ cta: RemoteCardCTA, to card: inout RemoteCard) {
        var presentation = card.presentation ?? .init(repository: card.project)
        if presentation.secondaryCTA == nil {
            presentation.secondaryCTA = cta
        } else {
            presentation.additionalCTAs = (presentation.additionalCTAs ?? []) + [cta]
        }
        card.presentation = presentation
    }

    static func contextRevision(_ request: GitLabMergeRequest) -> String? {
        guard let identity = try? RemoteDigest.token(MergeRequestDependencySummary.Context(request)) else { return nil }
        return try? RemoteDigest.token([identity, request.semanticContextFingerprint, String(describing: request.draft),
            String(request.author.id), request.author.username])
    }

    static func detail(_ item: MergeRequestAttentionMonitor.Item) -> String {
        detail(item.presentingVerifiedAuthorFeedback())
    }

    static func detail(_ item: MergeRequestAttentionMonitor.ItemPresentation) -> String {
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
