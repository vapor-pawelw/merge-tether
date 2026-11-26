import Foundation

extension MergeRequestAttentionMonitor {
    enum CatalogIssue: Hashable, Sendable {
        case conflict, changesRequested, failedPipeline

        static func observed(in request: GitLabMergeRequest) -> Set<Self> {
            var issues: Set<Self> = []
            if request.hasMergeConflict { issues.insert(.conflict) }
            if request.detailedMergeStatus == .requestedChanges { issues.insert(.changesRequested) }
            if request.headPipeline?.status == .failed || request.detailedMergeStatus == .ciMustPass {
                issues.insert(.failedPipeline)
            }
            return issues
        }
    }

    enum DiscussionObservation: Sendable {
        case resolved, unresolvedIncoming, unresolvedOther

        init(unresolved: Bool, includesOther: Bool) {
            self = includesOther ? .unresolvedOther : unresolved ? .unresolvedIncoming : .resolved
        }
    }

    enum ApprovalObservation: Equatable, Sendable {
        case unchecked
        case checked(manualVerdictPermitsApproval: Bool, automaticGatePassed: Bool, awaitsDiscussionReadiness: Bool)
        case manualFallback

        fileprivate var approval: Status.Approval {
            switch self {
            case .unchecked: .unavailable
            case .manualFallback: .manual
            case .checked(_, true, _): .automatic
            case .checked(true, false, let awaitsReadiness): awaitsReadiness ? .waitingForReadiness : .manual
            case .checked(false, false, _): .unavailable
            }
        }
    }

    struct Status: Sendable {
        enum Primary: Equatable, Sendable {
            case settled, actionRequired, confirmationRequired, waitingForApprovalReadiness, automaticApproval
        }

        enum Blocker: CaseIterable, Hashable, Sendable {
            case discussion, conflict, changesRequested, failedPipeline, pipelineHandoff, merge
            case discussionRecheck, reReviewUnconfirmed, feedback, reReviewReadiness, feedbackAssessment
        }

        enum Confirmation: CaseIterable, Hashable, Sendable { case commentReview, drafts, approval, reReview }
        enum Approval: Equatable, Sendable { case unavailable, manual, waitingForReadiness, automatic }

        let blockers: Set<Blocker>
        let confirmations: Set<Confirmation>
        let approval: Approval
        let isDraft: Bool

        init(evidence: Item) {
            var blockers: Set<Blocker> = []
            if evidence.discussionObservation != .resolved { blockers.insert(.discussion) }
            if evidence.catalogIssues.contains(.conflict) { blockers.insert(.conflict) }
            if evidence.catalogIssues.contains(.changesRequested) { blockers.insert(.changesRequested) }
            if evidence.catalogIssues.contains(.failedPipeline) { blockers.insert(.failedPipeline) }
            if evidence.pipelineHandoffPending { blockers.insert(.pipelineHandoff) }
            if evidence.manualMergeAvailable { blockers.insert(.merge) }
            if evidence.requiresDiscussionRecheck { blockers.insert(.discussionRecheck) }
            if evidence.reReviewUnconfirmed { blockers.insert(.reReviewUnconfirmed) }
            if !evidence.feedback.isEmpty { blockers.insert(.feedback) }
            if let readiness = evidence.reReviewReadiness, readiness != .checking { blockers.insert(.reReviewReadiness) }
            if evidence.authorFeedbackStatus?.needsAttention == true { blockers.insert(.feedbackAssessment) }

            var confirmations: Set<Confirmation> = []
            if evidence.requiresCommentReview { confirmations.insert(.commentReview) }
            if !evidence.drafts.isEmpty { confirmations.insert(.drafts) }
            let checkpointOpen = !confirmations.isEmpty
            let approval = checkpointOpen || blockers.contains(.changesRequested)
                ? Approval.unavailable : evidence.approvalObservation.approval
            if approval == .manual { confirmations.insert(.approval) }
            if !checkpointOpen, evidence.reReviewFeedbackChecked, evidence.reReviewReadiness?.canConfirm == true {
                confirmations.insert(.reReview)
            }

            self.init(blockers: blockers, confirmations: confirmations, approval: approval,
                isDraft: evidence.mergeRequest?.isDraft(fallback: evidence.draftFromTodo) ?? evidence.draftFromTodo)
        }

