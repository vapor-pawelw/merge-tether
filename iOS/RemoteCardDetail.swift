import SwiftUI
import MergeTetherRemote

struct RemoteCardDetail: View {
    @Bindable var model: RemotePhoneModel
    let original: RemoteCard
    @State private var confirmation: RemoteAction?
    @State private var confirmationCard: RemoteCard?
    @State private var approvalID: UUID?
    @State private var confirmationAccount = ""
    @Environment(\.dismiss) private var dismiss
    private var current: RemoteCard { model.state.board?.cards.first { $0.id == original.id } ?? original }
    private var headerDestination: RemoteCardCTA.Destination {
        switch current.primaryCTA?.destination {
        case .feedback: .feedback
        case .assistantRuns: .assistantRuns
        default: .overview
        }
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        RemoteCardView(card: current, expanded: true).id(headerDestination)
                        if current.primaryCTA?.destination == .setup {
                            Text(.Remote.remoteSetupOnMac).foregroundStyle(.secondary).id(RemoteCardCTA.Destination.setup)
                        } else if current.actions.isEmpty, let destination = current.primaryCTA?.destination,
                                  destination != .drafts {
                            Text(.Remote.remoteCompleteOnMac).foregroundStyle(.secondary)
                        }
                        draftSection.id(RemoteCardCTA.Destination.drafts)
                        if let result = model.state.result {
                            Text(result.status.title).font(.callout).foregroundStyle(.secondary)
                            Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
                        }
                        actionSection.id(RemoteCardCTA.Destination.actions)
                    }
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .task {
                    if let destination = current.primaryCTA?.destination {
                        proxy.scrollTo(destination, anchor: .top)
                    }
                }
            }
            .navigationTitle(Text(verbatim: current.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .accessibilityLabel(Text(.Remote.remoteOpen))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(.Remote.remoteClose) { dismiss() } }
            }
            .alert(Text(confirmation?.kind.title ?? .Remote.remoteConfirm), isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button(role: confirmation?.kind == .deleteDraft ? .destructive : nil) {
                    guard let action = confirmation, let card = confirmationCard else { return }
                    let approval = approvalID
                    confirmation = nil; confirmationCard = nil; approvalID = nil
                    Task { await model.perform(card: card, action: action, approvalID: approval) }
                } label: { Text(confirmation?.kind == .deleteDraft ? .CommentReview.commentReviewDelete : .Remote.remoteConfirm) }
                Button(.Remote.remoteCancel, role: .cancel) { confirmation = nil; confirmationCard = nil; approvalID = nil; model.cancelApproval() }
            } message: {
                if confirmation?.kind == .approve, let card = confirmationCard {
                    Text(.RemoteSecurity.remoteSecurityApproveHelp)
                        + Text(verbatim: "\n" + card.project + "\n" + card.title + "\n" + (card.url?.absoluteString ?? "") + "\n")
                        + Text(.RemoteSecurity.remoteSecurityCommit) + Text(verbatim: " " + (card.head ?? "") + "\n")
                        + Text(.RemoteSecurity.remoteSecurityAccount) + Text(verbatim: " " + confirmationAccount)
                } else if let text = confirmation?.confirmationText { Text(verbatim: text) }
                else { Text(confirmation?.kind == .deleteDraft ? .CommentReview.commentReviewDeleteHelp : .Remote.remoteConfirmHelp) }
            }
            .onDisappear { model.cancelApproval() }
        }
    }

    private func showConfirmation(_ action: RemoteAction) {
        let card = current
        model.cancelApproval()
        approvalID = action.kind == .approve ? model.prepareApproval(card: card, action: action) : nil
        guard action.kind != .approve || approvalID != nil else { return }
        confirmationAccount = model.state.board?.account ?? ""
        confirmationCard = card; confirmation = action
    }

    @ViewBuilder
    private var draftSection: some View {
        if !current.drafts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(.RemoteDetail.remoteDetailPendingDrafts).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(current.drafts.count, format: .number)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.secondary.opacity(0.08), in: Capsule())
                }
                Text(.RemoteDetail.remoteDetailPendingDraftsHelp)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(current.drafts) { draft in
                    RemoteDraftCard(draft: draft,
                        deleteAction: current.actions.first { $0.kind == .deleteDraft && $0.id == "deleteDraft:\(draft.id)" },
                        canDelete: model.state.canAct(now: .now),
                        onDelete: showConfirmation)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if model.state.pending != nil || current.actions.contains(where: { $0.kind != .deleteDraft }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(.RemoteDetail.remoteDetailActions).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if !current.detail.isEmpty {
                    Text(verbatim: current.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        if model.state.pending != nil { ProgressView(.Remote.remoteRunning) }
                        ForEach(current.actions.filter { $0.kind != .deleteDraft }) { action in
                            Button { showConfirmation(action) } label: {
                                Text(action.kind.title).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.state.canAct(now: context.date))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
