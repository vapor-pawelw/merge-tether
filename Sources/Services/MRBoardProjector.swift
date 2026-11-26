import Foundation

/// Stateless display decisions over account-bound values. No settings, monitor, I/O or execution ownership.
@MainActor
struct MRBoardProjector {
    typealias Item = MergeRequestAttentionMonitor.Item
    typealias ItemPresentation = MergeRequestAttentionMonitor.ItemPresentation
    typealias Account = GitLabAccountSession
    struct RequestFacts {
        /// Includes the mutable fields consumed by CI/conflict/policy readers; envelope compatibility is weaker.
        private struct Fields: Hashable {
            struct Pipeline: Hashable {
                let id: Int?
                let projectID: Int?
                let status: GitLabPipelineStatus
                let sha: String?
                let ref: String?
                init(_ value: GitLabMergeRequest.Pipeline) {
                    id = value.id; projectID = value.projectID; status = value.status; sha = value.sha; ref = value.ref
                }
            }
            let context: MergeRequestDependencySummary.Context
            let authorID: Int
            let authorUsername: String
            let soleAssignee: GitLabAuthenticatedUser?
            let draft: Bool?
            let pipeline: Pipeline?
            let hasConflicts: Bool?
            let trainConflict: MergeTrainPreparationConflict?
            let trainEvidenceUnavailable: Bool
            let detailedMergeStatus: GitLabDetailedMergeStatus?
            let blockingDiscussionsResolved: Bool?
            let mergeWhenPipelineSucceeds: Bool?
            let canMerge: Bool?
            let labels: [String]
            init(_ request: GitLabMergeRequest) {
                context = .init(request)
                authorID = request.author.id; authorUsername = request.author.username; draft = request.draft
                soleAssignee = request.soleAssignee
                pipeline = request.headPipeline.map(Pipeline.init)
                hasConflicts = request.hasConflicts; detailedMergeStatus = request.detailedMergeStatus
                trainConflict = request.mergeTrainConflict; trainEvidenceUnavailable = request.mergeTrainEvidenceUnavailable
                blockingDiscussionsResolved = request.blockingDiscussionsResolved
                mergeWhenPipelineSucceeds = request.mergeWhenPipelineSucceeds; canMerge = request.canMerge
                labels = request.labels
            }
        }
        private struct Source: Hashable {
            let fields: Fields
            let title: Data
            let body: Data
            init(_ request: GitLabMergeRequest) {
                fields = .init(request)
                // String equality normalizes Unicode; the existing semantic digest hashes exact UTF-8 bytes.
                title = Data(request.title.utf8); body = Data((request.description ?? "").utf8)
            }
        }
        private struct Binding: Hashable {
            let fields: Fields
            let semanticContext: String
        }
        let request: GitLabMergeRequest
        private let source: Source
        private let binding: Binding
        var mergeAutomatic = false
        var conflictFailed = false
        var conflictProcessing = false
        var pipelineProcessing = false
        var workflowReadFailed = false
        var aiOriginReadFailed = false
        init(request: GitLabMergeRequest, mergeAutomatic: Bool = false, conflictFailed: Bool = false,
             conflictProcessing: Bool = false, pipelineProcessing: Bool = false, workflowReadFailed: Bool = false,
             aiOriginReadFailed: Bool = false,
             semanticFingerprint: (GitLabMergeRequest) -> String = { $0.semanticContextFingerprint }) {
            self.request = request; source = .init(request)
            binding = .init(fields: source.fields, semanticContext: semanticFingerprint(request))
            self.mergeAutomatic = mergeAutomatic; self.conflictFailed = conflictFailed
            self.conflictProcessing = conflictProcessing; self.pipelineProcessing = pipelineProcessing
            self.workflowReadFailed = workflowReadFailed; self.aiOriginReadFailed = aiOriginReadFailed
        }

        struct Index {
            private let semanticFingerprint: (GitLabMergeRequest) -> String
            private var bindings: [Source: Binding] = [:]
            private var factsByBinding: [Binding: RequestFacts] = [:]
            private(set) var values: [RequestFacts] = []

