import Foundation

enum MRFollowUpAutomationHold: Equatable {
    case packageDisabled, ignored, closed, scopePaused, draftPaused, assignmentPending, runnerUnsupported, notConfigured
    case projectExcluded, workflowExcluded, ruleDisabled, assistantUnavailable, retryRequired, readinessUnknown, loginRequired, rateLimited

    var message: LocalizedStringResource {
        switch self {
        case .packageDisabled: .AutomationHold.automationHoldPackageDisabled
        case .ignored: .AutomationHold.automationHoldIgnored
        case .closed: .AutomationHold.automationHoldClosed
        case .scopePaused: .AutomationHold.automationHoldScopePaused
        case .draftPaused: .AutomationHold.automationHoldDraftPaused
        case .assignmentPending: .Board.boardAssignmentAwaitingClaim
        case .runnerUnsupported: .AutomationHold.automationHoldRunnerUnsupported
        case .notConfigured: .AutomationHold.automationHoldNotConfigured
        case .projectExcluded: .AutomationHold.automationHoldProjectExcluded
        case .workflowExcluded: .AutomationHold.automationHoldWorkflowExcluded
        case .ruleDisabled: .AutomationHold.automationHoldRuleDisabled
        case .assistantUnavailable: .AutomationHold.automationHoldAssistantUnavailable
        case .retryRequired: .AutomationHold.automationHoldRetryRequired
        case .readinessUnknown: .AutomationHold.automationHoldReadinessUnknown
        case .loginRequired: .AutomationHold.automationHoldLoginRequired
        case .rateLimited: .AutomationHold.automationHoldRateLimited
        }
    }
}

extension AutomationSettings {
    /// Routing and presentation share this gate; adopting an event can precede Draft execution.
    func followUpAutomationHold(for request: GitLabMergeRequest, target: MRAutomationScope.Target,
                                ignored: Bool = false, includeDraftPolicy: Bool = true,
                                requiresTodoRouting: Bool = true) -> MRFollowUpAutomationHold? {
        if !hasAutomaticActionConsent { return .packageDisabled }
        if ignored { return .ignored }
        if !request.isOpen { return .closed }
        if scope.awaitsAssignmentClaim(request, target: target) { return .assignmentPending }
        if !scope.resolve(target).active { return .scopePaused }
        let rule = authorFeedback
        let workflow = workflowRules[.newDiscussion]
        let independentWorkflow = !requiresTodoRouting && workflow.mode == .assistant && workflow.includes(request)
        if !independentWorkflow {
            if rule.runner != .assistant { return .runnerUnsupported }
            if !rule.isConfigured { return .notConfigured }
            if !rule.includes(project: request.webURL.gitLabProjectPath) { return .projectExcluded }
            if !rule.isEnabled {
                if workflow.mode != .assistant { return .ruleDisabled }
                if !workflow.includes(request) { return .workflowExcluded }
            }
        }
        if includeDraftPolicy, !scope.permits(request, host: target.host, username: target.username) {
            if request.draft == nil && !request.isDraft { return .readinessUnknown }
            return request.isDraft ? .draftPaused : .scopePaused
        }
        return nil
    }
}
