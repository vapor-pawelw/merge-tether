import Foundation

/// What a merge request call to action does when it is clicked.
///
/// AI work and deterministic actions must stay distinguishable without longer
/// labels: the icon comes from this effect and the hover text says exactly what
/// runs now and what may follow.
enum MRActionEffect: Equatable, Sendable {
    /// Starts an agent run that can change code, push or prepare drafts.
    case agent
    /// Runs a read-only AI check with the selected CLI.
    case aiCheck
    /// Performs a deterministic GitLab change.
    case gitLab
    /// Submits a GitLab merge and may first run a read-only AI check.
    case gitLabWithAICheck
    /// Changes only MergeTether state or reloads data.
    case local

    /// Sparkles are reserved for AI work everywhere, including Settings.
    var symbol: String? {
        switch self {
        case .agent: "sparkles"
        case .aiCheck: "sparkle.magnifyingglass"
        case .gitLab, .gitLabWithAICheck, .local: nil
        }
    }

    var kindDescription: LocalizedStringResource {
        switch self {
        case .agent: .ActionEffects.kindAgent
        case .aiCheck: .ActionEffects.kindAICheck
        case .gitLab: .ActionEffects.kindGitLab
        case .gitLabWithAICheck: .ActionEffects.kindMerge
        case .local: .ActionEffects.kindLocal
        }
    }
}

extension AssistantAutomationRunner.Handoff {
    var retryConfirmationVariant: String {
        switch taskIntent {
        case .review(let fromScratch, _): fromScratch ? "reviewFromScratch" : "review"
        case .pipelineDiagnosis: "pipeline"
        case .conflictResolution: "conflict"
        case nil: workflow?.rawValue ?? id.uuidString
        }
    }
}

/// Work that may follow an action immediately, under the current Settings.
enum MRActionFollowUp: Equatable, Sendable {
    /// A check that finds remaining feedback may start a fix agent.
    case mayStartAgent
    /// A clear check may ask the reviewers for another review.
    case mayRequestReReview
    /// The paused workflow continues under the automation rules in Settings.
    case resumesAutomation
    /// The refresh runs whatever automation Settings already allow.
    case runsAllowedAutomation
}

/// One description per merge request call to action. Labels stay at their call
/// sites; the icon and hover text always come from here so they cannot diverge.
enum MRActionCTA: String, CaseIterable, Sendable {
    case runReview, retryRun, handleFeedback, diagnosePipeline, resolveConflicts, confirmPipelineHandoff
    case addAndHandle
    case verifyFeedback, verifyReReview, retryDraftVerification, resolveThreads
    case publishComments, approve, merge, markReady, requestReReview
    case finishCommentReview, refreshFromGitLab, ignoreSuggestion

    func confirmationID(variant: String? = nil) -> String {
        [rawValue, variant].compactMap { $0 }.joined(separator: ".")
    }

    /// The call to action that runs a classified to-do intent.
    init?(intent: MRTodoIntent.Kind) {
        switch intent {
        case .review: self = .runReview
        case .followUp: self = .handleFeedback
        case .pipeline: self = .diagnosePipeline
        case .conflict: self = .resolveConflicts
        case .refresh: return nil
        }
    }

    var effect: MRActionEffect {
        switch self {
        case .runReview, .retryRun, .handleFeedback, .diagnosePipeline, .resolveConflicts,
             .confirmPipelineHandoff, .addAndHandle: .agent
        case .verifyFeedback, .verifyReReview, .retryDraftVerification, .resolveThreads: .aiCheck
        case .publishComments, .approve, .markReady, .requestReReview: .gitLab
        case .merge: .gitLabWithAICheck
        case .finishCommentReview, .refreshFromGitLab, .ignoreSuggestion: .local
        }
    }

    var requiresCodingAssistant: Bool { effect == .agent || effect == .aiCheck }

    var followUps: [MRActionFollowUp] {
        switch self {
        case .verifyFeedback: [.mayStartAgent]
        case .verifyReReview: [.mayRequestReReview]
        case .addAndHandle, .publishComments, .markReady: [.resumesAutomation]
        case .finishCommentReview: [.mayRequestReReview, .resumesAutomation]
        case .refreshFromGitLab, .ignoreSuggestion: [.runsAllowedAutomation]
        default: []
        }
    }

    /// The effect icon. Sparkles are reserved for AI work, the bolt for resumed
    /// automation; deterministic actions keep their own icon (`nil`).
    var symbol: String? {
        effect.symbol ?? (followUps.contains(.resumesAutomation) ? "bolt" : nil)
    }

    var summary: LocalizedStringResource {
        switch self {
        case .runReview: .ActionEffects.runReview
        case .retryRun: .ActionEffects.retryRun
        case .handleFeedback: .ActionEffects.handleFeedback
        case .diagnosePipeline: .ActionEffects.diagnosePipeline
        case .resolveConflicts: .ActionEffects.resolveConflicts
        case .confirmPipelineHandoff: .ActionEffects.confirmPipelineHandoff
        case .addAndHandle: .ActionEffects.addAndHandle
        case .verifyFeedback: .ActionEffects.verifyFeedback
        case .verifyReReview: .ActionEffects.verifyReReview
        case .retryDraftVerification: .ActionEffects.retryDraftVerification
        case .resolveThreads: .ActionEffects.resolveThreads
        case .publishComments: .ActionEffects.publishComments
        case .approve: .ActionEffects.approve
        case .merge: .ActionEffects.merge
        case .markReady: .ActionEffects.markReady
        case .requestReReview: .ActionEffects.requestReReview
        case .finishCommentReview: .ActionEffects.finishCommentReview
        case .refreshFromGitLab: .ActionEffects.refreshFromGitLab
        case .ignoreSuggestion: .ActionEffects.ignoreSuggestion
        }
    }

    /// Hover text: the effect kind, what this action does, then what may follow.
    var help: String {
        ([effect.kindDescription, summary] + followUps.map(Self.followUpLine))
            .map { String(localized: $0) }
            .joined(separator: "\n")
    }

    private static func followUpLine(_ followUp: MRActionFollowUp) -> LocalizedStringResource {
        switch followUp {
        case .mayStartAgent: .ActionEffects.thenMayStartAgent
        case .mayRequestReReview: .ActionEffects.thenMayRequestReReview
        case .resumesAutomation: .ActionEffects.thenResumesAutomation
        case .runsAllowedAutomation: .ActionEffects.thenRunsAllowedAutomation
        }
    }
}