            init(_ facts: [RequestFacts] = [],
                 semanticFingerprint: @escaping (GitLabMergeRequest) -> String = { $0.semanticContextFingerprint }) {
                self.semanticFingerprint = semanticFingerprint
                for fact in facts { retain(fact) }
            }
            private mutating func retain(_ fact: RequestFacts) {
                bindings[fact.source] = fact.binding
                guard factsByBinding[fact.binding] == nil else { return }
                factsByBinding[fact.binding] = fact
                values.append(fact)
            }
            mutating func insert(_ request: GitLabMergeRequest, makeFacts: () -> RequestFacts) {
                guard bindings[Source(request)] == nil else { return }
                retain(makeFacts())
            }
            mutating func prepare(_ request: GitLabMergeRequest) {
                let source = Source(request)
                guard bindings[source] == nil else { return }
                bindings[source] = .init(fields: source.fields, semanticContext: semanticFingerprint(request))
            }
            func facts(for request: GitLabMergeRequest) -> RequestFacts? {
                let source = Source(request)
                let binding = bindings[source] ?? .init(fields: source.fields, semanticContext: semanticFingerprint(request))
                return factsByBinding[binding]
            }
        }
    }
    struct Input {
        let account: Account
        var attention: MergeRequestAttentionMonitor.PresentationSnapshot?
        var authored: [AuthoredMergeRequestStatus] = []
        var retainedRequests: [GitLabMergeRequest] = []
        var completionIDs: [Item.ID: UUID] = [:]
        var ownCatalogIsAuthoritative = false
        var treatSoleAssigneeAsOwn = true
        var reviewAssignments: [ReviewAssignmentLedger.Entry]?
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
        var publicationPolicies: [MRAutomationScope.Target: AutomaticPublicationPolicy] = [:]
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
        var hiddenReviewNotifications: [HiddenReview] = []
    }
    let input: Input
    private let requestFacts: RequestFacts.Index
    init(input: Input, semanticFingerprint: @escaping (GitLabMergeRequest) -> String = { $0.semanticContextFingerprint }) {
        self.input = input
        var facts = RequestFacts.Index(input.requestFacts, semanticFingerprint: semanticFingerprint)
        var items = input.attention?.evidence ?? []
        items.append(contentsOf: input.attention?.attention ?? [])
        items.append(contentsOf: input.attention?.catalog ?? [])
        var requests = items.compactMap(\.mergeRequest)
        requests.append(contentsOf: input.authored.map(\.request))
        requests.append(contentsOf: input.retainedRequests)
        requests.append(contentsOf: input.pipelineHandoffs.map(\.event.mergeRequest))
        requests.append(contentsOf: input.displayRequests)
        requests.append(contentsOf: input.pipelineEvidence)
        for request in requests { facts.prepare(request) }
        requestFacts = facts
    }
    private var preparing: Bool { input.assistantReady || input.assistantChecking }
    private var attentionSnapshot: MergeRequestAttentionMonitor.PresentationSnapshot? {
        guard let snapshot = input.attention, snapshot.host == input.account.host,
              snapshot.username == input.account.username, snapshot.revision == input.account.revision else { return nil }
        return snapshot
    }
    private func scopeTarget(projectID: Int, iid: Int, url: URL) -> MRAutomationScope.Target? {
        guard projectID > 0, iid > 0, url.isGitLabMergeRequest(host: input.account.host, iid: iid) else { return nil }
        return .mergeRequest(host: input.account.host, username: input.account.username, projectID: projectID, iid: iid)
    }
    private func facts(for request: GitLabMergeRequest?) -> RequestFacts? {
        guard let request else { return nil }
        return requestFacts.facts(for: request)
    }

