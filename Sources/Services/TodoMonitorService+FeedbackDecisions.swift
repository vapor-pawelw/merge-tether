import Foundation

enum FeedbackSuggestionDecisionError: Error, Equatable {
    case invalidTarget, accountChanged, sourceChanged, invalidConcern, unavailable
}

extension TodoMonitorService {
    func ignoreFeedbackSuggestion(_ note: GitLabMergeRequestDiscussion.Note, concernSummary: String,
                                  concernReason: String, for target: MRAutomationScope.Target) async throws {
        try validateFeedbackDecisionTarget(target)
        guard !concernSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !concernReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeedbackSuggestionDecisionError.invalidConcern
        }
        guard let iid = target.iid, let executable = glab.glabPath else { throw FeedbackSuggestionDecisionError.unavailable }
        let revision = glab.accountRevision
        let user = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        let request = try await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
        let discussions = try await glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host)
        guard glab.accountRevision == revision, glab.glabPath == executable,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else {
            throw FeedbackSuggestionDecisionError.accountChanged
        }
        guard request.projectID == target.projectID, request.iid == iid, request.state == "opened",
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid) else {
            throw FeedbackSuggestionDecisionError.invalidTarget
        }
        let sources = discussions.flatMap(\.notes).filter { $0.id == note.id }
        guard note.id != nil, sources.count == 1, let source = sources.first,
              source.system == false, source.author?.id != user.id,
              source.author?.id == note.author?.id, source.body == note.body,
              IgnoredFeedbackSuggestion.revision(of: source) != nil else {
            throw FeedbackSuggestionDecisionError.sourceChanged
        }
        let previous = settings.feedbackSuggestionDecisions.revision(for: target)
        guard let decision = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: concernSummary,
            concernReason: concernReason, for: target) else { throw FeedbackSuggestionDecisionError.invalidConcern }
        guard settings.feedbackSuggestionDecisions.revision(for: target) != previous else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.ignoredEvent(decision.sourceNoteID, decision.concernSummary)))
        await refreshFeedbackDecisions(for: target)
    }

    func restoreFeedbackSuggestion(_ id: UUID, for target: MRAutomationScope.Target) async throws {
        try validateFeedbackDecisionTarget(target)
        guard let decision = settings.feedbackSuggestionDecisions.entries(for: target).first(where: { $0.id == id }),
              settings.feedbackSuggestionDecisions.remove(id, for: target) else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.restoredEvent(decision.sourceNoteID, decision.concernSummary)))
        await refreshFeedbackDecisions(for: target)
    }

    func resetFeedbackSuggestionDecisions(for target: MRAutomationScope.Target) async throws {
        try validateFeedbackDecisionTarget(target)
        let count = settings.feedbackSuggestionDecisions.reset(for: target)
        guard count > 0 else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.resetEvent(count)))
        await refreshFeedbackDecisions(for: target)
    }

    private func validateFeedbackDecisionTarget(_ target: MRAutomationScope.Target) throws {
        guard target.projectID > 0, (target.iid ?? 0) > 0, !target.host.isEmpty, !target.username.isEmpty else {
            throw FeedbackSuggestionDecisionError.invalidTarget
        }
        guard glab.resolvedHost == target.host, glab.currentUsername == target.username else {
            throw FeedbackSuggestionDecisionError.accountChanged
        }
    }

    private func refreshFeedbackDecisions(for target: MRAutomationScope.Target) async {
        guard let iid = target.iid else { return }
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: target.projectID, iid: iid)
        attention.retryAuthorFeedback(id)
        await refreshFromGitLab(for: id)
    }
}
