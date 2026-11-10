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

/// A train can fail replaying an intermediate commit even when the final trees merge cleanly.
/// Keep that server evidence separate from GitLab's ordinary has_conflicts flag.
struct MergeTrainPreparationConflict: Error, Codable, Hashable, Sendable {
    let context: MergeRequestDependencySummary.Context
    let noteID: Int
    let sourceSHA: String
    let targetSHA: String

    var noteURL: URL {
        var components = URLComponents(url: context.url, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(noteID)"
        return components?.url ?? context.url
    }

    func matches(_ request: GitLabMergeRequest) -> Bool { context == .init(request) }

    static func latest(in discussions: [GitLabMergeRequestDiscussion], for request: GitLabMergeRequest) -> Self? {
        let removal = discussions.flatMap(\.notes).filter {
            $0.system == true && ($0.id ?? 0) > 0
                && $0.body?.hasPrefix("removed this merge request from the merge train") == true
        }.max { ($0.id ?? 0) < ($1.id ?? 0) }
        guard let note = removal, let id = note.id, let body = note.body else { return nil }
        let pattern = #"^removed this merge request from the merge train because the merge train pipeline could not be prepared: failed to rebase ([0-9a-f]{40}|[0-9a-f]{64}) on ([0-9a-f]{40}|[0-9a-f]{64}) while preparing refs/merge-requests/([0-9]+)/train due to conflict\.($| )"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let sourceRange = Range(match.range(at: 1), in: body),
              let targetRange = Range(match.range(at: 2), in: body),
              let iidRange = Range(match.range(at: 3), in: body),
              String(body[sourceRange]) == request.sha, Int(body[iidRange]) == request.iid else { return nil }
        return .init(context: .init(request), noteID: id, sourceSHA: String(body[sourceRange]), targetSHA: String(body[targetRange]))
    }
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
    var trainNoteIDBeforeAttempt: Int? = nil
    var confirmedTrainRejection: MergeTrainPreparationConflict? = nil

    func mayReconsiderAfterTrainRepair(_ request: GitLabMergeRequest) -> Bool {
        guard let proof = confirmedTrainRejection, proof.context == context,
              proof.sourceSHA == context.head, GlabService.isFullGitSHA(proof.targetSHA),
              let baseline = trainNoteIDBeforeAttempt, baseline >= 0, proof.noteID > baseline,
              let head = request.sha, GlabService.isFullGitSHA(head), head != context.head else { return false }
        return request.projectID == context.projectID && request.iid == context.iid && request.webURL == context.url
            && request.sourceProjectID == context.sourceProjectID && request.sourceBranch == context.source
            && request.targetProjectID == context.targetProjectID && request.targetBranch == context.target
            && request.state == "opened"
    }

    func matches(_ request: GitLabMergeRequest, discussionFingerprint: String, configuration: MergeSubmissionConfiguration) -> Bool {
        context == .init(request) && semanticFingerprint == request.semanticContextFingerprint
            && self.discussionFingerprint == discussionFingerprint && self.configuration == configuration
    }
}

extension GitLabMergeRequest {
    var hasQueuedMerge: Bool { mergeWhenPipelineSucceeds == true }
    func isReadyForMergeSubmission(_ action: MergeSubmissionAction) -> Bool {
        guard state == "opened", draft == false, hasConflicts == false, !hasMergeConflict,
              !mergeTrainEvidenceUnavailable, canMerge == true,
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
