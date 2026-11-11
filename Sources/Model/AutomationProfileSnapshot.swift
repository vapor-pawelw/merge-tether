import Foundation

/// Only profile-managed permissions; restoring this leaves account, filters and task configuration intact.
struct AutomationProfileSnapshot: Codable, Equatable, Sendable {
    struct Rule: Codable, Equatable, Sendable {
        let enabled: Bool
        let markDone: Bool
        init(_ rule: AutomationRule) { enabled = rule.isEnabled; markDone = rule.markDoneOnSuccess }
        func apply(to rule: inout AutomationRule) { rule.isEnabled = enabled; rule.markDoneOnSuccess = markDone }
    }

    let packageDecision: AutomationPackageDecision
    let publicActions: Bool
    let verification: Bool
    let reReview: Bool
    let approval: Bool
    let merge: Bool
    let followUpPush: Bool
    let ownThreadResolution: Bool
    let acceptedFeedbackResolution: Bool
    let conflicts: Bool
    let tools: Bool
    let conflictPush: Bool
    let pipelineOwnership: Bool
    let publication: AutomationPublicationMode
    let requireAI: Bool
    let reviewRule: Rule
    let feedbackRule: Rule
    let eventModes: [String: MergeWorkflowMode]
    let infrastructureRetry: Bool

    init(_ configuration: AutomationSettings) {
        packageDecision = configuration.packageDecision
        publicActions = configuration.allowAutomaticPublicActions
        verification = configuration.autoVerifyReReview
        reReview = configuration.autoReReviewEnabled
        approval = configuration.autoApproveEnabled
        merge = configuration.autoMergeEnabled
        followUpPush = configuration.allowFollowUpPush
        ownThreadResolution = configuration.autoResolveOwnReviewThreads
        acceptedFeedbackResolution = configuration.autoResolveAcceptedFeedback
        conflicts = configuration.conflictTasksEnabled
        tools = configuration.allowAssistantTools
        conflictPush = configuration.allowConflictPush
        pipelineOwnership = configuration.autoClaimPipelineFailures
        publication = configuration.publicationMode
        requireAI = configuration.publicationRestrictions.requireAI
        reviewRule = Rule(configuration.reviewRequested)
        feedbackRule = Rule(configuration.authorFeedback)
        eventModes = Dictionary(uniqueKeysWithValues: MergeWorkflowTrigger.allCases.map { ($0.rawValue, configuration.workflowRules[$0].mode) })
        infrastructureRetry = configuration.workflowRules[.pipelineFailure].retryInfrastructureFailure
    }

    var isValid: Bool {
        packageDecision == .enabled
            && Set(eventModes.keys) == Set(MergeWorkflowTrigger.allCases.map(\.rawValue))
            && MergeWorkflowTrigger.allCases.allSatisfy { trigger in
                eventModes[trigger.rawValue].map { trigger.allowedModes.contains($0) } == true
            }
    }

    static func custom(from configuration: AutomationSettings) -> Self? {
        configuration.hasAutomaticActionConsent && configuration.matchingPreset == nil ? Self(configuration) : nil
    }

    static func remembering(previous: AutomationSettings, current: AutomationSettings, last: Self?) -> Self? {
        custom(from: current) ?? custom(from: previous) ?? last
    }

    func apply(to configuration: inout AutomationSettings) {
        guard isValid else { return }
        configuration.packageDecision = packageDecision
        configuration.allowAutomaticPublicActions = publicActions
        configuration.autoVerifyReReview = verification
        configuration.autoReReviewEnabled = reReview
        configuration.autoApproveEnabled = approval
        configuration.autoMergeEnabled = merge
        configuration.allowFollowUpPush = followUpPush
        configuration.autoResolveOwnReviewThreads = ownThreadResolution
        configuration.autoResolveAcceptedFeedback = acceptedFeedbackResolution
        configuration.conflictTasksEnabled = conflicts
        configuration.allowAssistantTools = tools
        configuration.allowConflictPush = conflictPush
        configuration.autoClaimPipelineFailures = pipelineOwnership
        configuration.publicationMode = publication
        configuration.publicationRestrictions.requireAI = requireAI
        reviewRule.apply(to: &configuration.reviewRequested)
        feedbackRule.apply(to: &configuration.authorFeedback)
        for trigger in MergeWorkflowTrigger.allCases {
            if let mode = eventModes[trigger.rawValue] { configuration.workflowRules[trigger].mode = mode }
        }
        configuration.workflowRules[.pipelineFailure].retryInfrastructureFailure = infrastructureRetry
    }
}
