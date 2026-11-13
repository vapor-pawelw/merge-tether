import Foundation

extension SettingsManager {
    struct CommentReviewProgress: Codable, Equatable {
        var observedDraftIDs: Set<Int> = []
        var automaticallyPublishedDraftIDs: Set<Int> = []
    }

    func commentReviewRevision(for target: MRAutomationScope.Target) -> UInt64 {
        commentReviewRevisions[target, default: 0]
    }

    func observeCommentReview(_ drafts: [GitLabDraftNote], for target: MRAutomationScope.Target, revision: UInt64) {
        guard !drafts.isEmpty, target.iid != nil, commentReviewRevision(for: target) == revision else { return }
        let inserted = pendingCommentReviews.insert(target).inserted
        let previous = commentReviewProgress[target]
        var progress = previous ?? .init()
        progress.observedDraftIDs.formUnion(drafts.compactMap(\.id))
        commentReviewProgress[target] = progress
        if inserted || progress != previous { save() }
    }

    func recordAutomaticCommentPublication(_ drafts: [GitLabDraftNote], for target: MRAutomationScope.Target) {
        guard pendingCommentReviews.contains(target) else { return }
        let previous = commentReviewProgress[target]
        var progress = previous ?? .init()
        progress.automaticallyPublishedDraftIDs.formUnion(drafts.compactMap(\.id))
        commentReviewProgress[target] = progress
        if progress != previous { save() }
    }

    func canAutomaticallyFinishCommentReview(for target: MRAutomationScope.Target) -> Bool {
        guard pendingCommentReviews.contains(target), let progress = commentReviewProgress[target],
              !progress.observedDraftIDs.isEmpty else { return false }
        return progress.observedDraftIDs.isSubset(of: progress.automaticallyPublishedDraftIDs)
    }

    func beginCommentReview(for target: MRAutomationScope.Target) {
        guard target.iid != nil, pendingCommentReviews.insert(target).inserted else { return }
        save()
    }

    func completeCommentReview(for target: MRAutomationScope.Target) {
        guard pendingCommentReviews.remove(target) != nil else { return }
        commentReviewProgress.removeValue(forKey: target)
        commentReviewRevisions[target, default: 0] &+= 1
        save()
    }

    /// The user's two-state MR preference only; callers must still check global permission,
    /// whole-MR scope and current action evidence before performing an automatic write.
    func actionIsAutomatic(_ action: MRAutomaticAction, for target: MRAutomationScope.Target) -> Bool {
        switch action {
        case .commentPublication: !autoPublishOptOuts.contains(target)
        case .merge: !autoMergeOptOuts.contains(target)
        case .approval: !autoApproveOptOuts.contains(target)
        }
    }

    func setActionAutomatic(_ action: MRAutomaticAction, enabled: Bool, for target: MRAutomationScope.Target) {
        guard target.iid != nil else { return }
        switch action {
        case .commentPublication:
            if enabled { autoPublishOptOuts.remove(target) } else { autoPublishOptOuts.insert(target) }
        case .merge:
            if enabled { autoMergeOptOuts.remove(target) } else { autoMergeOptOuts.insert(target) }
        case .approval:
            if enabled { autoApproveOptOuts.remove(target) } else { autoApproveOptOuts.insert(target) }
        }
    }

    /// Policy admission only. Action executors retain their current fresh evidence checks.
    /// Presentation passes `ignoringGlobalSuspension` so the killswitch does not change how MRs look.
    func permitsAutomaticAction(_ action: MRAutomaticAction, for request: GitLabMergeRequest,
                                target: MRAutomationScope.Target, ignoringGlobalSuspension: Bool = false) -> Bool {
        let automation = ignoringGlobalSuspension ? configuredAutomation : automation
        guard automaticActionsAllowed, automation.hasAutomaticPublicActionConsent else { return false }
        if action != .commentPublication, pendingCommentReviews.contains(target) { return false }
        guard request.projectID == target.projectID, request.iid == target.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid),
              actionIsAutomatic(action, for: target),
              automation.scope.permits(request, host: target.host, username: target.username) else { return false }
        return switch action {
        case .commentPublication: automation.publicationMode != .manual
        case .merge: automation.permitsAutoMerge(project: request.webURL.gitLabProjectPath)
        case .approval: automation.autoApproveEnabled
        }
    }
}