    private func canMergeAutomatically(_ status: AuthoredMergeRequestStatus, item: Item) -> Bool {
        let request = status.request
        let account = input.account
        return preparing && status.mayAutoMerge && facts(for: request)?.mergeAutomatic == true
            && !AssistantJobExecution.hasUnfinishedWork(in: input.handoffs,
                for: .init(host: account.host, projectID: request.projectID, iid: request.iid), username: account.username,
                currentRequest: request, feedbackStatus: item.authorFeedbackStatus,
                discussionFingerprint: item.observedDiscussionFingerprint)
    }
    var catalogItems: [Item] {
        var rows = Dictionary((attentionSnapshot?.catalog ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in input.reviewAssignments ?? [] {
            let request = entry.request
            let id = request.mergeRequestID
            if rows[id] == nil {
                rows[id] = .init(id: id, title: request.title, url: request.webURL, mergeRequest: request)
            }
        }
        for request in input.retainedRequests {
            let id = request.mergeRequestID
            guard let target = scopeTarget(projectID: id.projectID, iid: id.iid, url: request.webURL) else { continue }
            if !MRAttentionRecord.sameContext(rows[id]?.mergeRequest, request) {
                rows[id] = .init(id: id, title: request.title, url: request.webURL,
                    mergeRequest: request, isAuthored: request.isOwned(by: input.account.username, includingSoleAssignee: input.treatSoleAssigneeAsOwn))
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
            scope: input.automation.scope, ownCatalogIsAuthoritative: input.ownCatalogIsAuthoritative, draftsLast: input.draftsLast,
            treatSoleAssigneeAsOwn: input.treatSoleAssigneeAsOwn)
    }
    var ownItems: [Item] { browser.own }
    var reviewedItems: [Item] {
        reviewedItems(in: browser)
    }

    private func reviewedItems(in browser: MergeRequestBrowserSnapshot) -> [Item] {
        let assignments = input.reviewAssignments.map {
            Set($0.map { Item.ID(projectID: $0.request.projectID, iid: $0.request.iid) })
        }
        return browser.reviewed.filter { item in
            guard item.mergeRequest?.state == .opened,
                  let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
                  !input.ignoredTargets.contains(target) else { return false }
            return assignments?.contains(item.id) ?? input.trackedReviewedTargets.contains(target)
        }
    }

    var attentionItems: [ItemPresentation] {
        var items = (attentionSnapshot?.attention ?? []).compactMap { evidence -> ItemPresentation? in
            var item = evidence.presentingVerifiedAuthorFeedback()
            guard !item.feedback.isEmpty else { return item }
            let remaining = input.remainingFeedbackIDs[item.id] ?? Set(item.feedback.compactMap(\.id))
            item.filterFeedback(item.feedback.filter { $0.id.map(remaining.contains) ?? true })
            return item.needsAttention ? item : nil
        }
        func include(_ request: GitLabMergeRequest, isAuthored: Bool = false, update: (inout Item) -> Void) {
            let index = items.firstIndex { $0.id == request.mergeRequestID }
            let previous = index.map { items[$0] }
            var evidence = previous?.evidence ?? Item(id: request.mergeRequestID, title: request.title, url: request.webURL,
                mergeRequest: request, isAuthored: isAuthored)
            if evidence.mergeRequest == nil { evidence.mergeRequest = request }
            update(&evidence)
            let item = previous?.replacingEvidence(evidence) ?? evidence.presentingVerifiedAuthorFeedback()
            if let index { items[index] = item }
            else { items.append(item) }
        }
        let handoffs = input.pipelineHandoffs
        for handoff in handoffs {
            include(handoff.event.mergeRequest) { $0.pipelineHandoffPending = true }
        }
        if !input.mrCatalogReadFailed {
            let host = input.account.host, username = input.account.username
            for status in input.authored where status.mayMergeManually {
                let request = status.request
                guard request.isOwned(by: username, includingSoleAssignee: input.treatSoleAssigneeAsOwn),
                      request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                      let current = catalogItems.first(where: {
                          $0.id.projectID == request.projectID && $0.id.iid == request.iid
                      }), current.mergeRequest?.isOwned(by: username, includingSoleAssignee: input.treatSoleAssigneeAsOwn) == true, current.canOfferManualMerge(using: status)
                else { continue }
                let id = request.mergeRequestID
                guard (items.first(where: { $0.id == id })?.draftCount ?? 0) == 0 else { continue }
                guard !canMergeAutomatically(status, item: current) else { continue }
                include(request, isAuthored: true) { $0.manualMergeAvailable = true }
            }
        }
        let visible = items.compactMap { item -> ItemPresentation? in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return item }
            let currentEvents = input.workflowEntries.filter {
                $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                    && $0.event.mergeRequest.sha == item.mergeRequest?.sha
            }
            var failures = Set(MergeWorkflowTrigger.allCases.filter { trigger in
                guard let entry = currentEvents.first(where: { $0.event.kind == trigger }) else { return false }
                return entry.state == .failed && !entry.isReadOnlyFailure
            })
            if input.feedbackLaunchFailures.contains(where: { $0.matches(item.evidence, host: input.account.host,
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
        return ItemPresentation.ordered(visible)
    }

    func attentionIntentIsAutomatic(_ intent: MRTodoIntent, ready: Bool) -> Bool {
        let configuration = input.automation
        guard configuration.hasAutomaticActionConsent, configuration.scope.resolve(intent.target).active,
              !input.ignoredTargets.contains(intent.target), intent.request.isOpen,
              intent.isDeferredReview || (ready && configuration.scope.permits(intent.request,
                  host: intent.target.host, username: intent.target.username)) else { return false }
        let project = intent.request.webURL.gitLabProjectPath
        switch intent.kind {
        case .review:
            guard !configuration.requireReviewStartConfirmation else { return false }
            let rule = configuration.reviewRequested
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
        case .followUp:
            let rule = configuration.authorFeedback
            let workflow = configuration.workflowRules[.newDiscussion]
            return rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
                && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(intent.request)))
        case .pipeline:
            let rule = configuration.workflowRules[.pipelineFailure]
            return intent.request.isOwned(by: intent.target.username, includingSoleAssignee: input.treatSoleAssigneeAsOwn) && configuration.autoClaimPipelineFailures
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
        var publicationRequiresAI: Bool?
    }
    func rowInput(for row: MergeRequestBoardSnapshot.Row) -> RowInput {
        let facts = facts(for: row.item.mergeRequest)
        let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        return .init(account: input.account, automation: input.automation, workflowEntries: input.workflowEntries,
            assistantReady: input.reviewAssistantReady, assistantChecking: input.assistantChecking,
            confirmationBusy: input.confirmationStates[row.id]?.isBusy == true,
            conflictProcessing: facts?.conflictProcessing == true, pipelineProcessing: facts?.pipelineProcessing == true,
            catalogLoading: input.catalogLoading, catalogReadFailed: input.catalogReadFailed,
            workflowReadFailed: facts?.workflowReadFailed == true, aiOriginReadFailed: facts?.aiOriginReadFailed == true,
            publicationRequiresAI: target.map { input.publicationPolicies[$0]?.requiresAI == true })
    }
    static func reviewingContext(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> ReviewingContext {
        ReviewingContext(row: row, workflowState: ReviewingContext.workflowState(for: row, entries: input.workflowEntries),
            assistantReady: input.assistantReady, assistantChecking: input.assistantChecking,
            draftAutomationAllowed: input.automation.hasEnabledAutomation && row.displayRequest.map {
                input.automation.scope.permits($0, host: input.account?.host ?? "", username: input.account?.username ?? "")
            } == true, viewerUsername: input.account?.username)
    }
    private static func rowState(_ row: MergeRequestBoardSnapshot.Row, input: RowInput) -> BoardAttentionPresenter.RowState {
        .init(row: row, confirmationBusy: input.confirmationBusy,
            conflictProcessing: input.conflictProcessing, pipelineProcessing: input.pipelineProcessing)
    }
    static func attentionRefreshFailed(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> Bool {
        !attentionRefreshFailures(for: row, input: input).isEmpty
    }
    static func attentionRefreshFailures(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> [RefreshFailure] {
        BoardAttentionPresenter.attentionRefreshFailures(row: rowState(row, input: input), refresh: .init(
            catalogReadFailed: input.catalogReadFailed, workflowReadFailed: input.workflowReadFailed,
            needsAIAssessment: input.publicationRequiresAI ?? input.automation.needsAIAssessment,
            aiOriginReadFailed: input.aiOriginReadFailed))
    }
    static func isRecheckingAttention(for row: MergeRequestBoardSnapshot.Row, input: RowInput) -> Bool {
        BoardAttentionPresenter.isRecheckingAttention(row: rowState(row, input: input), refresh: .init(
            catalogLoading: input.catalogLoading,
            providerChecking: input.assistantChecking && input.automation.hasAutomaticActionConsent,
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
        let reviewed = reviewedItems(in: browser)
        let newAssignments = Dictionary((input.reviewAssignments ?? []).compactMap { entry -> (Item.ID, Date)? in
            guard let date = entry.newSince else { return nil }
            return (.init(projectID: entry.request.projectID, iid: entry.request.iid), date)
        }, uniquingKeysWith: min)
        let attention = attentionItems
        let byID = Dictionary(attention.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let evidence = attentionSnapshot?.evidence ?? []
        let prepared = Dictionary((browser.own + reviewed).map { catalog in
            let presentation = byID[catalog.id]
            return (catalog.id, MRCurrentRowProjection(evidence: presentation?.evidence
                ?? evidence.first { $0.id == catalog.id } ?? catalog, catalog: catalog, username: input.account.username,
                presentation: presentation))
        }, uniquingKeysWith: { first, _ in first })
        let automaticMerges = Set(input.authored.compactMap { status -> Item.ID? in
            let request = status.request
            let id = request.mergeRequestID
            guard !input.mrCatalogReadFailed, request.isOwned(by: input.account.username, includingSoleAssignee: input.treatSoleAssigneeAsOwn),
                  let projection = prepared[id], projection.evidenceMatchesCatalogContext,
                  projection.item.canOfferManualMerge(using: status),
                  canMergeAutomatically(status, item: projection.item) else { return nil }
            return id
        })
        return .init(own: browser.own, reviewed: reviewed, todos: input.todos, attention: attention.map(\.evidence),
            handoffs: input.handoffs, host: input.account.host, username: input.account.username,
            intents: input.intents, routedTodoIDs: input.routedTodoIDs, ignoredTargets: input.hiddenTargets,
            humanAttention: humanAttention, pinnedCards: input.pins, pipelineEvidence: input.pipelineEvidence,
            pipelineEvidenceCheckedAt: input.pipelineEvidenceCheckedAt, preservedOrder: preservedOrder,
            automation: input.automation, displayRequests: input.displayRequests, grouping: input.grouping,
            completions: input.completions, hiddenReviewNotifications: input.hiddenReviewNotifications,
            currentRows: prepared, automaticMerges: automaticMerges, attentionPresentations: byID,
            assignmentsAreAuthoritative: input.reviewAssignments != nil, newReviewAssignments: newAssignments)
    }

    var pendingUserAttention: ConfirmedAttentionSnapshot.Input {
        // Deliberately unconfirmed; never obtain this input by reading the confirmed board.
        let board = board()
        let attention = attentionItems
        var rows: [BoardAttentionPresenter.PresentedRow] = []
        for row in board.own + board.reviewed {
            guard row.displayRequest?.state == .opened else { continue }
            let target = MRAutomationScope.Target.mergeRequest(host: input.account.host, username: input.account.username,
                projectID: row.id.projectID, iid: row.id.iid)
            guard !input.ignoredTargets.contains(target) else { continue }
            let classified = ItemPresentation.forHumanAttention(catalog: row.item,
                filtered: attention.first { $0.id == row.id },
                unfiltered: attentionSnapshot?.attention.first { $0.id == row.id }, assistantReady: preparing)
            let item = MRCurrentRowProjection(evidence: classified.evidence, catalog: row.displayItem,
                username: input.account.username, presentation: classified).presentation
            let state = input.confirmationStates[row.id]
            let facts = facts(for: row.item.mergeRequest)
            let recoveryWaitsForHuman = (row.item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation)
                && row.hasIndependentStoppedWork
            let busy = row.latestJob?.operationalExecution?.state.isActive == true || state?.isBusy == true
                || row.item.aiOriginChecking
                || (!recoveryWaitsForHuman && (row.presented.authorFeedbackStatus?.phase == .checking || row.item.draftProofRecoveryChecking))
                || facts?.conflictProcessing == true || facts?.pipelineProcessing == true
                || (!recoveryWaitsForHuman && !row.item.isAuthored && reviewingContext(for: row).isAutomaticProcessing)
            let automaticDrafts = row.evidenceMatchesCatalogContext ? input.publicationPolicies[target].map {
                item.evidence.draftIDsHandledAutomatically(automation: input.automation, target: target,
                    assistantPreparing: preparing, publicationPolicy: $0)
            } ?? [] : []
            rows.append(.init(row: row, item: item, confirmationState: state, busy: busy,
                automaticDraftIDs: automaticDrafts, checking: isRecheckingAttention(for: row) || attentionRefreshFailed(for: row),
                automaticIntentIDs: Set(row.attentionIntents.filter { attentionIntentIsAutomatic($0, ready: preparing) }.map(\.id))))
        }
        return BoardAttentionPresenter.project(.init(account: input.account,
            host: input.account.host, username: input.account.username, rows: rows, proposals: board.proposals,
            otherTodos: board.otherTodos, inboxLoading: input.inboxLoading,
            assessingMentionNoteIDs: input.assessingMentionNoteIDs,
            assistantReady: input.assistantReady, assistantPreparing: preparing))
    }

    nonisolated static func browserItems(openItems: [Item], authored: [AuthoredMergeRequestStatus],
        host: String, username: String, ownCatalogIsAuthoritative: Bool, draftsLast: Bool, treatSoleAssigneeAsOwn: Bool) -> (own: [Item], reviewed: [Item]) {
        var rows = Dictionary(uniqueKeysWithValues: openItems.map { ($0.id, $0) })
        let currentAuthored = authored.filter {
            $0.request.isOwned(by: username, includingSoleAssignee: treatSoleAssigneeAsOwn) && $0.request.isOpen
                && $0.request.webURL.isGitLabMergeRequest(host: host, iid: $0.request.iid)
        }
        for status in currentAuthored {
            let request = status.request
            let id = request.mergeRequestID
            if ownCatalogIsAuthoritative && rows[id] == nil { continue }
            if let currentHead = rows[id]?.mergeRequest?.sha, currentHead != request.sha { continue }
            var item = rows[id] ?? .init(id: id, title: request.title, url: request.webURL)
            if item.mergeRequest == nil { item.mergeRequest = request }
            if let current = item.mergeRequest, MergeRequestDependencySummary.Context(current) == .init(request),
               current.semanticContextFingerprint == request.semanticContextFingerprint, current.draft == request.draft {
                item.mergeRequest?.mergeTrainConflict = request.mergeTrainConflict
                item.mergeRequest?.mergeTrainEvidenceUnavailable = request.mergeTrainEvidenceUnavailable
                if request.mergeTrainConflict != nil { item.catalogIssues.insert(.conflict) }
            }
            item.isAuthored = true
            rows[id] = item
        }
        let visible = rows.values.filter {
            [.opened, .merged, .closed].contains($0.mergeRequest?.state)
                && $0.url.isGitLabMergeRequest(host: host, iid: $0.id.iid)
                && $0.mergeRequest?.webURL.isGitLabMergeRequest(host: host, iid: $0.id.iid) == true
        }.map { item in
            var item = item
            item.isAuthored = item.mergeRequest?.isOwned(by: username, includingSoleAssignee: treatSoleAssigneeAsOwn) == true
            return item.presentingVerifiedAuthorFeedback()
        }
        let items = ItemPresentation.ordered(visible, draftsLast: draftsLast).map(\.evidence)
        let matchingStatuses = currentAuthored.filter { status in
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: status.request.projectID, iid: status.request.iid)
            guard let item = rows[id], item.mergeRequest?.sha == status.request.sha else { return false }
            return !status.blockers.isEmpty || item.canOfferMerge(using: status)
        }
        let orderedStatuses = AuthoredMergeRequestStatus.orderedForMerge(matchingStatuses)
        let ranks = Dictionary(orderedStatuses.enumerated().map {
            (MergeRequestAttentionMonitor.Item.ID(projectID: $0.element.request.projectID, iid: $0.element.request.iid), $0.offset)
        }, uniquingKeysWith: min)
        let own = items.filter(\.isAuthored).enumerated().sorted {
            let left = (draftsLast && $0.element.mergeRequest?.draft == true ? 1 : 0, ranks[$0.element.id] ?? Int.max, $0.offset)
            let right = (draftsLast && $1.element.mergeRequest?.draft == true ? 1 : 0, ranks[$1.element.id] ?? Int.max, $1.offset)
            return left < right
        }.map(\.element)
        let reviewed = items.filter { !$0.isAuthored }
        return (own, reviewed)
    }
}
