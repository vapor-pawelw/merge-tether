import Foundation

enum MergeRequestFinishedState: String {
    case merged, closed

    init?(_ request: GitLabMergeRequest?) {
        guard let state = request?.state else { return nil }
        self.init(rawValue: state)
    }

    var badge: LocalizedStringResource { self == .merged ? .MRLifecycle.merged : .MRLifecycle.closed }
    var status: LocalizedStringResource { self == .merged ? .MRLifecycle.mergedStatus : .MRLifecycle.closedStatus }
}

/// The visible text and attention treatment shared by the Mac card and phone snapshot.
@MainActor
struct MRCardPresentation {
    struct Chip { let title: LocalizedStringResource; let symbol: String }
    enum MergeStage: Equatable {
        case merging, inTrain, queued

        var title: LocalizedStringResource {
            switch self {
            case .merging: .AutomationProgress.progressMerging
            case .inTrain: .MergeActions.mergeActionsInTrain
            case .queued: .MergeActions.mergeActionsQueued
            }
        }

        var submission: MergeSubmissionState? {
            switch self {
            case .merging: nil
            case .inTrain: .inTrain
            case .queued: .queued
            }
        }
    }

    let row: MergeRequestBoardSnapshot.Row
    let preservedHumanAction: MRHumanAction?
    let isRefreshingAttention: Bool
    let showsReadProgress: Bool
    let refreshFailures: [RefreshFailure]
    var refreshFailed: Bool { !refreshFailures.isEmpty }
    /// Names the failed check inline; several failures collapse to a count with details on hover.
    var refreshFailureLabel: String? { RefreshFailure.label(refreshFailures) }
    var refreshFailureHelp: String? { RefreshFailure.help(refreshFailures) }
    let reviewingContext: ReviewingContext
    let allowsRemoval: Bool
    let assistantReady: Bool
    let assistant: AutomationAssistant
    let cliHoldKind: AssistantCLIHealthIssue.Kind?
    let confirmationState: MergeRequestAttentionMonitor.ConfirmationState?
    let automaticallyPublishedDraftIDs: Set<Int>
    let automaticConflictProgress: Bool
    let conflictReceipts: Set<MergeConflictReceipt>
    let automaticPipelineProgress: Bool
    let automaticMergeProgress: Bool
    let confirmedSubmission: MergeSubmissionState?
    private let automaticMergePolicyHold: LocalizedStringResource?
    private var item: MergeRequestAttentionMonitor.Item { row.item }
    private var finishedState: MergeRequestFinishedState? { .init(row.displayRequest) }

    init(row: MergeRequestBoardSnapshot.Row, reviewingContext: ReviewingContext,
         allowsRemoval: Bool, assistantReady: Bool,
         confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
         automaticallyPublishedDraftIDs: Set<Int> = [], automaticConflictProgress: Bool = false,
         automaticPipelineProgress: Bool = false, conflictReceipts: Set<MergeConflictReceipt> = [],
         preservedHumanAction: MRHumanAction? = nil, isRefreshingAttention: Bool = false, refreshFailures: [RefreshFailure] = [],
         showsReadProgress: Bool = true, automaticMergeProgress: Bool = false,
         cliHoldKind: AssistantCLIHealthIssue.Kind? = nil, assistant: AutomationAssistant = .codex,
         mergeStatus: AuthoredMergeRequestStatus? = nil, showsAutomaticMergePolicyHold: Bool = true) {
        self.row = row; self.reviewingContext = reviewingContext; self.allowsRemoval = allowsRemoval
        self.preservedHumanAction = preservedHumanAction; self.isRefreshingAttention = isRefreshingAttention
        self.refreshFailures = refreshFailures
        self.showsReadProgress = showsReadProgress
        self.automaticMergeProgress = automaticMergeProgress
        if row.evidenceMatchesCatalogContext, let request = row.displayRequest,
           let mergeStatus, mergeStatus.matchesCurrentRequest(request) {
            self.confirmedSubmission = mergeStatus.displayedSubmissionState
            self.automaticMergePolicyHold = showsAutomaticMergePolicyHold ? mergeStatus.automaticMergePolicyHold : nil
        } else {
            self.confirmedSubmission = nil
            self.automaticMergePolicyHold = nil
        }
        self.assistant = assistant
        self.cliHoldKind = cliHoldKind
        self.assistantReady = assistantReady; self.confirmationState = confirmationState
        self.automaticallyPublishedDraftIDs = automaticallyPublishedDraftIDs
        self.automaticConflictProgress = automaticConflictProgress
        self.automaticPipelineProgress = automaticPipelineProgress
        self.conflictReceipts = conflictReceipts
    }

