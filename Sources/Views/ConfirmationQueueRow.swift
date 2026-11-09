import SwiftUI

/// Pending draft publication or approval in an MR’s details.
struct ConfirmationQueueRow<AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let state: MergeRequestAttentionMonitor.ConfirmationState?
    let onPublish: () -> Void
    let onApprove: () -> Void
    let onOpen: () -> Void
    var onManage: (() -> Void)? = nil
    var initiallyExpanded = false
    var showDraftPreview = true
    var showHeader = true
    var selection: Binding<DraftPublicationSelection>? = nil
    var onPublishSelected: (([GitLabDraftNote]) -> Void)? = nil
    var requiresSelection = false
    let additionalActions: AdditionalActions

    @State private var showsComments = false
    @State private var localSelection = DraftPublicationSelection()

    private var isBusy: Bool { state == .publishing || state == .approving }
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
            } else if item.canApprove {
                Text(.Menu.menuConfirmApproveReady)
            }

            let rejected = PreparedReplyContext.rejected(in: item)
            ForEach(rejected, id: \.draftID) { reply in
                PreparedReplyWarning(reply: reply).id("prepared-reply-\(reply.draftID)")
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

            HStack(spacing: 8) {
                if !item.drafts.isEmpty {
                    let selected = draftSelection.wrappedValue.selectedDrafts(from: item.drafts)
                    if requiresSelection {
                        Button { onPublishSelected?(selected) } label: {
                            Text(.DraftPublication.draftPublicationPublishSelected(selected.count))
                        }
                        .help(Text(.DraftPublication.draftPublicationPublishSelectedHelp))
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || onPublishSelected == nil)
                    } else {
                        Button(action: onPublish) { Text(.Menu.menuConfirmPublish) }
                            .help(Text(.Menu.menuConfirmPublishHelp))
                            .buttonStyle(.borderedProminent)
                    }
                } else if item.canApprove {
                    Button(action: onApprove) { Text(.Menu.menuConfirmApprove) }
                        .buttonStyle(.borderedProminent)
                }
                Button(action: onOpen) { Text(.Menu.menuConfirmEdit) }
                    .buttonStyle(.bordered)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
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
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .publishing:
            Text(.Menu.menuConfirmPublishing).foregroundStyle(.secondary)
        case .approving:
            Text(.Menu.menuConfirmApproving).foregroundStyle(.secondary)
        case .failed:
            Text(.Menu.menuConfirmFailed).foregroundStyle(.orange)
        case .changed:
            Text(.Menu.menuConfirmChanged).foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private func draftPreview(_ draft: GitLabDraftNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if requiresSelection && onPublishSelected != nil {
                DraftPublicationCheckbox(draft: draft, selection: draftSelection, disabled: isBusy)
            }
            draftContent(draft)
        }
    }

    private func draftContent(_ draft: GitLabDraftNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let threadID = draft.discussionID {
                if let recipients = item.replyRecipients[threadID] {
                    Text(.Menu.menuConfirmReplyTo(recipients)).font(.caption2)
                } else {
                    Text(.Menu.menuConfirmReply).font(.caption2)
                }
            }
            switch draft.kind {
            case .line(let location):
                Text(verbatim: location).font(.caption2.monospaced())
            case .reply:
                EmptyView()
            case .general:
                Text(.Menu.menuConfirmGeneral).font(.caption2)
            }
            Text(verbatim: draft.note ?? "")
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
