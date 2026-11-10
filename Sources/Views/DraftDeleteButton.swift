import SwiftUI

struct DraftDeleteButton: View {
    let draft: GitLabDraftNote
    let disabled: Bool
    let onDelete: (GitLabDraftNote) -> Void
    @State private var pending: GitLabDraftNote?

    var body: some View {
        Button { pending = draft } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(disabled || (draft.id ?? 0) <= 0)
        .help(Text(.CommentReview.commentReviewDelete))
        .accessibilityLabel(Text(.CommentReview.commentReviewDelete))
        .accessibilityIdentifier("delete-draft-\(draft.id ?? 0)")
        .confirmationDialog(Text(.CommentReview.commentReviewDeleteTitle), isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            Button(role: .destructive) {
                guard let expected = pending else { return }
                pending = nil
                onDelete(expected)
            } label: { Text(.CommentReview.commentReviewDelete) }
            Button(role: .cancel) { pending = nil } label: { Text(.Menu.menuScopeCancel) }
        } message: { Text(.CommentReview.commentReviewDeleteHelp) }
    }
}