    init(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, allowsRemoval: Bool) {
        self.init(row: row, monitor: monitor, allowsRemoval: allowsRemoval, input: monitor.boardRowInput(for: row))
    }

    init(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, allowsRemoval: Bool,
         input: MRBoardProjector.RowInput) {
        let ready = input.assistantReady
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        let automatic = row.evidenceMatchesCatalogContext ? target.map {
            row.item.draftIDsHandledAutomatically(automation: monitor.settings.configuredAutomation, target: $0,
                assistantPreparing: ready || input.assistantChecking,
                publicationPolicy: monitor.settings.publicationPolicy(for: $0))
        } ?? [] : []
        let mergeStatus = monitor.authoredMergeRequests.hasSyncedCurrentCatalog && row.evidenceMatchesCatalogContext
            ? monitor.authoredMergeRequests.requests.first {
                $0.request.projectID == row.id.projectID && $0.request.iid == row.id.iid
            } : nil
        let showsAutomaticMergePolicyHold = if let target, let request = row.displayRequest, mergeStatus?.automaticMergePolicyHold != nil {
            monitor.settings.permitsAutomaticAction(.merge, for: request, target: target)
        } else { false }
        self.init(row: row, reviewingContext: MRBoardProjector.reviewingContext(for: row, input: input), allowsRemoval: allowsRemoval,
            assistantReady: ready, confirmationState: monitor.attention.confirmationStates[row.id],
            automaticallyPublishedDraftIDs: automatic,
            automaticConflictProgress: input.conflictProcessing,
            automaticPipelineProgress: input.pipelineProcessing,
            conflictReceipts: monitor.settings.conflictReceipts,
            preservedHumanAction: monitor.confirmedHumanAction(for: row),
            isRefreshingAttention: MRBoardProjector.isRecheckingAttention(for: row, input: input),
            refreshFailures: MRBoardProjector.attentionRefreshFailures(for: row, input: input),
            showsReadProgress: monitor.showsRefreshProgress(for: row.id),
            automaticMergeProgress: row.displayRequest.map { monitor.authoredMergeRequests.isMerging($0) } ?? false,
            cliHoldKind: monitor.cliHealth.hold(for: row.latestJob?.key.assistant ?? monitor.settings.automation.assistant)?.issue.kind,
            assistant: input.automation.assistant, mergeStatus: mergeStatus,
            showsAutomaticMergePolicyHold: showsAutomaticMergePolicyHold)
    }

    var mergeStage: MergeStage? {
        guard let request = row.displayRequest, request.state == "opened", request.draft != true else { return nil }
        if automaticMergeProgress { return .merging }
        switch confirmedSubmission ?? (request.hasQueuedMerge ? .queued : .none) {
        case .inTrain: return .inTrain
        case .queued: return .queued
        default: return nil
        }
    }

    var mergeActivity: MRActivity? {
        guard mergeStage == .merging, row.latestJob?.execution?.state.isActive != true,
              progressTitle == .AutomationProgress.progressMerging else { return nil }
        return activity
    }

