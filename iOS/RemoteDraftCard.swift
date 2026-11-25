import SwiftUI
import MergeTetherRemote

struct RemoteDraftCard: View {
    let draft: RemoteDraft
    let deleteAction: RemoteAction?
    var publishAction: RemoteAction? = nil
    var extraContext: String? = nil
    var proposedSolution = false
    var replyThread: RemoteDetailThread? = nil
    let canAct: Bool
    var runningActionID: String? = nil
    let onAction: (RemoteAction) -> Void
    var onRegenerate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(.RemoteDetail.remoteDetailDraft, systemImage: "square.and.pencil")
                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                if let onRegenerate {
                    Button(action: onRegenerate) {
                        CodingProviderIcon().frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationOneAction))
                    .disabled(!canAct)
                    .accessibilityIdentifier("draft-regeneration.draft.\(draft.id)")
                }
                if let deleteAction {
                    Button { onAction(deleteAction) } label: {
                        RemoteActionProgressLabel(running: runningActionID == deleteAction.id) {
                            Image(systemName: "trash")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(Text(runningActionID == deleteAction.id ? .Remote.remoteRunning : .CommentReview.commentReviewDelete))
                    .disabled(!canAct)
                    .accessibilityIdentifier("remote.delete-draft.\(draft.id)")
                }
            }
            if let recipients = draft.replyRecipients,
               let message = RemotePeopleMessage(.Board.boardReplyTo, people: recipients.map(PersonIdentity.init)) {
                // A reply's thread ID means nothing to people; name who it answers instead.
                Label {
                    PeopleMessageLabel(message: message)
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("remote.draft-recipients.\(draft.id)")
            } else if let context = draft.context, !context.isEmpty {
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
            if let replyThread, !replyThread.notes.isEmpty {
                RemoteDraftReplyContext(thread: replyThread)
                    .accessibilityIdentifier("remote.draft-reply-context.\(draft.id)")
            }
            RemoteMarkdownText(source: draft.body).font(.callout).lineSpacing(4)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let extraContext {
                RemoteExtraContextButton(markdown: extraContext, proposedSolution: proposedSolution)
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
                    RemoteActionProgressLabel(running: runningActionID == publishAction.id) {
                        Label(.Remote.remotePublishDraft, systemImage: "paperplane")
                    }
                    .frame(minHeight: 44)
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

private struct RemoteDraftReplyContext: View {
    let thread: RemoteDetailThread
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(.RemoteDetail.remoteDetailReplyingTo, systemImage: "quote.bubble")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let location = thread.location {
                Text(verbatim: location).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(expanded ? thread.notes : Array(thread.notes.prefix(1))) { note in
                VStack(alignment: .leading, spacing: 6) {
                    PersonLabel(person: .init(name: note.author, username: note.username, avatarURL: note.avatarURL),
                                avatarSize: 16, fallback: Text(.RemoteDetail.remoteDetailUnknownAuthor))
                        .font(.caption.weight(.medium))
                    RemoteMarkdownText(source: note.body).font(.callout).lineSpacing(3)
                        .lineLimit(expanded ? nil : 4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if thread.truncated {
                Text(.RemoteDetail.remoteDetailTruncated).font(.caption).foregroundStyle(.orange)
            }
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                Text(expanded ? .RemoteDetail.remoteDetailHideConversation : .RemoteDetail.remoteDetailShowConversation)
                    .font(.caption).frame(minHeight: 44)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
