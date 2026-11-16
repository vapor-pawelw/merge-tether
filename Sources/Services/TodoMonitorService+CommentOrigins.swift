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
        })
    }

    /// Records the user's verdict on comments of one MR. `nil` returns them to automatic assessment.
    @discardableResult
    func setCommentOrigin(_ classification: AICommentOriginOverride.Classification?,
                          notes: [GitLabMergeRequestDiscussion.Note], in discussions: [GitLabMergeRequestDiscussion],
                          for target: MRAutomationScope.Target) async throws -> CommentOriginOverrideCenter.Change {
        guard isCurrentAccount(target) else { throw CommentOriginOverrideCenter.ChangeError.invalidTarget }
        return try await commentOrigins.apply(classification, to: notes, in: discussions, target: target)
    }

    private func isCurrentAccount(_ target: MRAutomationScope.Target) -> Bool {
        glab.resolvedHost == target.host && glab.currentUsername == target.username
    }
}