        private init(blockers: Set<Blocker>, confirmations: Set<Confirmation>, approval: Approval, isDraft: Bool) {
            self.blockers = blockers
            self.confirmations = confirmations
            self.approval = approval
            self.isDraft = isDraft
        }

        fileprivate func displaying(blockers: Set<Blocker>, hidesApproval: Bool) -> Self {
            .init(blockers: blockers, confirmations: hidesApproval ? confirmations.subtracting([.approval]) : confirmations,
                approval: hidesApproval ? .unavailable : approval, isDraft: isDraft)
        }

        var primary: Primary {
            if !blockers.isEmpty { return .actionRequired }
            if needsConfirmation { return .confirmationRequired }
            if approval == .automatic { return .automaticApproval }
            if approval == .waitingForReadiness { return .waitingForApprovalReadiness }
            return .settled
        }

        var needsAttention: Bool { primary == .actionRequired || primary == .confirmationRequired }
        var needsConfirmation: Bool { !confirmations.isEmpty }
        var section: Item.Section { isDraft ? .draftMergeRequests : openSection }
        var openSection: Item.Section { needsConfirmation && blockers.isEmpty ? .unpublishedComments : .open }
    }

    /// Current semantic feedback binding can inform merge checks independently of board visibility.
    struct VerifiedFeedback {
        let assessment: AuthorFeedbackStatus?
        let outstandingNotes: [GitLabMergeRequestDiscussion.Note]
        let discussionsRemainOpen: Bool
        let changesRemainRequested: Bool

        init(_ item: Item) {
            let observed = item.observedEvidenceContext
            let status = item.isAuthored ? item.authorFeedbackStatus : nil
            let policy: EvidenceContext.BindingPolicy = status?.phase == .complete ? .observedFeedback : .feedbackProgress
            guard let status, status.evidenceContext.binds(to: observed, policy: policy) else {
                assessment = nil
                outstandingNotes = item.feedback
                discussionsRemainOpen = item.needsDiscussion
                changesRemainRequested = item.needsChanges
                return
            }
            assessment = status
            guard status.phase == .complete else {
                outstandingNotes = item.feedback
                discussionsRemainOpen = item.needsDiscussion
                changesRemainRequested = item.needsChanges
                return
            }
            let addressed = status.addressedNoteIDs.subtracting(status.replyNoteIDs).union(status.ignoredNoteIDs)
            outstandingNotes = item.feedback.filter { $0.id.map(addressed.contains) != true }
            discussionsRemainOpen = outstandingNotes.isEmpty && outstandingNotes.count != item.feedback.count
                ? item.hasOtherUnresolvedDiscussions : item.needsDiscussion
            let waitingReviewers = Set(status.findings.filter { $0.state == .waitingAcceptance }.flatMap(\.waitingForReviewers))
            let reviewsHandedOff = item.changeRequestReviewers.map { requesters in
                requesters.isEmpty ? waitingReviewers.isSubset(of: item.confirmedPendingReReviewers)
                    : requesters.isSubset(of: waitingReviewers)
            } ?? false
            let awaitsReviewer = status.evidenceContext.binds(to: observed, policy: .semanticText)
                && !waitingReviewers.isEmpty && reviewsHandedOff && status.ignoredNoteIDs.isEmpty
                && outstandingNotes.isEmpty && !status.needsAttention
                && status.followUpNoteIDs.isEmpty && status.replyNoteIDs.isEmpty
                && status.pendingDraftCount == 0 && item.drafts.isEmpty
            changesRemainRequested = item.needsChanges && !awaitsReviewer
        }
    }