    private var recoveryWaitsForHuman: Bool {
        (item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation) && row.hasIndependentStoppedWork
    }
    var busy: Bool {
        guard finishedState == nil else { return false }
        if confirmationState?.isBusy == true { return true }
        return confirmationState == .publishing || confirmationState == .approving
            || (!recoveryWaitsForHuman && (item.authorFeedbackStatus?.phase == .checking || item.draftProofRecoveryChecking))
            || item.reReviewReadiness == .checking || item.aiOriginChecking
            || (!recoveryWaitsForHuman && allowsRemoval && reviewingContext.isAutomaticProcessing)
            || automaticPipelineProgress
            || automaticMergeProgress
            || (automaticConflictProgress && row.latestJob?.execution?.state.isActive != true)
    }
    private var executingWork: Bool {
        finishedState == nil && (confirmationState?.isBusy == true
            || row.latestJob?.operationalExecution?.state.isActive == true
            || automaticPipelineProgress || automaticConflictProgress || automaticMergeProgress
            || (!recoveryWaitsForHuman && allowsRemoval && reviewingContext.nextStep == .automaticReview))
    }
    private var quietReadCheck: Bool {
        !showsReadProgress && !executingWork && (busy || isRefreshingAttention)
    }
    private var waitingOnCLI: Bool {
        guard cliHoldKind != nil, row.latestJob?.execution?.state != .running,
              confirmationState?.isBusy != true,
              !automaticMergeProgress, !automaticPipelineProgress, !automaticConflictProgress else { return false }
        return row.latestJob?.execution?.state == .queued
            || (allowsRemoval && [.runReview, .automaticReview, .verifying].contains(reviewingContext.nextStep))
            || row.attentionIntents.contains { ($0.kind == .review || $0.kind == .followUp) && $0.state == .pending }
    }
    var working: Bool {
        finishedState == nil && !waitingOnCLI && (executingWork || busy
            || item.draftProofRecoveryChecking || checkingFollowUp
            || (showsReadProgress && isRefreshingAttention))
    }
    private var checkingFollowUp: Bool {
        item.authorFeedbackStatus?.phase == .checking || row.attentionIntents.contains(where: \.isAwaitingFollowUpVerification)
    }
    var activity: MRActivity? {
        guard working, let status else { return nil }
        if let job = row.latestJob, job.operationalExecution?.state.isActive == true {
            return .init(status: status, jobID: job.id,
                startedAt: job.execution?.state == .running ? job.execution?.startedAt ?? job.createdAt : job.createdAt)
        }
        return .init(status: status)
    }
    var actionsBlocked: Bool { finishedState != nil || busy || isRefreshingAttention || row.latestJob?.execution?.state.isActive == true }
    private var preservesConfirmedAttention: Bool {
        (isRefreshingAttention || refreshFailed) && row.needsAttention && preservedHumanAction != nil
            && row.latestJob?.operationalExecution?.state.isActive != true
            && confirmationState?.isBusy != true
            && !automaticConflictProgress && !automaticPipelineProgress && !automaticMergeProgress
    }
    var humanAction: MRHumanAction? {
        guard finishedState == nil else { return nil }
        if preservesConfirmedAttention { return preservedHumanAction }
        guard row.needsAttention, !busy,
              !(allowsRemoval && reviewingContext.nextStep == .setupAgent && !item.requiresCommentReview) else { return nil }
        return MRHumanAction(row: row, assistantReady: assistantReady, confirmationState: confirmationState,
                             automaticallyPublishedDraftIDs: automaticallyPublishedDraftIDs,
                             automaticMergePolicyHold: automaticMergePolicyHold)
    }
    var showsAdditionalCommentReview: Bool {
        finishedState == nil && item.requiresCommentReview && item.draftCount == 0 && item.drafts.isEmpty
            && humanAction?.kind != .commentReview
    }
    var waitingStatus: MRWaitingStatus? {
        // A quiet background read keeps the settled waiting list; only a shown refresh replaces it.
        guard mergeStage == nil, !busy, !working, !waitingOnCLI, !(isRefreshingAttention && showsReadProgress), !refreshFailed,
              humanAction == nil, confirmationState != .failed, confirmationState != .changed else { return nil }
        return MRWaitingStatus(row: row)
    }
    var neutralStatus: LocalizedStringResource? {
        if let finishedState { return finishedState.status }
        if waitingOnCLI {
            return cliHoldKind == .loginRequired ? .AutomationProgress.progressPausedLogin : .AutomationProgress.progressPausedLimit
        }
        if busy || (isRefreshingAttention && showsReadProgress) { return progressTitle }
        if let mergeStage { return mergeStage.title }
        if let waitingStatus { return waitingStatus.title }
        if let automaticMergePolicyHold { return automaticMergePolicyHold }
        guard allowsRemoval else {
            return row.isDraft ? .AutomationProgress.progressOwnDraft : .AutomationProgress.progressMonitoring
        }
        return reviewingContext.status == .activityUnknown ? reviewingContext.presenceMessage : reviewingContext.statusMessage
    }
    var message: String {
        guard let human = humanAction else { return "" }
        return human.explanation
    }
    var status: String? {
        if let finishedState { return String(localized: finishedState.status) }
        if waitingOnCLI { return neutralStatus.map { String(localized: $0) } }
        if let job = row.latestJob, job.execution?.state.isActive == true {
            return job.progressStatus(intents: row.intents, conflictReceipts: conflictReceipts)
        }
        if working {
            return activityEffect == nil ? String(localized: progressTitle) : MRActivity.agentStatus(progressTitle, assistant: assistant)
        }
        return humanAction == nil ? neutralStatus.map { String(localized: $0) } : nil
    }
    var activityEffect: MRActionEffect? {
        guard working else { return nil }
        if row.latestJob?.operationalExecution?.state.isActive == true { return .agent }
        return progress.effect
    }
    private var progressTitle: LocalizedStringResource { progress.title }
    private var progress: (title: LocalizedStringResource, effect: MRActionEffect?) {
        if confirmationState == .publishing { return (.AutomationProgress.progressPublishing, nil) }
        if confirmationState == .approving { return (.AutomationProgress.progressApproving, nil) }
        if confirmationState == .deleting { return (.CommentReview.commentReviewDeleting, nil) }
        if confirmationState == .finishingCommentReview { return (.CommentReview.commentReviewFinishing, nil) }
        if automaticMergeProgress { return (.AutomationProgress.progressMerging, nil) }
        if item.draftProofRecoveryChecking, !row.hasIndependentStoppedWork { return (.AutomationProgress.progressReplies, .aiCheck) }
        if item.aiOriginChecking { return (.AutomationProgress.progressAIAssistance, .aiCheck) }
        if item.draftProofRecoveryChecking { return (.AutomationProgress.progressReplies, .aiCheck) }
        if checkingFollowUp { return (.AutomationProgress.progressFeedbackCheck, .aiCheck) }
        if item.reReviewReadiness == .checking { return (.AutomationProgress.progressReviewReadiness, .aiCheck) }
        if automaticPipelineProgress { return (.AutomationProgress.progressPipeline, nil) }
        if automaticConflictProgress { return (.AutomationProgress.progressConflictPreparing, .agent) }
        if allowsRemoval, reviewingContext.nextStep == .verifying { return (.AutomationProgress.progressReviewCheck, nil) }
        if allowsRemoval, reviewingContext.nextStep == .automaticReview { return (.AutomationProgress.progressReviewPreparing, .agent) }
        return (isRefreshingAttention ? .AutomationProgress.progressRefreshing : .AutomationProgress.progressProcessing, nil)
    }
    var nextStep: String? {
        guard finishedState == nil else { return nil }
        if item.requiresCommentReview || item.draftCount > 0 {
            return String(localized: item.isAuthored ? .CommentReview.commentReviewAfterOwn : .CommentReview.commentReviewAfterReviewed)
        }
        return finishedState == nil && allowsRemoval && humanAction == nil && !busy
            && !(quietReadCheck && reviewingContext.status == .activityUnknown)
            ? String(localized: reviewingContext.nextStepMessage) : nil
    }
    /// The automation order with the step that currently holds the MR; Comment review is
    /// still open whenever this chain shows, so it is the current step.
    struct StepChain: Equatable {
        let steps: [LocalizedStringResource]
        let current: Int
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.current == rhs.current && lhs.steps.map { String(localized: $0) } == rhs.steps.map { String(localized: $0) }
        }
    }
    var stepChain: StepChain? {
        guard finishedState == nil, item.requiresCommentReview || item.draftCount > 0 else { return nil }
        let steps: [LocalizedStringResource] = item.isAuthored
            ? [.CommentReview.commentReviewStepCommentReview, .CommentReview.commentReviewStepReReviewReadiness,
               .CommentReview.commentReviewStepMergeChecks]
            : [.CommentReview.commentReviewStepCommentReview, .CommentReview.commentReviewStepReviewVerdict,
               .CommentReview.commentReviewStepApproval]
        return .init(steps: steps, current: 0)
    }
    var actionLabel: LocalizedStringResource? {
        guard finishedState == nil else { return nil }
        if waitingOnCLI && humanAction == nil { return nil }
        guard !actionsBlocked || preservesConfirmedAttention else { return nil }
        if humanAction == nil, allowsRemoval, reviewingContext.nextStep == .runReview, !assistantReady {
            return .Board.boardCompactSetupCli
        }
        return humanAction?.actionLabel ?? (allowsRemoval ? reviewingContext.actionLabel : nil)
    }
    var chips: [Chip] {
        guard finishedState == nil else { return [] }
        var result: [Chip] = []
        if row.displayRequest?.mergeTrainConflict != nil {
            result.append(.init(title: .MergeActions.mergeActionsTrainRebaseConflict, symbol: "arrow.triangle.branch"))
        } else if row.displayRequest?.hasMergeConflict == true || (row.evidenceMatchesCatalogContext && item.hasConflict) {
            result.append(.init(title: .Board.boardCompactConflict, symbol: "arrow.triangle.branch"))
        }
        if let pipeline = row.currentPipelineRequest?.headPipeline,
           ["running", "pending", "created", "preparing", "waiting_for_resource"].contains(pipeline.status) {
            result.append(.init(title: .Board.boardCompactPipelineRunning, symbol: "clock"))
        } else if automaticPipelineProgress {
            result.append(.init(title: .PipelineAutomation.pipelineHandling, symbol: "gearshape"))
        } else if item.failedPipeline || item.mergeRequest?.headPipeline?.status == "failed" {
            result.append(.init(title: .Board.boardCompactPipelineFailed, symbol: "xmark.circle"))
        }
        if humanAction == nil, !busy, !allowsRemoval, max(item.draftCount, item.drafts.count) > 0 {
            result.append(.init(title: .Board.boardCompactDrafts(max(item.draftCount, item.drafts.count)), symbol: "text.bubble"))
        }
        return Array(result.prefix(2))
    }
}
