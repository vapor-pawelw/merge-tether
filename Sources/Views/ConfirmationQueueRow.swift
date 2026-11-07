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
    let additionalActions: AdditionalActions

    @State private var showsComments = false

    private var isBusy: Bool { state == .publishing || state == .approving }

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

            if item.awaitingRemoteVerification {
                Text(.Menu.menuConfirmRemoteVerificationRequired)
                    .foregroundStyle(.orange)
            }
            if item.requiresDiscussionRecheck {
                Text(.Menu.menuConfirmDiscussionRecheckRequired)
                    .foregroundStyle(.orange)
            }
            statusLine

            HStack(spacing: 8) {
                if !item.drafts.isEmpty {
                    Button(action: onPublish) { Text(.Menu.menuConfirmPublish) }
                        .help(Text(.Menu.menuConfirmPublishHelp))
                        .buttonStyle(.borderedProminent)
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
