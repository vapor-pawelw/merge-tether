import Foundation
import MergeTetherRemote

enum MergeRequestFinishedState: String, Error {
    case merged, closed

    init?(_ request: GitLabMergeRequest?) {
        guard let state = request?.state else { return nil }
        self.init(rawValue: state.rawValue)
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

    struct ConfirmationOffers {
        let publishableDraftIDs: [Int]
        let approve: Bool
        let confirmReReview: Bool
        let finishCommentReview: Bool

        init(evidence: MergeRequestAttentionMonitor.Item, offersPublishShortcut: Bool,
             contextMatches: Bool = true, blocked: Bool = false) {
            // A phone command needs a head-bound list of draft IDs.
            let canBindDrafts = evidence.mergeRequest?.sha != nil && !evidence.requiresDiscussionRecheck
                && evidence.drafts.allSatisfy { $0.id != nil && AutomaticPublicationPolicy.safeForAutomaticPublication($0) }
            publishableDraftIDs = offersPublishShortcut && contextMatches && !blocked && canBindDrafts
                ? evidence.publishAllDrafts.compactMap(\.id) : []
            approve = contextMatches && !blocked && evidence.canApprove
            confirmReReview = contextMatches && !blocked && evidence.canConfirmReReview
            finishCommentReview = !blocked && evidence.canFinishCommentReview
        }
    }

    enum CardActivity {
        enum Work { case confirmation, assistantJob, merging, pipeline, conflict, automaticReview }

        struct ReadCheck {
            let refresh: Bool
            enum Visibility { case shown, quiet, supersededByWork }
            let visibility: Visibility
            let busy: Bool
            let reconciliation: Bool

            var isActive: Bool { refresh || busy || reconciliation }
            var isQuiet: Bool { visibility == .quiet && (refresh || busy) }
            var showsWork: Bool { busy || reconciliation || (refresh && visibility == .shown) }
        }

        case finished
        case working(Work, busy: Bool, blocksActions: Bool = true)
        case waitingOnCLI(AssistantCLIHealthIssue.Kind, ReadCheck, hasActiveJob: Bool)
        case readCheck(ReadCheck, hasActiveJob: Bool)
        case blockedByJob
        case idle

        var busy: Bool {
            switch self {
            case .working(_, let busy, _): busy
            case .waitingOnCLI(_, let check, _), .readCheck(let check, _): check.busy
            default: false
            }
        }

        var quietReadCheck: Bool {
            switch self {
            case .waitingOnCLI(_, let check, _), .readCheck(let check, _): check.isQuiet
            default: false
            }
        }

        var working: Bool {
            switch self {
            case .working: true
            case .readCheck(let check, _): check.showsWork
            default: false
            }
        }

        var actionsBlocked: Bool {
            switch self {
            case .finished, .blockedByJob: true
            case .working(_, _, let blocksActions): blocksActions
            case .waitingOnCLI(_, let check, let queued), .readCheck(let check, let queued):
                check.refresh || check.busy || queued
            case .idle: false
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
    let confirmationState: MergeRequestAttentionMonitor.ConfirmationState?
    let automaticallyPublishedDraftIDs: Set<Int>
    let automaticConflictProgress: Bool
    let conflictReceipts: Set<MergeConflictReceipt>
    let automaticPipelineProgress: Bool
    let automaticMergeProgress: Bool
    let mergeControls: MRManualMergePresentation
    let confirmedSubmission: MergeSubmissionState?
    let cardActivity: CardActivity
    private let automaticMergePolicyHold: LocalizedStringResource?
    private var item: MergeRequestAttentionMonitor.ItemPresentation { row.presented }
    private var finishedState: MergeRequestFinishedState? { .init(row.displayRequest) }

    init(row: MergeRequestBoardSnapshot.Row, reviewingContext: ReviewingContext,
         allowsRemoval: Bool, assistantReady: Bool,
         confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
         automaticallyPublishedDraftIDs: Set<Int> = [], automaticConflictProgress: Bool = false,
         automaticPipelineProgress: Bool = false, conflictReceipts: Set<MergeConflictReceipt> = [],
         preservedHumanAction: MRHumanAction? = nil, isRefreshingAttention: Bool = false, refreshFailures: [RefreshFailure] = [],
         showsReadProgress: Bool = true, automaticMergeProgress: Bool = false,
         cliHoldKind: AssistantCLIHealthIssue.Kind? = nil, assistant: AutomationAssistant = .codex,
         mergeStatus: AuthoredMergeRequestStatus? = nil, showsAutomaticMergePolicyHold: Bool = true,
         hasCurrentMergeCatalog: Bool = true) {
        self.row = row; self.reviewingContext = reviewingContext; self.allowsRemoval = allowsRemoval
        self.preservedHumanAction = preservedHumanAction; self.isRefreshingAttention = isRefreshingAttention
        self.refreshFailures = refreshFailures
        self.showsReadProgress = showsReadProgress
        self.automaticMergeProgress = automaticMergeProgress
        let controls = MRManualMergePresentation(item: row.item, candidate: mergeStatus,
            evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext, hasCurrentCatalog: hasCurrentMergeCatalog)
        self.mergeControls = controls
        self.confirmedSubmission = controls.status?.displayedSubmissionState
        self.automaticMergePolicyHold = showsAutomaticMergePolicyHold ? controls.status?.automaticMergePolicyHold : nil
        self.assistant = assistant
        self.assistantReady = assistantReady; self.confirmationState = confirmationState
        self.automaticallyPublishedDraftIDs = automaticallyPublishedDraftIDs
        self.automaticConflictProgress = automaticConflictProgress
        self.automaticPipelineProgress = automaticPipelineProgress
        self.conflictReceipts = conflictReceipts
        self.cardActivity = Self.activity(for: row, reviewing: reviewingContext, allowsRemoval: allowsRemoval,
            confirmation: confirmationState, merging: automaticMergeProgress, pipeline: automaticPipelineProgress,
            conflict: automaticConflictProgress, isRefreshing: isRefreshingAttention, showsReadProgress: showsReadProgress,
            cliHold: cliHoldKind)
    }

    init(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, allowsRemoval: Bool) {
        let input = monitor.boardRowInput(for: row)
        self.init(row: row, monitor: monitor, allowsRemoval: allowsRemoval, input: input)
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
        let mergeStatus: AuthoredMergeRequestStatus?
        if monitor.authoredMergeRequests.hasSyncedCurrentCatalog, row.evidenceMatchesCatalogContext {
            mergeStatus = MRManualMergePresentation.candidate(for: row.item, in: monitor.authoredMergeRequests.requests)
        } else {
            mergeStatus = nil
        }
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
            showsAutomaticMergePolicyHold: showsAutomaticMergePolicyHold,
            hasCurrentMergeCatalog: monitor.authoredMergeRequests.hasSyncedCurrentCatalog)
    }

    var mergeStage: MergeStage? {
        guard let request = row.displayRequest, request.isOpen, request.draft != true else { return nil }
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

    var busy: Bool { cardActivity.busy }
    private var quietReadCheck: Bool { cardActivity.quietReadCheck }
    var working: Bool { cardActivity.working }
    var actionsBlocked: Bool { cardActivity.actionsBlocked }

    private var waitingOnCLI: Bool {
        if case .waitingOnCLI = cardActivity { return true }
        return false
    }

    private static func activity(for row: MergeRequestBoardSnapshot.Row, reviewing: ReviewingContext,
                                 allowsRemoval: Bool, confirmation: MergeRequestAttentionMonitor.ConfirmationState?,
                                 merging: Bool, pipeline: Bool, conflict: Bool, isRefreshing: Bool,
                                 showsReadProgress: Bool, cliHold: AssistantCLIHealthIssue.Kind?) -> CardActivity {
        guard MergeRequestFinishedState(row.displayRequest) == nil else { return .finished }
        if confirmation?.isBusy == true { return .working(.confirmation, busy: true) }
        if merging { return .working(.merging, busy: true) }
        if pipeline { return .working(.pipeline, busy: true) }

        let item = row.presented
        let execution = row.latestJob?.execution?.state
        let activeJob = execution?.isActive == true
        let recovering = item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation
        let recoveryWaitsForHuman = recovering && row.hasIndependentStoppedWork
        let checkingFeedback = item.authorFeedbackStatus?.phase == .checking
        let reviewingAutomatically = !recoveryWaitsForHuman && allowsRemoval && reviewing.isAutomaticProcessing
        let busy = (!recoveryWaitsForHuman && (checkingFeedback || item.draftProofRecoveryChecking))
            || item.reReviewReadiness == .checking || item.aiOriginChecking || reviewingAutomatically
        let operationalJob = row.latestJob?.operationalExecution?.state.isActive == true
        let startsReview = !recoveryWaitsForHuman && allowsRemoval && reviewing.nextStep == .automaticReview
        let visibility: CardActivity.ReadCheck.Visibility = operationalJob || startsReview ? .supersededByWork
            : showsReadProgress ? .shown : .quiet
        let reads = CardActivity.ReadCheck(refresh: isRefreshing, visibility: visibility, busy: busy,
            reconciliation: item.draftProofRecoveryChecking || checkingFeedback
                || row.attentionIntents.contains(where: \.isAwaitingFollowUpVerification))
        if conflict { return .working(.conflict, busy: busy || !activeJob) }

        if let cliHold, execution != .running, execution == .queued
            || (allowsRemoval && [.runReview, .automaticReview, .verifying].contains(reviewing.nextStep))
            || row.attentionIntents.contains(where: { ($0.kind == .review || $0.kind == .followUp) && $0.state == .pending }) {
            return .waitingOnCLI(cliHold, reads, hasActiveJob: activeJob)
        }
        let blocksActions = activeJob || isRefreshing || busy
        if operationalJob {
            return .working(.assistantJob, busy: busy, blocksActions: blocksActions)
        }
        if startsReview {
            return .working(.automaticReview, busy: busy, blocksActions: blocksActions)
        }
        if reads.isActive { return .readCheck(reads, hasActiveJob: activeJob) }
        return activeJob ? .blockedByJob : .idle
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
    var draftPublicationShortcut: MRHumanAction.DraftPublicationShortcut? {
        humanAction?.draftPublicationShortcut(for: item.drafts)
    }

    var confirmationOffers: ConfirmationOffers {
        .init(evidence: row.item, offersPublishShortcut: draftPublicationShortcut == .publishAll,
            contextMatches: row.evidenceMatchesCatalogContext, blocked: actionsBlocked)
    }

    var showsAdditionalCommentReview: Bool {
        finishedState == nil && item.requiresCommentReview && item.drafts.isEmpty
            && humanAction?.kind != .commentReview
    }
    var waitingStatus: MRWaitingStatus? {
        // A quiet background read keeps the settled waiting list; only a shown refresh replaces it.
        guard mergeStage == nil, !busy, !working, !waitingOnCLI, !(isRefreshingAttention && showsReadProgress), !refreshFailed,
              humanAction == nil, confirmationState != .failed, confirmationState != .changed else { return nil }
        return MRWaitingStatus(row: row)
    }
    private var generalNeutralStatus: LocalizedStringResource? {
        if let finishedState { return finishedState.status }
        if case .waitingOnCLI(let hold, _, _) = cardActivity {
            return hold == .loginRequired ? .AutomationProgress.progressPausedLogin : .AutomationProgress.progressPausedLimit
        }
        if busy || (isRefreshingAttention && showsReadProgress) { return progressTitle }
        if let mergeStage { return mergeStage.title }
        if let waitingStatus { return waitingStatus.title }
        if let automaticMergePolicyHold { return automaticMergePolicyHold }
        guard allowsRemoval else {
            return row.isDraft ? .AutomationProgress.progressOwnDraft : .AutomationProgress.progressMonitoring
        }
        return nil
    }
    var neutralStatus: LocalizedStringResource? {
        if let generalNeutralStatus { return generalNeutralStatus }
        return reviewingContext.status == .activityUnknown ? reviewingContext.presenceMessage : reviewingContext.statusMessage
    }
    var reviewCompletionInDetailsOnly: Bool {
        allowsRemoval && reviewingContext.isMonitoringCompletedReview && !working && !refreshFailed
            && generalNeutralStatus == nil && humanAction == nil
    }
    var cardNeutralStatus: LocalizedStringResource? {
        guard mergeStage == nil, confirmedSubmission == nil || confirmedSubmission == MergeSubmissionState.none,
              !reviewCompletionInDetailsOnly else { return nil }
        return neutralStatus
    }
    var cardWaitingRequirements: MRWaitingStatus? {
        guard humanAction == nil, cardNeutralStatus != nil, let waitingStatus,
              !waitingStatus.requirements.isEmpty else { return nil }
        return waitingStatus
    }
    var cardNextStep: String? { reviewCompletionInDetailsOnly ? nil : nextStep }
    var nextStepExplainsReviewThreadStatus: Bool {
        guard !working, !refreshFailed, humanAction == nil, generalNeutralStatus == nil,
              reviewingContext.nextStep == .monitoring else { return false }
        return switch reviewingContext.status {
        case .openThreads, .waitingForOtherDiscussions: true
        default: false
        }
    }
    var statusPeopleMessage: RemotePeopleMessage? {
        guard !working, !refreshFailed, humanAction == nil, generalNeutralStatus == nil else { return nil }
        return reviewingContext.status == .activityUnknown ? reviewingContext.presencePeopleMessage : reviewingContext.statusPeopleMessage
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
        if confirmationState == .removingApproval { return (.Board.boardApprovalsRemoving, nil) }
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
           [.running, .pending, .created, .preparing, .waitingForResource].contains(pipeline.status) {
            result.append(.init(title: .Board.boardCompactPipelineRunning, symbol: "clock"))
        } else if automaticPipelineProgress {
            result.append(.init(title: .PipelineAutomation.pipelineHandling, symbol: "gearshape"))
        } else if item.failedPipeline || item.mergeRequest?.headPipeline?.status == .failed {
            result.append(.init(title: .Board.boardCompactPipelineFailed, symbol: "xmark.circle"))
        }
        if humanAction == nil, !busy, !allowsRemoval, item.draftCount > 0 {
            result.append(.init(title: .Board.boardCompactDrafts(item.draftCount), symbol: "text.bubble"))
        }
        return Array(result.prefix(2))
    }
}
