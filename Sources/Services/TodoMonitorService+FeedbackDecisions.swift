import Foundation

enum FeedbackSuggestionDecisionError: Error, Equatable {
    case invalidTarget, accountChanged, sourceChanged, invalidConcern, unavailable
}

struct FeedbackSuggestionDecisionConfirmation {
    let request: GitLabMergeRequest
    let discussionFingerprint: String

    func matches(_ current: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion]) -> Bool {
        request.sha?.isEmpty == false
            && MergeRequestDependencySummary.Context(current) == MergeRequestDependencySummary.Context(request)
            && current.semanticContextFingerprint == request.semanticContextFingerprint
            && current.author.id == request.author.id && current.author.username == request.author.username
            && current.draft == request.draft
            && ReviewVerdict.fingerprint(discussions) == discussionFingerprint
    }
}

extension TodoMonitorService {
    func ignoreFeedbackSuggestion(_ note: GitLabMergeRequestDiscussion.Note, concernSummary: String,
                                  concernReason: String, for target: MRAutomationScope.Target) async throws {
        try await recordIgnoredFeedbackSuggestion(note.id, confirmedNote: note, concernSummary: concernSummary,
            concernReason: concernReason, for: target)
    }

    func ignoreFeedbackSuggestion(noteID: Int, concernSummary: String, concernReason: String,
                                  for target: MRAutomationScope.Target,
                                  confirmation: FeedbackSuggestionDecisionConfirmation) async throws {
        try await recordIgnoredFeedbackSuggestion(noteID, confirmation: confirmation, concernSummary: concernSummary,
            concernReason: concernReason, for: target)
    }

    private func recordIgnoredFeedbackSuggestion(_ noteID: Int?, confirmedNote: GitLabMergeRequestDiscussion.Note? = nil,
                                                 confirmation: FeedbackSuggestionDecisionConfirmation? = nil,
                                                 concernSummary: String, concernReason: String,
                                                 for target: MRAutomationScope.Target) async throws {
        try validateFeedbackDecisionTarget(target)
        guard !concernSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !concernReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeedbackSuggestionDecisionError.invalidConcern
        }
        let (user, discussions, revision) = try await readFeedbackDecisionEvidence(for: target, confirmation: confirmation)
        let sources = discussions.flatMap(\.notes).filter { $0.id == noteID }
        guard noteID != nil, sources.count == 1, let source = sources.first,
              source.system == false, source.author?.id != user.id,
              IgnoredFeedbackSuggestion.revision(of: source) != nil else {
            throw FeedbackSuggestionDecisionError.sourceChanged
        }
        if let confirmedNote, source.author?.id != confirmedNote.author?.id || source.body != confirmedNote.body {
            throw FeedbackSuggestionDecisionError.sourceChanged
        }
        let previous = settings.feedbackSuggestionDecisions.revision(for: target)
        guard let decision = settings.feedbackSuggestionDecisions.ignore(source, concernSummary: concernSummary,
            concernReason: concernReason, for: target) else { throw FeedbackSuggestionDecisionError.invalidConcern }
        guard settings.feedbackSuggestionDecisions.revision(for: target) != previous else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.ignoredEvent(decision.sourceNoteID, decision.concernSummary)))
        await refreshFeedbackDecisions(for: target, revision: revision)
    }

    func restoreFeedbackSuggestion(_ id: UUID, for target: MRAutomationScope.Target,
                                   confirmation: FeedbackSuggestionDecisionConfirmation? = nil) async throws {
        try validateFeedbackDecisionTarget(target)
        let revision: UInt64
        if let confirmation {
            revision = try await readFeedbackDecisionEvidence(for: target, confirmation: confirmation).revision
        } else {
            revision = glab.accountRevision
        }
        guard let decision = settings.feedbackSuggestionDecisions.entries(for: target).first(where: { $0.id == id }),
              settings.feedbackSuggestionDecisions.remove(id, for: target) else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.restoredEvent(decision.sourceNoteID, decision.concernSummary)))
        await refreshFeedbackDecisions(for: target, revision: revision)
    }

    func resetFeedbackSuggestionDecisions(for target: MRAutomationScope.Target) async throws {
        try validateFeedbackDecisionTarget(target)
        let revision = glab.accountRevision
        let count = settings.feedbackSuggestionDecisions.reset(for: target)
        guard count > 0 else { return }
        settings.recordAutomationEvent(target: target, action: .feedbackDecision, origin: .manual, state: .completed,
            message: String(localized: .FeedbackDecisionActions.resetEvent(count)))
        await refreshFeedbackDecisions(for: target, revision: revision)
    }

    private func validateFeedbackDecisionTarget(_ target: MRAutomationScope.Target) throws {
        guard target.projectID > 0, (target.iid ?? 0) > 0, !target.host.isEmpty, !target.username.isEmpty else {
            throw FeedbackSuggestionDecisionError.invalidTarget
        }
        guard glab.resolvedHost == target.host, glab.currentUsername == target.username else {
            throw FeedbackSuggestionDecisionError.accountChanged
        }
    }

    private func readFeedbackDecisionEvidence(for target: MRAutomationScope.Target,
                                              confirmation: FeedbackSuggestionDecisionConfirmation?) async throws
        -> (user: GitLabAuthenticatedUser, discussions: [GitLabMergeRequestDiscussion], revision: UInt64) {
        guard let iid = target.iid, let executable = glab.glabPath else { throw FeedbackSuggestionDecisionError.unavailable }
        let revision = glab.accountRevision
        let user = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        let discussions = try await glab.fetchMergeRequestDiscussions(projectID: target.projectID, iid: iid, host: target.host)
        let request = try await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: target.host)
        guard !Task.isCancelled, glab.accountRevision == revision, glab.glabPath == executable,
              glab.resolvedHost == target.host, glab.currentUsername == target.username else {
            throw FeedbackSuggestionDecisionError.accountChanged
        }
        guard request.projectID == target.projectID, request.iid == iid, request.isOpen,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid) else {
            throw FeedbackSuggestionDecisionError.invalidTarget
        }
        if let confirmation, !confirmation.matches(request, discussions: discussions) {
            throw FeedbackSuggestionDecisionError.sourceChanged
        }
        return (user, discussions, revision)
    }
}