    /// Overlay for the board and inbox. Command guards receive the separately retained evidence.
    @dynamicMemberLookup
    struct ItemPresentation: Identifiable, Sendable {
        let evidence: Item
        private var status: Status
        private(set) var feedback: [GitLabMergeRequestDiscussion.Note]
        let authorFeedbackStatus: AuthorFeedbackStatus?
        var humanActionRequired: Bool?
        private var hiddenBlockers: Set<Status.Blocker> = []
        private var hidesApproval = false
        private var filteredNoteIDs: Set<Int>?
        private let verifiesFeedback: Bool
        private var addsMergeDecision = false

        init(evidence: Item, humanActionRequired: Bool? = nil, verifiesFeedback: Bool = true) {
            self.evidence = evidence
            self.humanActionRequired = humanActionRequired
            self.verifiesFeedback = verifiesFeedback
            guard verifiesFeedback else {
                status = evidence.status
                feedback = evidence.feedback
                authorFeedbackStatus = evidence.authorFeedbackStatus
                return
            }
            let verified = VerifiedFeedback(evidence)
            feedback = verified.outstandingNotes
            authorFeedbackStatus = verified.assessment
            let raw = evidence.status
            var blockers = raw.blockers
            if !verified.discussionsRemainOpen { blockers.remove(.discussion) }
            if !verified.changesRemainRequested { blockers.remove(.changesRequested) }
            if feedback.isEmpty { blockers.remove(.feedback) }
            if verified.assessment?.needsAttention != true { blockers.remove(.feedbackAssessment) }
            status = raw.displaying(blockers: blockers, hidesApproval: false)
        }

        var id: Item.ID { evidence.id }
        subscript<Value>(dynamicMember keyPath: KeyPath<Item, Value>) -> Value { evidence[keyPath: keyPath] }
        var needsDiscussion: Bool { status.blockers.contains(.discussion) }
        var needsChanges: Bool { status.blockers.contains(.changesRequested) }
        var hasConflict: Bool { status.blockers.contains(.conflict) }
        var failedPipeline: Bool { status.blockers.contains(.failedPipeline) }
        var canApprove: Bool { status.approval == .manual || status.approval == .waitingForReadiness }
        var autoApproveReady: Bool { status.approval == .automatic }
        var approvalWaitingForReadiness: Bool { status.approval == .waitingForReadiness }
        var needsMerge: Bool { status.blockers.contains(.merge) }
        var needsPipelineHandoff: Bool { status.blockers.contains(.pipelineHandoff) }
        var needsConfirmation: Bool { status.needsConfirmation }
        var needsAttention: Bool {
            (evidence.requiresCommentReview && evidence.drafts.isEmpty) || (humanActionRequired ?? status.needsAttention)
        }
        var section: Item.Section { status.section }
        var isCloseToMerge: Bool { evidence.isCloseToMerge(using: status, feedbackRemaining: !feedback.isEmpty) }

        static func forHumanAttention(catalog: Item, filtered: Self?, unfiltered: Item?, assistantReady: Bool) -> Self {
            if assistantReady {
                if let filtered { return filtered }
                let fallback = Item(id: catalog.id, title: catalog.title, url: catalog.url,
                    mergeRequest: catalog.mergeRequest, isAuthored: catalog.isAuthored)
                return Self(evidence: fallback)
            }
            var visible = Self(evidence: unfiltered ?? catalog)
            if filtered?.needsMerge == true { visible.includeMergeDecision() }
            return visible
        }

        static func ordered(_ items: [Self], draftsLast: Bool = true) -> [Self] {
            items.map { ($0, $0.evidence.mergeOrder(using: $0.status, draftsLast: draftsLast)) }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }

        func verifyingFeedback() -> Self {
            verifiesFeedback ? self : replacingEvidence(evidence)
        }

        private mutating func includeMergeDecision() {
            addsMergeDecision = true
            status = status.displaying(blockers: status.blockers.union([.merge]), hidesApproval: false)
        }

