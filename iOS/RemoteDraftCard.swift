import SwiftUI
import MergeTetherRemote

struct RemoteDraftCard: View {
    let draft: RemoteDraft
    let deleteAction: RemoteAction?
    var publishAction: RemoteAction? = nil
    var extraContext: String? = nil
    let canAct: Bool
    let onAction: (RemoteAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(.RemoteDetail.remoteDetailDraft, systemImage: "square.and.pencil")
                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                if let deleteAction {
                    Button { onAction(deleteAction) } label: {
                        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(Text(.CommentReview.commentReviewDelete))
                    .disabled(!canAct)
                    .accessibilityIdentifier("remote.delete-draft.\(draft.id)")
                }
            }
            if let context = draft.context, !context.isEmpty {
                DisclosureGroup {
                    Text(verbatim: context).font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Label {
                        Text(verbatim: context.split(separator: "/").last.map(String.init) ?? context)
                            .lineLimit(1).truncationMode(.middle)
                    } icon: { Image(systemName: "text.alignleft") }
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(.RemoteDetail.remoteDetailContext) + Text(verbatim: ": " + context))
                }
                .tint(.secondary)
                .accessibilityIdentifier("remote.draft-context.\(draft.id)")
            }
            Text(verbatim: draft.body).font(.callout).lineSpacing(4)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let extraContext {
                RemoteExtraContextButton(markdown: extraContext)
                    .accessibilityIdentifier("remote.draft-extra-context.\(draft.id)")
            }
            ForEach(Array((draft.publicationWarnings ?? []).enumerated()), id: \.offset) { _, warning in
                Label { Text(verbatim: warning).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Drafts with quick actions or thread resolution get no button: the Mac shows their effects.
            if let publishAction {
                Button { onAction(publishAction) } label: {
                    Label(.Remote.remotePublishDraft, systemImage: "paperplane").frame(minHeight: 44)
                }
                .buttonStyle(.bordered).disabled(!canAct)
                .accessibilityIdentifier("remote.publish-draft.\(draft.id)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5) }
        .accessibilityIdentifier("remote.draft.\(draft.id)")
    }
}
