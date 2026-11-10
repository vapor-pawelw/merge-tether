import SwiftUI

struct CommentReviewImpactView: View {
    let item: MergeRequestAttentionMonitor.Item
    let reReviewEnabled: Bool

    var body: some View {
        if item.draftCount > 0 || item.requiresCommentReview {
            VStack(alignment: .leading, spacing: 6) {
                Label { Text(.CommentReview.commentReviewBlocks) } icon: { Image(systemName: "pause.circle") }
                    .fontWeight(.medium)
                if item.isAuthored {
                    if reReviewEnabled { Text(.CommentReview.commentReviewBeforeReReview) }
                    Text(.CommentReview.commentReviewBeforeMerge)
                } else {
                    Text(.CommentReview.commentReviewBeforeApproval)
                }
                Text(.CommentReview.commentReviewOtherChecks).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 6)
        }
    }
}
