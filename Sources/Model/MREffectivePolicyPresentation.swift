import Foundation

/// A description of existing policy, never an authorization to perform an action.
struct MREffectivePolicyPresentation {
    enum ReadState {
        case current, rechecking, unavailable

        init(catalogCurrent: Bool, sameContext: Bool, readFailed: Bool, rechecking: Bool) {
            guard catalogCurrent, sameContext, !readFailed else { self = .unavailable; return }
            self = rechecking ? .rechecking : .current
        }

        @MainActor
        init(catalogCurrent: Bool, row: MergeRequestBoardSnapshot.Row, input: MRBoardProjector.RowInput) {
            self.init(catalogCurrent: catalogCurrent, sameContext: row.evidenceMatchesCatalogContext,
                readFailed: MRBoardProjector.attentionRefreshFailed(for: row, input: input),
                rechecking: MRBoardProjector.isRecheckingAttention(for: row, input: input))
        }
    }

    enum Clause: Equatable {
        case publicationAfterChecks(AutomationPublicationMode), publicationManual
        case mergeManual, mergeAfterChecks, approvalManual, approvalAfterChecks, deliveryManual
        case draftPaused, scopePaused, automationOff, automationDecisionRequired, privateWork, savedDataHold, requiresVerification
        case assistantUnavailable, loginRequired, rateLimited, finishCommentReview
        case mergeSubmission(MergeSubmissionState)
    }

    struct Input {
        let request: GitLabMergeRequest?
        let submission: MergeSubmissionState
        let automaticActionsAllowed: Bool
        let packageDecision: AutomationPackageDecision
        let publicActionsAllowed: Bool
        let enabled: Bool
        let scopeActive: Bool
        let draftPaused: Bool
        let publicationMode: AutomationPublicationMode
        let publicationAllowed: Bool
        let mergeAllowed: Bool
        let approvalAllowed: Bool
        let owned: Bool
        let localDelivery: Bool
        let commentReview: Bool
        let assistantReady: Bool
        let cliHold: AssistantCLIHealthIssue.Kind?
        let readState: ReadState

        @MainActor
        init(request: GitLabMergeRequest?, target: MRAutomationScope.Target?, settings: SettingsManager,
             assistantReady: Bool, readState: ReadState = .current, submission: MergeSubmissionState = .none,
             cliHold: AssistantCLIHealthIssue.Kind? = nil) {
            let bound = request.flatMap { request in
                target.flatMap { target in
                    request.projectID == target.projectID && request.iid == target.iid
                        && request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid) ? request : nil
                }
            }
            self.request = bound
            self.submission = bound == nil ? .none : submission
            automaticActionsAllowed = settings.automaticActionsAllowed
            let automation = settings.configuredAutomation
            packageDecision = automation.packageDecision
            publicActionsAllowed = automation.allowAutomaticPublicActions
            enabled = automation.hasEnabledAutomation
            let scope = target.map { automation.scope.resolve($0, isDraft: bound?.draft == true || bound?.detailedMergeStatus == "draft_status") }
            scopeActive = scope?.active == true
            draftPaused = scope?.source == .draft
            publicationMode = automation.publicationMode
            publicationAllowed = (automation.publicationMode != .filtered || automation.publicationRestrictions.hasConditions) && bound.flatMap { request in
                target.map { settings.permitsAutomaticAction(.commentPublication, for: request, target: $0, ignoringGlobalSuspension: true) }
            } == true
            mergeAllowed = bound.flatMap { request in
                target.map { settings.permitsAutomaticAction(.merge, for: request, target: $0, ignoringGlobalSuspension: true) }
            } == true
            approvalAllowed = bound.flatMap { request in
                target.map { settings.permitsAutomaticAction(.approval, for: request, target: $0, ignoringGlobalSuspension: true) }
            } == true
            owned = bound?.author.username == target?.username && target != nil
            localDelivery = bound.flatMap { request in
                target.map { automation.followUpAutomationHold(for: request, target: $0) == nil }
            } == true && !automation.allowFollowUpPush
            commentReview = target.map { settings.pendingCommentReviews.contains($0) } == true
            self.assistantReady = assistantReady
            self.cliHold = cliHold
            self.readState = readState
        }
    }

    let clauses: [Clause]
    enum SettingsAction { case chooseAutomationSettings }
    var settingsAction: SettingsAction? { clauses.contains(.automationDecisionRequired) ? .chooseAutomationSettings : nil }

    init(input: Input) {
        guard let request = input.request else { clauses = [.requiresVerification]; return }
        guard request.state == "opened", input.submission != .merged else { clauses = []; return }
        if input.submission != .none { clauses = [.mergeSubmission(input.submission)]; return }
        if !input.automaticActionsAllowed { clauses = [.savedDataHold]; return }
        if input.packageDecision == .undecided { clauses = [.automationDecisionRequired]; return }
        if !input.enabled { clauses = [.automationOff]; return }
        guard request.draft != nil else { clauses = [.requiresVerification]; return }
        if !input.scopeActive { clauses = [input.draftPaused ? .draftPaused : .scopePaused]; return }
        if let hold = input.cliHold {
            clauses = [hold == .loginRequired ? .loginRequired : .rateLimited]; return
        }
        if !input.assistantReady { clauses = [.assistantUnavailable]; return }
        if input.readState == .unavailable { clauses = [.requiresVerification]; return }
        if !input.publicActionsAllowed { clauses = [.privateWork]; return }
        let publication: Clause = input.publicationAllowed ? .publicationAfterChecks(input.publicationMode) : .publicationManual
        let completion: Clause
        if input.commentReview { completion = .finishCommentReview }
        else if input.owned {
            completion = input.localDelivery ? .deliveryManual : input.mergeAllowed ? .mergeAfterChecks : .mergeManual
        } else { completion = input.approvalAllowed ? .approvalAfterChecks : .approvalManual }
        clauses = [publication, completion]
    }
}
