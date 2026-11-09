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
    let row: MergeRequestBoardSnapshot.Row
    let preservedHumanAction: MRHumanAction?
    let isRefreshingAttention: Bool
    let showsReadProgress: Bool
    let refreshFailed: Bool
    let reviewingContext: ReviewingContext
    let allowsRemoval: Bool
    let assistantReady: Bool
    let cliHoldKind: AssistantCLIHealthIssue.Kind?
    let confirmationState: MergeRequestAttentionMonitor.ConfirmationState?
    let automaticallyPublishedDraftIDs: Set<Int>
    let automaticConflictProgress: Bool
    let conflictReceipts: Set<MergeConflictReceipt>
    let automaticPipelineProgress: Bool
    let automaticMergeProgress: Bool
    private var item: MergeRequestAttentionMonitor.Item { row.item }
    private var finishedState: MergeRequestFinishedState? { .init(item.mergeRequest) }

    init(row: MergeRequestBoardSnapshot.Row, reviewingContext: ReviewingContext,
         allowsRemoval: Bool, assistantReady: Bool,
         confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
         automaticallyPublishedDraftIDs: Set<Int> = [], automaticConflictProgress: Bool = false,
         automaticPipelineProgress: Bool = false, conflictReceipts: Set<MergeConflictReceipt> = [],
         preservedHumanAction: MRHumanAction? = nil, isRefreshingAttention: Bool = false, refreshFailed: Bool = false,
         showsReadProgress: Bool = true, automaticMergeProgress: Bool = false,
         cliHoldKind: AssistantCLIHealthIssue.Kind? = nil) {
        self.row = row; self.reviewingContext = reviewingContext; self.allowsRemoval = allowsRemoval
        self.preservedHumanAction = preservedHumanAction; self.isRefreshingAttention = isRefreshingAttention
        self.refreshFailed = refreshFailed
        self.showsReadProgress = showsReadProgress
        self.automaticMergeProgress = automaticMergeProgress
        self.cliHoldKind = cliHoldKind
        self.assistantReady = assistantReady; self.confirmationState = confirmationState
        self.automaticallyPublishedDraftIDs = automaticallyPublishedDraftIDs
        self.automaticConflictProgress = automaticConflictProgress
        self.automaticPipelineProgress = automaticPipelineProgress
        self.conflictReceipts = conflictReceipts
    }

    init(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, allowsRemoval: Bool) {
        let ready = monitor.assistantDependencies.available.contains(monitor.settings.automation.assistant)
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        let automatic = target.map {
            row.item.draftIDsHandledAutomatically(automation: monitor.settings.automation, target: $0,
                assistantPreparing: ready || monitor.assistantDependencies.isChecking,
                publicationAutomatic: monitor.settings.actionIsAutomatic(.commentPublication, for: $0))
        } ?? []
        self.init(row: row, reviewingContext: monitor.reviewingContext(for: row), allowsRemoval: allowsRemoval,
            assistantReady: ready, confirmationState: monitor.attention.confirmationStates[row.id],
            automaticallyPublishedDraftIDs: automatic,
            automaticConflictProgress: row.item.mergeRequest.map { monitor.automaticConflictIsProcessing(for: $0) } ?? false,
            automaticPipelineProgress: row.item.mergeRequest.map { monitor.authoredMergeRequests.workflow.isAutomaticallyProcessingPipeline($0) } ?? false,
            conflictReceipts: monitor.settings.conflictReceipts,
            preservedHumanAction: monitor.confirmedHumanAction(for: row),
            isRefreshingAttention: monitor.isRecheckingAttention(for: row), refreshFailed: monitor.attentionRefreshFailed(for: row),
            showsReadProgress: monitor.showsRefreshProgress(for: row.id),
            automaticMergeProgress: row.item.mergeRequest.map { monitor.authoredMergeRequests.isMerging($0) } ?? false,
            cliHoldKind: monitor.cliHealth.hold(for: row.latestJob?.key.assistant ?? monitor.settings.automation.assistant)?.issue.kind)
    }

    private var recoveryWaitsForHuman: Bool {
        (item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation) && row.hasIndependentStoppedWork
    }
    var busy: Bool {
        guard finishedState == nil else { return false }
        return confirmationState == .publishing || confirmationState == .approving
            || (!recoveryWaitsForHuman && (item.authorFeedbackStatus?.phase == .checking || item.draftProofRecoveryChecking))
            || item.reReviewReadiness == .checking || item.aiOriginChecking
            || (!recoveryWaitsForHuman && allowsRemoval && reviewingContext.isAutomaticProcessing)
            || automaticPipelineProgress
            || automaticMergeProgress
            || (automaticConflictProgress && row.latestJob?.execution?.state.isActive != true)
    }
    private var executingWork: Bool {
        finishedState == nil && (confirmationState == .publishing || confirmationState == .approving
            || row.latestJob?.operationalExecution?.state.isActive == true
            || automaticPipelineProgress || automaticConflictProgress || automaticMergeProgress
            || (!recoveryWaitsForHuman && allowsRemoval && reviewingContext.nextStep == .automaticReview))
    }
    private var quietReadCheck: Bool {
        !showsReadProgress && !executingWork && (busy || isRefreshingAttention)
    }
    private var waitingOnCLI: Bool {
        guard cliHoldKind != nil, row.latestJob?.execution?.state != .running,
              confirmationState != .publishing, confirmationState != .approving,
              !automaticMergeProgress, !automaticPipelineProgress, !automaticConflictProgress else { return false }
        return row.latestJob?.execution?.state == .queued
            || (allowsRemoval && [.runReview, .automaticReview, .verifying].contains(reviewingContext.nextStep))
            || row.attentionIntents.contains { ($0.kind == .review || $0.kind == .followUp) && $0.state == .pending }
    }
    var working: Bool {
        finishedState == nil && !waitingOnCLI && (executingWork || busy
            || item.draftProofRecoveryChecking || item.authorFeedbackStatus?.phase == .checking
            || (showsReadProgress && isRefreshingAttention))
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
            && confirmationState != .publishing && confirmationState != .approving
            && !automaticConflictProgress && !automaticPipelineProgress && !automaticMergeProgress
    }
    var humanAction: MRHumanAction? {
        guard finishedState == nil else { return nil }
        if preservesConfirmedAttention { return preservedHumanAction }
        guard row.needsAttention, !busy,
              !(allowsRemoval && reviewingContext.nextStep == .setupAgent) else { return nil }
        return MRHumanAction(row: row, assistantReady: assistantReady, confirmationState: confirmationState,
                             automaticallyPublishedDraftIDs: automaticallyPublishedDraftIDs)
    }
    var neutralStatus: LocalizedStringResource? {
        if let finishedState { return finishedState.status }
        if waitingOnCLI {
            return cliHoldKind == .loginRequired ? .AutomationProgress.progressPausedLogin : .AutomationProgress.progressPausedLimit
        }
        if busy || (isRefreshingAttention && showsReadProgress) { return progressTitle }
        if item.authorFeedbackStatus?.waitingForReviewer == true { return .AuthorFeedback.authorFeedbackWaitingChip }
        guard allowsRemoval else {
            return item.section == .draftMergeRequests ? .AutomationProgress.progressOwnDraft : .AutomationProgress.progressMonitoring
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
            return String(localized: job.progressTitle(intents: row.intents, conflictReceipts: conflictReceipts)) + " · " + String(localized: job.key.assistant.displayName)
        }
        if working { return String(localized: progressTitle) }
        return humanAction == nil ? neutralStatus.map { String(localized: $0) } : nil
    }
    private var progressTitle: LocalizedStringResource {
        if confirmationState == .publishing { return .AutomationProgress.progressPublishing }
        if confirmationState == .approving { return .AutomationProgress.progressApproving }
        if automaticMergeProgress { return .AutomationProgress.progressMerging }
        if item.draftProofRecoveryChecking, !row.hasIndependentStoppedWork { return .AutomationProgress.progressReplies }
        if item.aiOriginChecking { return .AutomationProgress.progressAIAssistance }
        if item.draftProofRecoveryChecking { return .AutomationProgress.progressReplies }
        if item.authorFeedbackStatus?.phase == .checking { return .AutomationProgress.progressFeedbackCheck }
        if item.reReviewReadiness == .checking { return .AutomationProgress.progressReviewReadiness }
        if automaticPipelineProgress { return .AutomationProgress.progressPipeline }
        if automaticConflictProgress { return .AutomationProgress.progressConflictPreparing }
        if allowsRemoval, reviewingContext.nextStep == .verifying { return .AutomationProgress.progressReviewCheck }
        if allowsRemoval, reviewingContext.nextStep == .automaticReview { return .AutomationProgress.progressReviewPreparing }
        return isRefreshingAttention ? .AutomationProgress.progressRefreshing : .AutomationProgress.progressProcessing
    }
    var nextStep: String? {
        finishedState == nil && allowsRemoval && humanAction == nil && !busy
            && !(quietReadCheck && reviewingContext.status == .activityUnknown)
            ? String(localized: reviewingContext.nextStepMessage) : nil
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
        if item.hasConflict || item.mergeRequest?.hasMergeConflict == true {
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
