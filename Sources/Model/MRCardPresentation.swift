import Foundation

/// The visible text and attention treatment shared by the Mac card and phone snapshot.
@MainActor
struct MRCardPresentation {
    struct Chip { let title: LocalizedStringResource; let symbol: String }
    let row: MergeRequestBoardSnapshot.Row
    let reviewingContext: ReviewingContext
    let allowsRemoval: Bool
    let assistantReady: Bool
    let confirmationState: MergeRequestAttentionMonitor.ConfirmationState?
    let automaticallyPublishedDraftIDs: Set<Int>
    let automaticConflictProgress: Bool
    private var item: MergeRequestAttentionMonitor.Item { row.item }

    init(row: MergeRequestBoardSnapshot.Row, reviewingContext: ReviewingContext,
         allowsRemoval: Bool, assistantReady: Bool,
         confirmationState: MergeRequestAttentionMonitor.ConfirmationState? = nil,
         automaticallyPublishedDraftIDs: Set<Int> = [], automaticConflictProgress: Bool = false) {
        self.row = row; self.reviewingContext = reviewingContext; self.allowsRemoval = allowsRemoval
        self.assistantReady = assistantReady; self.confirmationState = confirmationState
        self.automaticallyPublishedDraftIDs = automaticallyPublishedDraftIDs
        self.automaticConflictProgress = automaticConflictProgress
    }

    init(row: MergeRequestBoardSnapshot.Row, monitor: TodoMonitorService, allowsRemoval: Bool) {
        let ready = monitor.availableAssistants.contains(monitor.settings.automation.assistant)
        let target = monitor.scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
        let automatic = target.map {
            row.item.draftIDsHandledAutomatically(automation: monitor.settings.automation, target: $0,
                assistantPreparing: ready || monitor.assistantDependencies.isChecking)
        } ?? []
        self.init(row: row, reviewingContext: monitor.reviewingContext(for: row), allowsRemoval: allowsRemoval,
            assistantReady: ready, confirmationState: monitor.attention.confirmationStates[row.id],
            automaticallyPublishedDraftIDs: automatic,
            automaticConflictProgress: row.item.mergeRequest.map { monitor.automaticConflictIsProcessing(for: $0) } ?? false)
    }

    var busy: Bool {
        confirmationState == .publishing || confirmationState == .approving
            || item.authorFeedbackStatus?.phase == .checking || item.reReviewReadiness == .checking
            || item.aiOriginChecking || (allowsRemoval && reviewingContext.isAutomaticProcessing)
            || (automaticConflictProgress && row.latestJob?.execution?.state.isActive != true)
    }
    var working: Bool { busy || row.latestJob?.execution?.state.isActive == true }
    var humanAction: MRHumanAction? {
        guard row.needsAttention, !busy,
              !(allowsRemoval && reviewingContext.nextStep == .setupAgent) else { return nil }
        return MRHumanAction(row: row, assistantReady: assistantReady, confirmationState: confirmationState,
                             automaticallyPublishedDraftIDs: automaticallyPublishedDraftIDs)
    }
    var neutralStatus: LocalizedStringResource? {
        if item.authorFeedbackStatus?.waitingForReviewer == true { return .AuthorFeedback.authorFeedbackWaitingChip }
        guard allowsRemoval else { return nil }
        return reviewingContext.status == .activityUnknown ? reviewingContext.presenceMessage : reviewingContext.statusMessage
    }
    var message: String {
        guard let human = humanAction else { return "" }
        if let detail = human.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return detail }
        return String(localized: human.message)
    }
    var status: String? {
        if let job = row.latestJob, job.execution?.state.isActive == true {
            return String(localized: .Board.boardCompactWorking) + " · " + String(localized: job.key.assistant.displayName)
        }
        if busy { return String(localized: item.aiOriginChecking ? .MRDiscussions.mrDiscussionsAiChecking : .Board.boardCompactWorking) }
        return humanAction == nil ? neutralStatus.map { String(localized: $0) } : nil
    }
    var nextStep: String? {
        allowsRemoval && humanAction == nil && !busy ? String(localized: reviewingContext.nextStepMessage) : nil
    }
    var actionLabel: LocalizedStringResource? {
        guard !working else { return nil }
        if humanAction == nil, allowsRemoval, reviewingContext.nextStep == .runReview, !assistantReady {
            return .Board.boardCompactSetupCli
        }
        return humanAction?.actionLabel ?? (allowsRemoval ? reviewingContext.actionLabel : nil)
    }
    var chips: [Chip] {
        var result: [Chip] = []
        if item.hasConflict || item.mergeRequest?.hasMergeConflict == true {
            result.append(.init(title: .Board.boardCompactConflict, symbol: "arrow.triangle.branch"))
        }
        if item.failedPipeline || item.mergeRequest?.headPipeline?.status == "failed" {
            result.append(.init(title: .Board.boardCompactPipelineFailed, symbol: "xmark.circle"))
        } else if let pipeline = item.mergeRequest?.headPipeline,
                  ["running", "pending", "created", "preparing", "waiting_for_resource"].contains(pipeline.status) {
            result.append(.init(title: .Board.boardCompactPipelineRunning, symbol: "clock"))
        }
        if humanAction == nil, !busy, !allowsRemoval, max(item.draftCount, item.drafts.count) > 0 {
            result.append(.init(title: .Board.boardCompactDrafts(max(item.draftCount, item.drafts.count)), symbol: "text.bubble"))
        }
        return Array(result.prefix(2))
    }
}
