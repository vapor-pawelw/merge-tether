import Foundation

/// Stateless display decisions over account-bound values. No settings, monitor, I/O or execution ownership.
@MainActor
struct MRBoardProjector {
    typealias Item = MergeRequestAttentionMonitor.Item
    struct Account: Equatable {
        let host: String
        let username: String
        let revision: UInt64
        var presentationKey: String { "\(host)/\(username)/\(revision)" }
    }
    struct RequestFacts {
        /// Includes the mutable fields consumed by CI/conflict/policy readers; envelope compatibility is weaker.
        private struct Binding: Equatable {
            struct Pipeline: Equatable {
                let id: Int?
                let projectID: Int?
                let status: String
                let sha: String?
                let ref: String?
                init(_ value: GitLabMergeRequest.Pipeline) {
                    id = value.id; projectID = value.projectID; status = value.status; sha = value.sha; ref = value.ref
                }
            }
            let context: MergeRequestDependencySummary.Context
            let semanticContext: String
            let authorID: Int
            let authorUsername: String
            let draft: Bool?
            let pipeline: Pipeline?
            let hasConflicts: Bool?
            let detailedMergeStatus: String?
            let blockingDiscussionsResolved: Bool?
            let mergeWhenPipelineSucceeds: Bool?
            let canMerge: Bool?
            let labels: [String]
            init(_ request: GitLabMergeRequest) {
                context = .init(request); semanticContext = request.semanticContextFingerprint
                authorID = request.author.id; authorUsername = request.author.username; draft = request.draft
                pipeline = request.headPipeline.map(Pipeline.init)
                hasConflicts = request.hasConflicts; detailedMergeStatus = request.detailedMergeStatus
                blockingDiscussionsResolved = request.blockingDiscussionsResolved
                mergeWhenPipelineSucceeds = request.mergeWhenPipelineSucceeds; canMerge = request.canMerge
                labels = request.labels
            }
        }
        let request: GitLabMergeRequest
        var mergeAutomatic = false
        var conflictFailed = false
        var conflictProcessing = false
        var pipelineProcessing = false
        var workflowReadFailed = false
        var aiOriginReadFailed = false
        func matches(_ request: GitLabMergeRequest) -> Bool { Binding(self.request) == Binding(request) }
    }
    struct Input {
        let account: Account
        var attention: MergeRequestAttentionMonitor.PresentationSnapshot?
        var authored: [AuthoredMergeRequestStatus] = []
        var retainedRequests: [GitLabMergeRequest] = []
        var completionIDs: [Item.ID: UUID] = [:]
        var ownCatalogIsAuthoritative = false
        var trackedReviewedTargets: Set<MRAutomationScope.Target> = []
        var remainingFeedbackIDs: [Item.ID: Set<Int>] = [:]
        var feedbackLaunchFailures: [MRFeedbackLaunchCoordinator.Failure] = []
        var feedbackDecisionRevisions: [Item.ID: String] = [:]
        var requestFacts: [RequestFacts] = []
        var workflowEntries: [MergeWorkflowActivityEntry] = []
        var pipelineHandoffs: [MergeWorkflowActivityEntry] = []
        var handoffs: [AssistantAutomationRunner.Handoff] = []
        var confirmationStates: [Item.ID: MergeRequestAttentionMonitor.ConfirmationState] = [:]
        var automation = AutomationSettings()
        var assistantReady = false
        var reviewAssistantReady = false
        var assistantChecking = false
        var publicationAutomaticTargets: Set<MRAutomationScope.Target> = []
        var ignoredTargets: Set<MRAutomationScope.Target> = []
        var hiddenTargets: Set<MRAutomationScope.Target> = []
        var mrCatalogReadFailed = false
        var catalogReadFailed = false
        var catalogLoading = false
        var inboxLoading = false
        var assessingMentionNoteIDs: Set<Int> = []
        var todos: [Todo] = []
        var intents: [MRTodoIntent] = []
        var routedTodoIDs: Set<Int> = []
        var pipelineEvidence: [GitLabMergeRequest] = []
        var pipelineEvidenceCheckedAt: Date?
        var displayRequests: [GitLabMergeRequest] = []
        var pins: Set<BoardCardPin> = []
        var grouping: MRBoardGrouping = .withoutAutomation
        var draftsLast = true
        var completions: [MergeRequestLifecycleLedger.CompletionReceipt] = []
    }
    let input: Input
    private var preparing: Bool { input.assistantReady || input.assistantChecking }
    private var attentionSnapshot: MergeRequestAttentionMonitor.PresentationSnapshot? {
        guard let snapshot = input.attention, snapshot.host == input.account.host,
              snapshot.username == input.account.username, snapshot.revision == input.account.revision else { return nil }
        return snapshot
    }
    private func scopeTarget(projectID: Int, iid: Int, url: URL) -> MRAutomationScope.Target? {
        guard projectID > 0, iid > 0, url.isGitLabMergeRequest(host: input.account.host, iid: iid) else { return nil }
        return .init(host: input.account.host, username: input.account.username, projectID: projectID, iid: iid)
    }
    private func facts(for request: GitLabMergeRequest?) -> RequestFacts? {
        guard let request else { return nil }
        return input.requestFacts.first { $0.matches(request) }
    }
    var catalogItems: [Item] {
        var rows = Dictionary((attentionSnapshot?.catalog ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for request in input.retainedRequests {
            let id = Item.ID(projectID: request.projectID, iid: request.iid)
            guard let target = scopeTarget(projectID: id.projectID, iid: id.iid, url: request.webURL) else { continue }
            if !MRAttentionRecord.sameContext(rows[id]?.mergeRequest, request) {
                rows[id] = .init(id: id, title: request.title, url: request.webURL,
                    mergeRequest: request, isAuthored: request.author.username == input.account.username)
            }
            rows[id]?.lifecycleCompletionID = input.completionIDs[id]
            if input.hiddenTargets.contains(target) { rows[id] = nil }
        }
        return rows.values.filter { item in
            scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
                .map { !input.hiddenTargets.contains($0) } == true
        }
    }
    var browser: MergeRequestBrowserSnapshot {
        .init(openItems: catalogItems, authored: input.authored, host: input.account.host, username: input.account.username,
            scope: input.automation.scope, ownCatalogIsAuthoritative: input.ownCatalogIsAuthoritative, draftsLast: input.draftsLast)
    }
    var ownItems: [Item] { browser.own }
    var reviewedItems: [Item] {
        browser.reviewed.filter { item in
            scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url).map {
                !input.ignoredTargets.contains($0) && input.trackedReviewedTargets.contains($0)
            } == true
        }
    }

    var attentionItems: [MergeRequestAttentionMonitor.Item] {
        var items = (attentionSnapshot?.attention ?? []).compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard !item.feedback.isEmpty else { return item }
            let remaining = input.remainingFeedbackIDs[item.id] ?? Set(item.feedback.compactMap(\.id))
            var item = item
            item.feedback.removeAll { $0.id.map { !remaining.contains($0) } ?? false }
            if item.feedback.isEmpty { item.needsDiscussion = item.hasOtherUnresolvedDiscussions }
            return item.needsAttention ? item : nil
        }
        let handoffs = input.pipelineHandoffs
        for handoff in handoffs {
            let mr = handoff.event.mergeRequest
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: mr.projectID, iid: mr.iid)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].needsPipelineHandoff = true
                if items[index].mergeRequest == nil { items[index].mergeRequest = mr }
            } else {
                items.append(.init(id: id, title: mr.title, url: mr.webURL, needsPipelineHandoff: true, mergeRequest: mr))
            }
        }
        if !input.mrCatalogReadFailed {
            let host = input.account.host, username = input.account.username
            for status in input.authored where status.mayMergeManually {
                let request = status.request
                guard request.author.username == username,
                      request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                      let current = catalogItems.first(where: {
                          $0.id.projectID == request.projectID && $0.id.iid == request.iid
                      }), current.mergeRequest?.author.username == username, current.canOfferManualMerge(using: status)
                else { continue }
                let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
                guard (items.first(where: { $0.id == id })?.draftCount ?? 0) == 0 else { continue }
                let automatic = preparing && status.mayAutoMerge && facts(for: request)?.mergeAutomatic == true
                    && !AssistantJobExecution.hasUnfinishedWork(in: input.handoffs,
                        for: .init(host: host, projectID: id.projectID, iid: id.iid), username: username,
                        currentRequest: request, feedbackStatus: current.authorFeedbackStatus,
                        discussionFingerprint: current.observedDiscussionFingerprint)
                guard !automatic else { continue }
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].needsMerge = true }
                else { items.append(.init(id: id, title: request.title, url: request.webURL, needsMerge: true, mergeRequest: request, isAuthored: true)) }
            }
        }
        let visible = items.compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return item }
            let currentEvents = input.workflowEntries.filter {
                $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                    && $0.event.mergeRequest.sha == item.mergeRequest?.sha
            }
            var failures = Set(MergeWorkflowTrigger.allCases.filter { trigger in
                guard let entry = currentEvents.first(where: { $0.event.kind == trigger }) else { return false }
                return entry.state == .failed && !entry.isReadOnlyFailure
            })
            if input.feedbackLaunchFailures.contains(where: { $0.matches(item, host: input.account.host,
                username: input.account.username, revision: input.account.revision, configuration: input.automation,
                decisionRevision: input.feedbackDecisionRevisions[item.id]) }) {
                failures.insert(.newDiscussion)
            }
            let conflictFailed = facts(for: item.mergeRequest)?.conflictFailed == true
            let pipelineState = currentEvents.first { $0.event.kind == .pipelineFailure
                && $0.event.pipelineID == item.mergeRequest?.headPipeline?.id }?.state
            let pipelineOwned = pipelineState.map { [.queued, .running, .waitingForAssistant, .completed, .alreadyRegistered].contains($0) } ?? false
            let feedbackState = currentEvents.first { $0.event.kind == .newDiscussion }?.state
            let feedbackOwned = feedbackState.map { [.queued, .running, .waitingForAssistant, .completed].contains($0) } ?? false
            let visible = item.requiringUserAttention(automation: input.automation, target: target,
                                                     failedTriggers: failures, conflictTaskFailed: conflictFailed,
                                                     pipelineOwnedAutomatically: pipelineOwned, feedbackOwnedAutomatically: feedbackOwned)
            return visible.needsAttention ? visible : nil
        }
        return MergeRequestAttentionMonitor.Item.ordered(visible)
    }

    func attentionIntentIsAutomatic(_ intent: MRTodoIntent, ready: Bool) -> Bool {
        let configuration = input.automation
        guard configuration.packageDecision != .disabled, configuration.scope.resolve(intent.target).active,
              !input.ignoredTargets.contains(intent.target), intent.request.state == "opened",
              intent.isDeferredReview || (ready && configuration.scope.permits(intent.request,
                  host: intent.target.host, username: intent.target.username)) else { return false }
        let project = intent.request.webURL.gitLabProjectPath
        switch intent.kind {
        case .review:
            let rule = configuration.reviewRequested
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
        case .followUp:
            let rule = configuration.authorFeedback
            let workflow = configuration.workflowRules[.newDiscussion]
            return rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
                && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(intent.request)))
        case .pipeline:
            let rule = configuration.workflowRules[.pipelineFailure]
            return intent.request.author.username == intent.target.username && configuration.autoClaimPipelineFailures
                && rule.mode == .assistant && rule.includes(intent.request)
        default: return false
        }
    }

    struct RowInput {
        let account: Account?
        let automation: AutomationSettings
        let workflowEntries: [MergeWorkflowActivityEntry]
        var assistantReady = false
        var assistantChecking = false
        var confirmationBusy = false
        var conflictProcessing = false
        var pipelineProcessing = false
        var catalogLoading = false
        var catalogReadFailed = false
        var workflowReadFailed = false
        var aiOriginReadFailed = false
    }
    func rowInput(for row: MergeRequestBoardSnapshot.Row) -> RowInput {
        let facts = facts(for: row.item.mergeRequest)
        return .init(account: input.account, automation: input.automation, workflowEntries: input.workflowEntries,
            assistantReady: input.reviewAssistantReady, assistantChecking: input.assistantChecking,
            confirmationBusy: input.confirmationStates[row.id]?.isBusy == true,
            conflictProcessing: facts?.conflictProcessing == true, pipelineProcessing: facts?.pipelineProcessing == true,
            catalogLoading: input.catalogLoading, catalogReadFailed: input.catalogReadFailed,
            workflowReadFailed: facts?.workflowReadFailed == true, aiOriginReadFailed: facts?.aiOriginReadFailed == true)
    }
    static func reviewingContext(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> ReviewingContext {
        ReviewingContext(row: row, workflowState: ReviewingContext.workflowState(for: row, entries: input.workflowEntries),
            assistantReady: input.assistantReady, assistantChecking: input.assistantChecking,
            draftAutomationAllowed: input.automation.hasEnabledAutomation && row.displayRequest.map {
                input.automation.scope.permits($0, host: input.account?.host ?? "", username: input.account?.username ?? "")
            } == true)
    }
    private static func rowState(_ row: MergeRequestBoardSnapshot.Row, input: RowInput) -> BoardAttentionPresenter.RowState {
        .init(row: row, confirmationBusy: input.confirmationBusy,
            conflictProcessing: input.conflictProcessing, pipelineProcessing: input.pipelineProcessing)
    }
    static func attentionRefreshFailed(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> Bool {
        BoardAttentionPresenter.attentionRefreshFailed(row: rowState(row, input: input), refresh: .init(
            catalogReadFailed: input.catalogReadFailed, workflowReadFailed: input.workflowReadFailed,
            needsAIAssessment: input.automation.needsAIAssessment, aiOriginReadFailed: input.aiOriginReadFailed))
    }
    static func isRecheckingAttention(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> Bool {
        BoardAttentionPresenter.isRecheckingAttention(row: rowState(row, input: input), refresh: .init(
            catalogLoading: input.catalogLoading,
            providerChecking: input.assistantChecking && input.automation.packageDecision != .disabled,
            reviewingVerifying: !row.item.isAuthored && reviewingContext(for: row, input: input).nextStep == .verifying))
    }
    func reviewingContext(for row: MergeRequestBoardSnapshot.Row) -> ReviewingContext {
        Self.reviewingContext(for: row, input: rowInput(for: row))
    }
    func attentionRefreshFailed(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        Self.attentionRefreshFailed(for: row, input: rowInput(for: row))
    }
    func isRecheckingAttention(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        Self.isRecheckingAttention(for: row, input: rowInput(for: row))
    }

    func board(humanAttention: UserAttentionSnapshot? = nil, preservedOrder: [Item.ID: Int] = [:]) -> MergeRequestBoardSnapshot {
        let browser = self.browser
        let reviewed = browser.reviewed.filter { item in
            scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url).map {
                !input.ignoredTargets.contains($0) && input.trackedReviewedTargets.contains($0)
            } == true
        }
        let attention = attentionItems
        let evidence = attentionSnapshot?.evidence ?? []
        let prepared = Dictionary((browser.own + reviewed).map { catalog in
            (catalog.id, MRCurrentRowProjection(evidence: attention.first { $0.id == catalog.id }
                ?? evidence.first { $0.id == catalog.id } ?? catalog, catalog: catalog, username: input.account.username))
        }, uniquingKeysWith: { first, _ in first })
        return .init(own: browser.own, reviewed: reviewed, todos: input.todos, attention: attention,
            handoffs: input.handoffs, host: input.account.host, username: input.account.username,
            intents: input.intents, routedTodoIDs: input.routedTodoIDs, ignoredTargets: input.hiddenTargets,
            humanAttention: humanAttention, pinnedCards: input.pins, pipelineEvidence: input.pipelineEvidence,
            pipelineEvidenceCheckedAt: input.pipelineEvidenceCheckedAt, preservedOrder: preservedOrder,
            automation: input.automation, displayRequests: input.displayRequests, grouping: input.grouping,
            completions: input.completions, currentRows: prepared)
    }

    var pendingUserAttention: ConfirmedAttentionSnapshot.Input {
        // Deliberately unconfirmed; never obtain this input by reading the confirmed board.
        let board = board()
        let attention = attentionItems
        var rows: [BoardAttentionPresenter.PresentedRow] = []
        for row in board.own + board.reviewed {
            guard row.displayRequest?.state == "opened" else { continue }
            let target = MRAutomationScope.Target(host: input.account.host, username: input.account.username,
                projectID: row.id.projectID, iid: row.id.iid)
            guard !input.ignoredTargets.contains(target) else { continue }
            let classified = row.item.presentingHumanAttention(filtered: attention.first { $0.id == row.id },
                unfiltered: attentionSnapshot?.attention.first { $0.id == row.id }, assistantReady: preparing)
            let item = MRCurrentRowProjection(evidence: classified, catalog: row.displayItem,
                username: input.account.username).item
            let state = input.confirmationStates[row.id]
            let facts = facts(for: row.item.mergeRequest)
            let recoveryWaitsForHuman = (row.item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation)
                && row.hasIndependentStoppedWork
            let busy = row.latestJob?.operationalExecution?.state.isActive == true || state?.isBusy == true
                || row.item.aiOriginChecking
                || (!recoveryWaitsForHuman && (row.item.authorFeedbackStatus?.phase == .checking || row.item.draftProofRecoveryChecking))
                || facts?.conflictProcessing == true || facts?.pipelineProcessing == true
                || (!recoveryWaitsForHuman && !row.item.isAuthored && reviewingContext(for: row).isAutomaticProcessing)
            let automaticDrafts = row.evidenceMatchesCatalogContext ? item.draftIDsHandledAutomatically(
                automation: input.automation, target: target, assistantPreparing: preparing,
                publicationAutomatic: input.publicationAutomaticTargets.contains(target)) : []
            rows.append(.init(row: row, item: item, confirmationState: state, busy: busy,
                automaticDraftIDs: automaticDrafts, checking: isRecheckingAttention(for: row) || attentionRefreshFailed(for: row),
                automaticIntentIDs: Set(row.attentionIntents.filter { attentionIntentIsAutomatic($0, ready: preparing) }.map(\.id))))
        }
        return BoardAttentionPresenter.project(.init(account: input.account.presentationKey,
            host: input.account.host, username: input.account.username, rows: rows, proposals: board.proposals,
            otherTodos: board.otherTodos, inboxLoading: input.inboxLoading,
            assessingMentionNoteIDs: input.assessingMentionNoteIDs,
            assistantReady: input.assistantReady, assistantPreparing: preparing))
    }

    nonisolated static func browserItems(openItems: [Item], authored: [AuthoredMergeRequestStatus],
        host: String, username: String, ownCatalogIsAuthoritative: Bool, draftsLast: Bool) -> (own: [Item], reviewed: [Item]) {
        var rows = Dictionary(uniqueKeysWithValues: openItems.map { ($0.id, $0) })
        let currentAuthored = authored.filter {
            $0.request.author.username == username && $0.request.state == "opened"
                && $0.request.webURL.isGitLabMergeRequest(host: host, iid: $0.request.iid)
        }
        for status in currentAuthored {
            let request = status.request
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
            if ownCatalogIsAuthoritative && rows[id] == nil { continue }
            if let currentHead = rows[id]?.mergeRequest?.sha, currentHead != request.sha { continue }
            var item = rows[id] ?? .init(id: id, title: request.title, url: request.webURL)
            if item.mergeRequest == nil { item.mergeRequest = request }
            item.isAuthored = true
            rows[id] = item
        }
        let items = MergeRequestAttentionMonitor.Item.ordered(rows.values.filter {
            ["opened", "merged", "closed"].contains($0.mergeRequest?.state ?? "")
                && $0.url.isGitLabMergeRequest(host: host, iid: $0.id.iid)
                && $0.mergeRequest?.webURL.isGitLabMergeRequest(host: host, iid: $0.id.iid) == true
        }, draftsLast: draftsLast)
        let matchingStatuses = currentAuthored.filter { status in
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: status.request.projectID, iid: status.request.iid)
            guard let item = rows[id], item.mergeRequest?.sha == status.request.sha else { return false }
            return !status.blockers.isEmpty || item.canOfferMerge(using: status)
        }
        let orderedStatuses = AuthoredMergeRequestStatus.orderedForMerge(matchingStatuses)
        let ranks = Dictionary(orderedStatuses.enumerated().map {
            (MergeRequestAttentionMonitor.Item.ID(projectID: $0.element.request.projectID, iid: $0.element.request.iid), $0.offset)
        }, uniquingKeysWith: min)
        let own = items.filter { $0.mergeRequest?.author.username == username }.enumerated().sorted {
            let left = (draftsLast && $0.element.mergeRequest?.draft == true ? 1 : 0, ranks[$0.element.id] ?? Int.max, $0.offset)
            let right = (draftsLast && $1.element.mergeRequest?.draft == true ? 1 : 0, ranks[$1.element.id] ?? Int.max, $1.offset)
            return left < right
        }.map(\.element)
        let reviewed = items.filter {
            $0.mergeRequest?.author.username != username
        }
        return (own, reviewed)
    }
}
