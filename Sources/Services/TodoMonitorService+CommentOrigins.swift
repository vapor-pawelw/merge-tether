import Foundation

extension TodoMonitorService {
    func makeCommentOriginCenter() -> CommentOriginOverrideCenter {
        CommentOriginOverrideCenter(directory: attention.aiAssessmentDirectory, gain: { [weak self] target, discussions, noteIDs in
            guard let self, let iid = target.iid, self.isCurrentAccount(target) else { return 0 }
            return await self.attention.automaticPublicationGain(for: .init(projectID: target.projectID, iid: iid),
                discussions: discussions, becomingAI: noteIDs)
        }, resume: { [weak self] target in
            guard let self, let iid = target.iid, self.isCurrentAccount(target) else { return }
            await self.refreshFromGitLab(for: .init(projectID: target.projectID, iid: iid))
        }, onRevision: { [weak self] in self?.attention.invalidateCommentOriginPublication() })
    }

    /// Records the user's verdict on comments of one MR. `nil` returns them to automatic assessment.
    @discardableResult
    func setCommentOrigin(_ classification: AICommentOriginOverride.Classification?,
                          notes: [GitLabMergeRequestDiscussion.Note], in discussions: [GitLabMergeRequestDiscussion],
                          for target: MRAutomationScope.Target) async throws -> CommentOriginOverrideCenter.Change {
        guard isCurrentAccount(target) else { throw CommentOriginOverrideCenter.ChangeError.invalidTarget }
        let revision = glab.accountRevision
        for authorID in Set(notes.compactMap { $0.author?.id }) where authorID > 0 {
            if settings.reviewParticipationPreferences.isDeclaredAutomation(
                host: target.host, username: target.username, userID: authorID) {
                throw CommentOriginOverrideCenter.ChangeError.automatedAuthor
            }
            let kind = try await glab.feedbackAccountKind(userID: authorID, host: target.host)
            guard isCurrentAccount(target), glab.accountRevision == revision else {
                throw CommentOriginOverrideCenter.ChangeError.invalidTarget
            }
            guard kind != .automation,
                  !settings.reviewParticipationPreferences.isDeclaredAutomation(
                    host: target.host, username: target.username, userID: authorID) else {
                throw CommentOriginOverrideCenter.ChangeError.automatedAuthor
            }
        }
        let account = try await glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
        guard isCurrentAccount(target), glab.accountRevision == revision else {
            throw CommentOriginOverrideCenter.ChangeError.invalidTarget
        }
        return try await commentOrigins.apply(classification, to: notes, in: discussions, target: target, userID: account.id,
            legacyUsernames: settings.unambiguousLegacyUsernames(for: account.account(on: target.host))) { [weak self] selected in
            guard let self, self.isCurrentAccount(target), self.glab.accountRevision == revision else { return false }
            guard classification.map({ self.settings.recordAIReplyTrust($0, notes: selected, host: target.host, user: account) }) ?? true
            else { return false }
            return true
        }
    }

    private func isCurrentAccount(_ target: MRAutomationScope.Target) -> Bool {
        glab.resolvedHost == target.host && glab.currentUsername == target.username
    }
}
