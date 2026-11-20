import SwiftUI
import MergeTetherRemote

/// Pending draft publication or approval in an MR’s details.
struct ConfirmationQueueRow<AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let state: MergeRequestAttentionMonitor.ConfirmationState?
    let onPublish: () async -> Void
    let onApprove: () async -> Void
    let onOpen: () -> Void
    var onManage: (() -> Void)? = nil
    var initiallyExpanded = false
    var showDraftPreview = true
    var showHeader = true
    var selection: Binding<DraftPublicationSelection>? = nil
    var onPublishSelected: (([GitLabDraftNote]) async -> Void)? = nil
    var requiresSelection = false
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    var onFinishCommentReview: (() async -> Void)? = nil
    let additionalActions: AdditionalActions

    @State private var showsComments = false
    @State private var localSelection = DraftPublicationSelection()
    @State private var pendingAction: MergeRequestAttentionMonitor.ConfirmationState?

    private var isBusy: Bool { pendingAction != nil || state?.isBusy == true }
    private var draftSelection: Binding<DraftPublicationSelection> { selection ?? $localSelection }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: 10) {
                        MergeRequestTitle(title: "!\(item.id.iid) · \(item.title)",
                                          isDraft: item.section == .draftMergeRequests)
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                            .mrRowAccessoryFrame()
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(.Menu.menuActionOpenInBrowser))

                RepositoryPathText(item.url.gitLabProjectPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !item.drafts.isEmpty {
                Text(item.isAuthored
                     ? .Menu.menuConfirmReplies(item.drafts.count)
                     : .Menu.menuConfirmComments(item.drafts.count))
                if showDraftPreview {
                    DisclosureGroup(isExpanded: $showsComments) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(item.drafts.enumerated()), id: \.offset) { _, draft in
                                draftPreview(draft)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(.Menu.menuConfirmShowComments)
                    }
                }
            } else if item.requiresCommentReview {
                Text(.CommentReview.commentReviewPending)
            } else if item.canApprove {
                if let threshold = item.metApprovalThreshold {
                    Text(.Menu.menuConfirmApprovalThreshold(String(localized: threshold.title)))
                } else {
                    Text(.Menu.menuConfirmApproveReady)
                }
                ForEach(Array(item.remainingApprovalFindings.enumerated()), id: \.offset) { _, finding in
                    if let title = finding.level.title {
                        if let id = finding.noteID,
                           let url = URL(string: "#note_\(id)", relativeTo: item.url) {
                            Link(destination: url) { Text(title) }
                        } else {
                            Text(title)
                        }
                        if let summary = finding.summary {
                            Text(verbatim: summary).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let rejected = PreparedReplyContext.rejected(in: item)
            ForEach(rejected, id: \.draftID) { reply in
                PreparedReplyWarning(reply: reply).id("prepared-reply-\(reply.draftID)")
            }
            let duplicates = item.duplicateDraftIDs.count
            if duplicates > 0 {
                Label {
                    Text(duplicates == 1 ? .MRHumanAction.mrHumanActionDuplicateDraftSingle
                        : .MRHumanAction.mrHumanActionDuplicateDrafts(duplicates))
                } icon: { Image(systemName: "doc.on.doc") }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("duplicate-reply-drafts")
            }
            if item.awaitingRemoteVerification && rejected.isEmpty {
                Text(.PreparedReplies.preparedRepliesChecksPending)
                    .foregroundStyle(.orange)
            }
            if item.requiresDiscussionRecheck && rejected.isEmpty {
                Text(.PreparedReplies.preparedRepliesDiscussionCheck)
                    .foregroundStyle(.orange)
            }
            statusLine
            DraftPublicationWarnings(drafts: requiresSelection
                ? draftSelection.wrappedValue.selectedDrafts(from: item.drafts) : item.drafts)

            HStack(spacing: 8) {
                if pendingAction == .publishing || (pendingAction == nil && !item.drafts.isEmpty) {
                    let selected = draftSelection.wrappedValue.selectedDrafts(from: item.drafts)
                    if requiresSelection {
                        Button {
                            guard let onPublishSelected else { return }
                            run(.publishing) { await onPublishSelected(selected) }
                        } label: {
                            MRActionProgressLabel(working: pendingAction == .publishing) {
                                // Only publishing every draft lets the paused workflow continue.
                                if selected.count == item.drafts.count {
                                    MRActionLabel(title: .CommentReview.commentReviewPublishSelected(selected.count), cta: .publishComments)
                                } else {
                                    Text(.DraftPublication.draftPublicationPublishSelected(selected.count))
                                }
                            }
                        }
                        .mrActionHelp(.publishComments, detail: .CommentReview.commentReviewPublishSelectedHelp)
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || onPublishSelected == nil)
                    } else {
                        Button { run(.publishing, operation: onPublish) } label: {
                            MRActionLabel(title: .CommentReview.commentReviewPublishAll, cta: .publishComments, working: pendingAction == .publishing)
                        }
                            .mrActionHelp(.publishComments, detail: .Menu.menuConfirmPublishHelp)
                            .buttonStyle(.borderedProminent)
                    }
                } else if pendingAction == .finishingCommentReview || (pendingAction == nil && item.requiresCommentReview), let onFinishCommentReview {
                    Button { run(.finishingCommentReview, operation: onFinishCommentReview) } label: {
                        MRActionLabel(title: .CommentReview.commentReviewFinish, cta: .finishCommentReview,
                            working: pendingAction == .finishingCommentReview)
                    }
                        .buttonStyle(.borderedProminent)
                        .mrActionHelp(.finishCommentReview)
                        .disabled(!item.canFinishCommentReview)
                } else if pendingAction == .approving || (pendingAction == nil && item.canApprove) {
                    Button { run(.approving, operation: onApprove) } label: {
                        MRActionProgressLabel(working: pendingAction == .approving) { Text(.Menu.menuConfirmApprove) }
                    }
                        .buttonStyle(.borderedProminent)
                        .mrActionHelp(.approve)
                }
                Button(action: onOpen) { Text(.Menu.menuConfirmEdit) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(isBusy)
            additionalActions
            if let onManage {
                Button(action: onManage) { Label { Text(.Menu.menuScopeAddManaged) } icon: { Image(systemName: "bolt.badge.plus") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .mrRowContentPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5))
        .onAppear { if initiallyExpanded { showsComments = true } }
        .onChange(of: item.drafts) { _, drafts in draftSelection.wrappedValue.reconcile(with: drafts) }
        .onChange(of: item.id) { _, _ in draftSelection.wrappedValue = DraftPublicationSelection() }
        .environment(\.gitLabPersonSourceURL, item.url)
    }

    private func run(_ action: MergeRequestAttentionMonitor.ConfirmationState, operation: @escaping () async -> Void) {
        guard !isBusy else { return }
        pendingAction = action
        Task { defer { pendingAction = nil }; await operation() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .deleting:
            Text(.CommentReview.commentReviewDeleting).foregroundStyle(.secondary)
        case .failed:
            Text(.Menu.menuConfirmFailed).foregroundStyle(.orange)
        case .changed:
            Text(.Menu.menuConfirmChanged).foregroundStyle(.orange)
        case .publishing, .approving, .finishingCommentReview, nil:
            EmptyView()
        }
    }

    private func draftPreview(_ draft: GitLabDraftNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if requiresSelection && onPublishSelected != nil {
                DraftPublicationCheckbox(draft: draft, selection: draftSelection, disabled: isBusy)
            }
            draftContent(draft)
            if let onDelete { DraftDeleteButton(draft: draft, disabled: isBusy, onDelete: onDelete) }
        }
    }

    private func draftContent(_ draft: GitLabDraftNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let threadID = draft.discussionID {
                Group {
                    if let message = RemotePeopleMessage(.Board.boardReplyTo, people: item.replyRecipients[threadID] ?? []) {
                        PeopleMessageLabel(message: message)
                    } else { Text(.Menu.menuConfirmReply) }
                }.font(.caption2)
            }
            switch draft.kind {
            case .line(let location):
                Text(verbatim: location).font(.caption2.monospaced())
            case .reply:
                EmptyView()
            case .general:
                Text(.Menu.menuConfirmGeneral).font(.caption2)
            }
            Group {
                let note = draft.note ?? ""
                if let rendered = SafeInlineMarkdown.render(note) { Text(rendered) } else { Text(verbatim: note) }
            }
                .lineLimit(5)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
        }
    }
}

struct PreparedReplyWarning: View {
    let reply: PreparedReplyContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(.PreparedReplies.preparedRepliesLabel(reply.draftID)) } icon: {
                Image(systemName: "text.bubble")
            }
            .font(.subheadline.weight(.medium))
            if let summary = AgentExplanation.summary(reply.summary) {
                Text(verbatim: summary).foregroundStyle(.orange)
            }
            Text(verbatim: reply.quote)
                .font(.callout).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let url = reply.discussionURL {
                Link(destination: url) { Text(.PreparedReplies.preparedRepliesViewDiscussion) }
            }
            AgentDiagnosticDetails(reason: reply.reason)
        }
        .padding(.vertical, 6)
    }
}
