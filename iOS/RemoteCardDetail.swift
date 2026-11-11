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
    private var boardCard: RemoteCard? { model.state.board?.cards.first { $0.id == original.id } }
    private var current: RemoteCard { boardCard ?? original }
    private var loadedDetails: RemoteMRDetails? {
        guard let board = model.state.board, let card = boardCard else { return nil }
        return model.detailState.details(for: card, board: board)
    }
    private var headerCard: RemoteCard {
        var card = current
        if let details = loadedDetails { card.approvals = details.approvals?.progress }
        return card
    }
    private var detailIdentity: String {
        (model.state.board?.hostSession.uuidString ?? "") + (model.state.board?.account ?? "")
            + ((try? RemoteDigest.token(current)) ?? "") + String(model.supportsDetails)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        RemoteCardView(card: headerCard, expanded: true).id(RemoteCardCTA.Destination.overview)
                        Menu {
                            Button(.RemoteDetail.remoteDetailOverview) { proxy.scrollTo(RemoteCardCTA.Destination.overview, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailPendingDrafts) { proxy.scrollTo(RemoteCardCTA.Destination.drafts, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailApprovals) { proxy.scrollTo(RemoteDetailAnchor.approvals, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailDiscussions) { proxy.scrollTo(RemoteDetailAnchor.discussions, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailFeedback) { proxy.scrollTo(RemoteCardCTA.Destination.feedback, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailActivity) { proxy.scrollTo(RemoteCardCTA.Destination.assistantRuns, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailActions) { proxy.scrollTo(RemoteCardCTA.Destination.actions, anchor: .top) }
                        } label: {
                            Label(.RemoteDetail.remoteDetailSections, systemImage: "list.bullet")
                                .frame(minHeight: 44)
                        }
                        if current.primaryCTA?.destination == .setup {
                            Text(.Remote.remoteSetupOnMac).foregroundStyle(.secondary).id(RemoteCardCTA.Destination.setup)
                        } else if current.actions.isEmpty, let destination = current.primaryCTA?.destination,
                                  destination != .drafts {
                            Text(.Remote.remoteCompleteOnMac).foregroundStyle(.secondary)
                        }
                        if current.id.hasPrefix("mr:") {
                            detailReadStatus
                        }
                        draftSection.id(RemoteCardCTA.Destination.drafts)
                        if current.id.hasPrefix("mr:") {
                            if let details = loadedDetails {
                                RemoteMRDetailContent(details: details, card: current)
                            }
                        }
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
                .task(id: detailIdentity) {
                    guard current.id.hasPrefix("mr:") else { return }
                    await model.requestDetails(card: current)
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
            .onDisappear { model.cancelApproval(); model.cancelDetails() }
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
                        deleteAction: boardCard?.actions.first { $0.kind == .deleteDraft && $0.id == "deleteDraft:\(draft.id)" },
                        canDelete: boardCard != nil && model.state.canAct(now: .now),
                        onDelete: showConfirmation)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if boardCard != nil, model.state.pending != nil || current.actions.contains(where: { $0.kind != .deleteDraft }) {
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

    private var detailReadStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if boardCard == nil {
                    Text(.RemoteDetail.remoteDetailNoLongerCurrent).foregroundStyle(.orange)
                } else if model.connectionStatus(now: context.date) != .connected {
                    Label(.RemoteDetail.remoteDetailCached, systemImage: "wifi.slash").foregroundStyle(.secondary)
                } else if !model.supportsDetails {
                    Text(.RemoteDetail.remoteDetailUpdateMac).foregroundStyle(.secondary)
                } else {
                    if model.detailState.isLoading(now: context.date) {
                        ProgressView(.RemoteDetail.remoteDetailLoading)
                    }
                    if model.detailState.failure != nil || model.detailState.hasTimedOut(now: context.date) {
                        Text(model.detailState.failure == .changed ? .RemoteDetail.remoteDetailContextChanged : .RemoteDetail.remoteDetailReadFailed)
                            .foregroundStyle(.orange)
                        if model.detailState.failure == .changed {
                            Button { Task { await model.refresh(force: true) } } label: {
                                Label(.Remote.remoteRefreshData, systemImage: "arrow.clockwise").frame(minHeight: 44)
                            }
                        }
                    }
                    Button { Task { await model.requestDetails(card: current, force: true) } } label: {
                        Label(.RemoteDetail.remoteDetailRefresh, systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    .disabled(model.detailState.isLoading(now: context.date))
                }
                if let details = loadedDetails {
                    HStack {
                        Text(.RemoteDetail.remoteDetailChecked)
                        Text(details.checkedAt, style: .relative)
                    }.font(.caption).foregroundStyle(.secondary)
                    if details.truncated {
                        Text(.RemoteDetail.remoteDetailTruncated).foregroundStyle(.orange)
                        if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { Label(.Remote.remoteOpen, systemImage: "arrow.up.right.square") }
                                .frame(minHeight: 44)
                        }
                    }
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
