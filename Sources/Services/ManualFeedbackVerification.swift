import Foundation

@MainActor enum MergeSubmissionFingerprint {
    static func configuration(_ settings: SettingsManager) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let automation = try encoder.encode(settings.automation)
        let decisions = try encoder.encode(settings.feedbackSuggestionDecisions)
        let optOuts = try settings.autoMergeOptOuts.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.sorted()
        return UserAttentionSnapshot.digest(String(decoding: automation, as: UTF8.self)
            + String(decoding: decisions, as: UTF8.self) + optOuts.joined(separator: "\n"))
    }
}

extension AutomationAssistant {
    var manualMergeVerificationDisclosure: LocalizedStringResource {
        .MergeActions.mergeActionsVerifyBeforeSubmit(String(localized: displayName))
    }
}

/// Explicit manual checks can run when background automation is off. They use the
/// same read-only verifier and never grant a coding job, push or publication.
@MainActor enum ManualFeedbackVerification {
    static func assess(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                       user: GitLabAuthenticatedUser, host: String, settings: SettingsManager,
                       glab: GlabService) async throws -> ReReviewAssessment {
        let discussions = GitLabMergeRequestDiscussion.activeForReview(discussions)
        guard discussions.flatMap(\.notes).contains(where: { $0.system != true && $0.author?.id != user.id }) else {
            return .init(notes: [])
        }
        let configuration = settings.automation
        guard let assistant = configuration.selectedAssistant else { throw ReReviewVerifier.VerificationError.unavailable }
        let diff: Data = try await glab.mergeRequestAPI(
            "/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        guard settings.automation == configuration, !Task.isCancelled else { throw CancellationError() }
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
        return try await ReReviewVerifier.verify(.init(authorID: user.id, headSHA: request.sha ?? "", title: request.title,
            description: request.description, diff: String(decoding: diff, as: UTF8.self), discussions: discussions,
            target: .init(host: host, projectID: request.projectID, iid: request.iid, url: request.webURL, expectedUsername: user.username),
            semanticContextFingerprint: request.semanticContextFingerprint, thinking: configuration.verificationThinking,
            ignoredSuggestions: settings.feedbackSuggestionDecisions.applicable(in: discussions, for: target),
            excludedReplyAuthorIDs: settings.reviewParticipationPreferences.excludedIDs(host: host, username: user.username).sorted(),
            usagePurpose: .manualFeedback, usageCorrelationID: UUID()),
            assistant: assistant, model: model)
    }
}
