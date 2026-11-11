import Foundation

extension MergeRequestAttentionMonitor.Item {
    /// Only the pending-draft updater opts into this comparison. This includes its
    /// mutations and updateItem's derived safety flags; other mutations always publish.
    func hasSamePendingDraftEvidence(as previous: Self) -> Bool {
        drafts == previous.drafts && draftCount == previous.draftCount
            && requiresCommentReview == previous.requiresCommentReview
            && commentReviewSnapshot == previous.commentReviewSnapshot
            && reviewingProgress == previous.reviewingProgress
            && reviewingActivity == previous.reviewingActivity
            && observedDiscussionFingerprint == previous.observedDiscussionFingerprint
            && requiresDiscussionRecheck == previous.requiresDiscussionRecheck
            && canApprove == previous.canApprove && autoApproveReady == previous.autoApproveReady
            && canConfirmReReview == previous.canConfirmReReview
            && awaitingRemoteVerification == previous.awaitingRemoteVerification
    }
}