        func replacingEvidence(_ evidence: Item, keepsMergeDecision: Bool = true) -> Self {
            var updated = Self(evidence: evidence, humanActionRequired: humanActionRequired)
            if addsMergeDecision && keepsMergeDecision { updated.includeMergeDecision() }
            if let filteredNoteIDs {
                updated.filterFeedback(feedback.isEmpty ? [] : updated.feedback.filter { $0.id.map(filteredNoteIDs.contains) ?? true })
            }
            updated.hide(hiddenBlockers, approval: hidesApproval)
            return updated
        }

        mutating func hide(_ blockers: Set<Status.Blocker>, approval: Bool = false) {
            hiddenBlockers.formUnion(blockers)
            hidesApproval = hidesApproval || approval
            status = status.displaying(blockers: status.blockers.subtracting(blockers), hidesApproval: approval)
        }

        mutating func filterFeedback(_ notes: [GitLabMergeRequestDiscussion.Note]) {
            filteredNoteIDs = Set(notes.compactMap(\.id))
            feedback = notes
            if notes.isEmpty { hide(evidence.hasOtherUnresolvedDiscussions ? [.feedback] : [.feedback, .discussion]) }
        }

        func requiringUserAttention(
            automation: AutomationSettings, target: MRAutomationScope.Target,
            failedTriggers: Set<MergeWorkflowTrigger> = [], conflictTaskFailed: Bool = false,
            pipelineOwnedAutomatically: Bool = false, feedbackOwnedAutomatically: Bool = false
        ) -> Self {
            guard automation.hasAutomaticActionConsent, let request = evidence.authoredRequest, request.isOpen,
                  request.isOwned(by: target.username, includingAssignee: true),
                  request.projectID == target.projectID, request.iid == target.iid,
                  request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
                  automation.scope.permits(request, host: target.host, username: target.username) else { return self }
            func handles(_ trigger: MergeWorkflowTrigger) -> Bool {
                let rule = automation.workflowRules[trigger]
                return rule.mode == .assistant && rule.includes(request) && !failedTriggers.contains(trigger)
            }
            var visible = self
            if automation.conflictTasksEnabled && !conflictTaskFailed { visible.hide([.conflict]) }
            if handles(.pipelineFailure) && pipelineOwnedAutomatically && !evidence.needsPipelineHandoff { visible.hide([.failedPipeline]) }
            let feedbackRule = automation.authorFeedback
            let canPrepareFeedback = feedbackRule.runner == .assistant && feedbackRule.isConfigured
                && feedbackRule.includes(project: request.webURL.gitLabProjectPath)
            let handlesFeedback = !failedTriggers.contains(.newDiscussion) && (
                (canPrepareFeedback && (feedbackRule.isEnabled || handles(.newDiscussion)))
                    || (handles(.newDiscussion) && feedbackOwnedAutomatically))
            if handlesFeedback && !feedback.isEmpty { visible.filterFeedback([]) }
            if handles(.newDiscussion) && feedbackOwnedAutomatically { visible.hide([.changesRequested]) }
            return visible
        }
    }
}

extension MergeRequestAttentionMonitor.Item {
    var verifiedFeedback: MergeRequestAttentionMonitor.VerifiedFeedback { .init(self) }

    func presentingVerifiedAuthorFeedback() -> MergeRequestAttentionMonitor.ItemPresentation { .init(evidence: self) }

    func requiringUserAttention(
        automation: AutomationSettings, target: MRAutomationScope.Target,
        failedTriggers: Set<MergeWorkflowTrigger> = [], conflictTaskFailed: Bool = false,
        pipelineOwnedAutomatically: Bool = false, feedbackOwnedAutomatically: Bool = false
    ) -> MergeRequestAttentionMonitor.ItemPresentation {
        presentingVerifiedAuthorFeedback().requiringUserAttention(automation: automation, target: target,
            failedTriggers: failedTriggers, conflictTaskFailed: conflictTaskFailed,
            pipelineOwnedAutomatically: pipelineOwnedAutomatically, feedbackOwnedAutomatically: feedbackOwnedAutomatically)
    }
}
