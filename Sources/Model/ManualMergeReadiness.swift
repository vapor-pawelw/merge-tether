import Foundation

extension MergeRequestAttentionMonitor.Item {
    func canOfferManualMerge(using status: AuthoredMergeRequestStatus) -> Bool {
        guard let request = mergeRequest, let action = status.action else { return false }
        return isAuthored && status.mayMergeManually && status.submissionState == .none
            && MergeRequestDependencySummary.Context(request) == .init(status.request)
            && request.semanticContextFingerprint == status.request.semanticContextFingerprint
            && request.isReadyForMergeSubmission(action)
            && !requiresCommentReview && !requiresDiscussionRecheck && draftCount == 0 && drafts.isEmpty
            && !needsDiscussion && feedback.isEmpty && !needsChanges && !hasConflict
            && !failedPipeline && !needsPipelineHandoff && authorFeedbackStatus?.needsAttention != true
    }
}
