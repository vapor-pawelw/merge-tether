import Foundation

enum MergeSubmissionAction: String, Codable, Sendable {
    case mergeNow, enqueue
    var title: LocalizedStringResource { self == .mergeNow ? .MergeActions.mergeActionsMergeNow : .MergeActions.mergeActionsEnqueue }
}

enum MergeSubmissionState: String, Codable, Sendable {
    case none, merged, queued, inTrain, uncertain, changed
    var isDelegated: Bool { self == .queued || self == .inTrain }
    var title: LocalizedStringResource? {
        switch self {
        case .none, .merged: nil
        case .queued: .MergeActions.mergeActionsQueued
        case .inTrain: .MergeActions.mergeActionsInTrain
        case .uncertain: .MergeActions.mergeActionsUncertain
        case .changed: .MergeActions.mergeActionsChanged
        }
    }
}

struct GitLabMergeActionPolicy: Equatable, Sendable {
    let action: MergeSubmissionAction?
    let requiresResolvedDiscussions: Bool?
    let resetsApprovalsOnPush: Bool?
    var usesMergeTrain = false
}

/// Saved before a potentially accepted request. A lost response must survive restart
/// as an uncertain attempt, rather than inviting another non-idempotent train write.
struct MergeSubmissionReceipt: Codable, Equatable {
    enum Origin: String, Codable { case appAttempt, observedQueue }
    var origin: Origin = .appAttempt
    let target: MRAutomationScope.Target
    let userID: Int
    let context: MergeRequestDependencySummary.Context
    let semanticFingerprint: String
    let discussionFingerprint: String
    let configuration: MergeSubmissionConfiguration
    let action: MergeSubmissionAction
    var state: MergeSubmissionState = .uncertain
    let createdAt: Date

    func matches(_ request: GitLabMergeRequest, discussionFingerprint: String, configuration: MergeSubmissionConfiguration) -> Bool {
        context == .init(request) && semanticFingerprint == request.semanticContextFingerprint
            && self.discussionFingerprint == discussionFingerprint && self.configuration == configuration
    }
}

extension GitLabMergeRequest {
    var hasQueuedMerge: Bool { mergeWhenPipelineSucceeds == true }
    func isReadyForMergeSubmission(_ action: MergeSubmissionAction) -> Bool {
        guard state == "opened", draft == false, hasConflicts == false, canMerge == true,
              let sha, GlabService.isFullGitSHA(sha) else { return false }
        if detailedMergeStatus == "mergeable", headPipeline == nil || headPipeline?.status == "success" { return true }
        return action == .enqueue && ["mergeable", "ci_still_running"].contains(detailedMergeStatus ?? "")
            && ["created", "pending", "running", "preparing", "waiting_for_resource"].contains(headPipeline?.status ?? "")
    }
}

struct MergeSubmissionConfiguration: Codable, Equatable, Sendable {
    let automation: AutomationSettings
    let automaticMergeOptOuts: Set<MRAutomationScope.Target>
    let feedbackDecisions: FeedbackSuggestionDecisions

    @MainActor init(_ settings: SettingsManager) {
        automation = settings.automation
        automaticMergeOptOuts = settings.autoMergeOptOuts
        feedbackDecisions = settings.feedbackSuggestionDecisions
    }
}
