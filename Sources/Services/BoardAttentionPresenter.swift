import Foundation
import Observation

/// Display-only confirmed state. Execution must continue to use live policy and GitLab evidence.
@MainActor @Observable
final class BoardAttentionPresenter {
    struct RowState {
        let row: MergeRequestBoardSnapshot.Row
        var confirmationBusy = false
        var conflictProcessing = false
        var pipelineProcessing = false
    }
    struct RefreshState {
        var catalogLoading = false
        var catalogReadFailed = false
        var providerChecking = false
        var reviewingVerifying = false
        var workflowReadFailed = false
        var needsAIAssessment = false
        var aiOriginReadFailed = false
    }

    private var confirmedAttention = ConfirmedAttentionSnapshot()
    private var activityTimeline = MRActivityTimeline()

    func updateAttention(_ input: ConfirmedAttentionSnapshot.Input) { confirmedAttention.update(input) }

    func userAttention(account: String?) -> UserAttentionSnapshot {
        confirmedAttention.matches(account: account) ? confirmedAttention.snapshot : .empty
    }

    func confirmedHumanAction(key: String?, account: String?) -> MRHumanAction? {
        guard confirmedAttention.matches(account: account), let key else { return nil }
        return confirmedAttention.humanActions[key]
    }

    func updateActivities(_ activities: [MRAutomationScope.Target: MRActivity], now: Date = Date()) {
        var updated = activityTimeline
        updated.update(activities, now: now)
        if updated != activityTimeline { activityTimeline = updated }
    }

    func activityStartedAt(target: MRAutomationScope.Target?, activity: MRActivity?) -> Date? {
        guard let target, let activity else { return nil }
        return activityTimeline.startedAt(for: target, activity: activity) ?? activity.startedAt
    }

    static func isExecuting(_ state: RowState) -> Bool {
        state.row.latestJob?.operationalExecution?.state.isActive == true || state.confirmationBusy
            || state.conflictProcessing || state.pipelineProcessing
    }

    static func attentionRefreshFailed(row state: RowState, refresh: RefreshState) -> Bool {
        let row = state.row
        guard !isExecuting(state), !row.hasIndependentStoppedWork else { return false }
        if row.item.authorFeedbackStatus?.isReadOnlyFailure == true { return true }
        if row.item.draftProofRecoveryReadFailure || refresh.workflowReadFailed { return true }
        if max(row.item.draftCount, row.item.drafts.count) > 0,
           refresh.needsAIAssessment, refresh.aiOriginReadFailed { return true }
        // A failed catalog cannot confirm a replacement projection for any of its rows.
        return refresh.catalogReadFailed
    }

    static func isRecheckingAttention(row state: RowState, refresh: RefreshState) -> Bool {
        guard !isExecuting(state) else { return false }
        let item = state.row.item
        return refresh.catalogLoading || refresh.providerChecking || item.aiOriginChecking || item.draftProofRecoveryChecking
            || item.authorFeedbackStatus?.phase == .checking || item.reReviewReadiness == .checking
            || (!item.isAuthored && refresh.reviewingVerifying)
    }
    struct PresentedRow {
        let row: MergeRequestBoardSnapshot.Row
        let item: MergeRequestAttentionMonitor.Item
        let confirmationState: MergeRequestAttentionMonitor.ConfirmationState?
        let busy: Bool
        let automaticDraftIDs: Set<Int>
        let checking: Bool
        let automaticIntentIDs: Set<UUID>
    }
    struct ProjectionInput {
        let account: String?
        let host: String
        let username: String
        let rows: [PresentedRow]
        let proposals: [MergeRequestBoardSnapshot.Proposal]
        let otherTodos: [Todo]
        let inboxLoading: Bool
        let assessingMentionNoteIDs: Set<Int>
        let assistantReady: Bool
        let assistantPreparing: Bool
    }

    /// Policy and freshness are already evaluated by the coordinator; this only composes display values.
    static func project(_ input: ProjectionInput) -> ConfirmedAttentionSnapshot.Input {
        var candidates: [UserAttentionSnapshot.Candidate] = []
        var checkingIDs: Set<String> = []
        var humanActions: [String: MRHumanAction] = [:]
        func key(_ project: Int, _ iid: Int) -> String { "\(input.host)/\(input.username)/mr/\(project)/\(iid)" }
        func eventToken(_ todo: Todo) -> String {
            "\(todo.id):\(todo.updatedAt?.timeIntervalSince1970 ?? todo.createdAt.timeIntervalSince1970):" + UserAttentionSnapshot.digest(todo.body + todo.displayTitle)
        }
        for presented in input.rows {
            let row = presented.row
            let item = presented.item
            let state = presented.confirmationState
            let automaticDrafts = presented.automaticDraftIDs
            var actions: [UserAttentionSnapshot.Action] = []
            func add(_ reason: UserAttentionSnapshot.Reason, _ token: String, automatic: Bool = false) {
                actions.append(.init(reason: reason, token: token, automatic: automatic))
            }
            let drafts = item.drafts.filter { !automaticDrafts.contains($0.id ?? -1) }
            for draft in drafts { add(.drafts, "\(draft.id ?? -1):" + UserAttentionSnapshot.digest(draft.note ?? "")) }
            if item.draftCount > 0 && item.drafts.isEmpty { add(.drafts, "unread-drafts") }
            if row.item.requiresCommentReview, row.item.draftCount == 0, row.item.drafts.isEmpty {
                add(.reviewConfirmation, "comment-review:" + (row.item.commentReviewSnapshot?.discussionFingerprint ?? "unchecked"))
            }
            if (item.canApprove && !item.approvalWaitingForReadiness) || (item.autoApproveReady && !input.assistantPreparing) {
                add(.approval, item.mergeRequest?.sha ?? "approval")
            }
            if item.needsPipelineHandoff { add(.pipelineHandoff, String(item.mergeRequest?.headPipeline?.id ?? 0)) }
            if item.failedPipeline && !item.needsPipelineHandoff { add(.pipeline, String(item.mergeRequest?.headPipeline?.id ?? 0)) }
            if item.hasConflict { add(.conflict, item.mergeRequest?.sha ?? "conflict") }
            if item.needsMerge { add(.merge, item.mergeRequest?.sha ?? "merge") }
            for note in item.feedback { add(.discussion, "\(note.id ?? 0):" + UserAttentionSnapshot.digest(note.body ?? "")) }
            if item.needsDiscussion && item.feedback.isEmpty { add(.discussion, item.reReviewFingerprint ?? "open-discussions") }
            if item.needsChanges { add(.discussion, "changes-requested") }
            if let feedback = row.item.authorFeedbackStatus, feedback.needsAttention {
                if feedback.phase == .failed { add(.failedWork, "author-feedback:" + feedback.fingerprint) }
                for finding in feedback.findings where [.needsChanges, .needsVerification].contains(finding.state) {
                    add(.discussion, "\(finding.id):" + UserAttentionSnapshot.digest(finding.reason ?? ""))
                }
            }
            if item.requiresDiscussionRecheck && item.reReviewReadiness != .checking { add(.review, item.mergeRequest?.sha ?? "recheck") }
            if item.canConfirmReReview || item.reReviewUnconfirmed { add(.reviewConfirmation, item.reReviewFingerprint ?? "confirm") }
            switch item.reReviewReadiness {
            case .manual, .unavailable, .failed: add(.reviewConfirmation, "verification-needs-input")
            case .blocked(let blockers), .uncertain(let blockers):
                for blocker in blockers { add(.discussion, "\(blocker.noteID):" + UserAttentionSnapshot.digest(blocker.reason)) }
            default: break
            }
            if state == .failed || state == .changed { add(.failedWork, "confirmation-\(String(describing: state))") }
            if let job = row.latestJob, let execution = job.operationalExecution,
               row.stoppedJobNeedsAttention, [.failed, .blocked, .interrupted].contains(execution.state),
               !row.intents.contains(where: { $0.jobID == job.id && $0.state == .completed }) {
                add(.failedWork, job.id.uuidString + ":" + execution.state.rawValue)
            }
            for intent in row.attentionIntents where intent.state != .completed && intent.state != .running {
                if intent.state == .failed {
                    add(.failedWork, intent.id.uuidString + ":" + (intent.jobID?.uuidString ?? "") + ":" + UserAttentionSnapshot.digest(intent.error ?? ""))
                } else {
                    let automatic = presented.automaticIntentIDs.contains(intent.id)
                    if intent.sourceEvents.isEmpty { add(.review, intent.id.uuidString, automatic: automatic) }
                    for event in intent.sourceEvents {
                        add(.review, "\(event.id):\(event.updatedAt?.timeIntervalSince1970 ?? event.createdAt.timeIntervalSince1970)", automatic: automatic)
                    }
                }
            }
            let id = key(row.id.projectID, row.id.iid)
            let candidate = UserAttentionSnapshot.Candidate(id: id, title: row.item.title,
                subtitle: row.item.url.gitLabProjectPath, actions: actions, working: presented.busy)
            candidates.append(candidate)
            if presented.checking { checkingIDs.insert(id) }
            if UserAttentionSnapshot(candidates: [candidate]).hasAttention {
                var confirmedItem = row.item
                confirmedItem.humanActionRequired = true
                let confirmedRow = MergeRequestBoardSnapshot.Row(item: confirmedItem, latestJob: row.latestJob,
                    intents: row.intents, pipelineEvidence: row.pipelineEvidence,
                    pipelineEvidenceCheckedAt: row.pipelineEvidenceCheckedAt)
                humanActions[id] = MRHumanAction(row: confirmedRow, assistantReady: input.assistantReady,
                    confirmationState: state, automaticallyPublishedDraftIDs: automaticDrafts)
            }
        }
        for proposal in input.proposals {
            let id = key(proposal.target.projectID, proposal.target.iid ?? 0)
            if input.inboxLoading { checkingIDs.insert(id) }
            let tokens = proposal.todos.map(eventToken)
            let actions = tokens.isEmpty ? [UserAttentionSnapshot.Action(reason: .proposal, token: "adopt")]
                : tokens.map { UserAttentionSnapshot.Action(reason: .proposal, token: $0) }
            candidates.append(.init(id: id,
                title: proposal.title, subtitle: proposal.url.gitLabProjectPath, actions: actions))
        }
        for todo in input.otherTodos {
            let id = todo.targetType == .mergeRequest && todo.target.iid != nil
                ? key(todo.project.id, todo.target.iid!) : "\(input.host)/\(input.username)/todo/\(todo.id)"
            if input.inboxLoading || todo.linkedNoteID.map({ input.assessingMentionNoteIDs.contains($0) }) == true { checkingIDs.insert(id) }
            candidates.append(.init(id: id, title: todo.displayTitle, subtitle: todo.project.pathWithNamespace,
                actions: [.init(reason: .otherEvent, token: eventToken(todo))]))
        }
        return .init(account: input.account, candidates: candidates,
            checkingIDs: checkingIDs, humanActions: humanActions)
    }
}
