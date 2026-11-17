import SwiftUI
import MergeTetherRemote

struct RemoteCardDetail: View {
    @Bindable var model: RemotePhoneModel
    let original: RemoteCard
    @State private var confirmation: RemoteAction?
    @State private var confirmationCard: RemoteCard?
    @State private var approvalID: UUID?
    @State private var confirmationAccount = ""
    /// The last details shown for this card, kept on screen while a re-read is in flight so sections do not vanish.
    @State private var retainedDetails: RemoteMRDetails?
    @Environment(\.dismiss) private var dismiss
    private var boardCard: RemoteCard? { model.state.board?.cards.first { $0.id == original.id } }
    private var current: RemoteCard { boardCard ?? original }
    /// Matching a response hashes the card, so it is evaluated once per body rather than per use or timer tick.
    private var loadedDetails: RemoteMRDetails? {
        guard let board = model.state.board, let card = boardCard else { return nil }
        return model.detailState.details(for: card, board: board)
    }
    private func headerCard(_ details: RemoteMRDetails?) -> RemoteCard {
        var card = current
        if let details { card.approvals = details.approvals?.progress }
        return card
    }
    private struct DetailIdentity: Equatable {
        let session: UUID?, account: String?, card: RemoteCard, supportsDetails: Bool
    }
    private var detailIdentity: DetailIdentity {
        .init(session: model.state.board?.hostSession, account: model.state.board?.account,
              card: current, supportsDetails: model.supportsDetails)
    }
    var body: some View {
        let fresh = loadedDetails
        let rereading = model.detailState.pending != nil && boardCard != nil
        let shown = fresh ?? (rereading ? retainedDetails : nil)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // Lazy: off-screen sections are not laid out again on each board update.
                    LazyVStack(alignment: .leading, spacing: 24) {
                        RemoteCardView(card: headerCard(shown), expanded: true).id(RemoteCardCTA.Destination.overview)
                        if let branches = shown?.branches {
                            Label { Text(verbatim: branches.source + " → " + branches.target) } icon: {
                                Image(systemName: "arrow.triangle.branch")
                            }
                            .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(.RemoteDetail.remoteDetailBranches(branches.source, branches.target)))
                        }
                        Menu {
                            Button(.RemoteDetail.remoteDetailOverview) { proxy.scrollTo(RemoteCardCTA.Destination.overview, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailPendingDrafts) { proxy.scrollTo(RemoteCardCTA.Destination.drafts, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailActions) { proxy.scrollTo(RemoteCardCTA.Destination.actions, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailFeedback) { proxy.scrollTo(RemoteCardCTA.Destination.feedback, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailDiscussions) { proxy.scrollTo(RemoteDetailAnchor.discussions, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailApprovals) { proxy.scrollTo(RemoteDetailAnchor.approvals, anchor: .top) }
                            Button(.RemoteDetail.remoteDetailActivity) { proxy.scrollTo(RemoteCardCTA.Destination.assistantRuns, anchor: .top) }
                        } label: {
                            Label(.RemoteDetail.remoteDetailSections, systemImage: "list.bullet")
                                .frame(minHeight: 44)
                        }
                        if current.primaryCTA?.destination == .setup {
                            Text(.Remote.remoteSetupOnMac).foregroundStyle(.secondary).id(RemoteCardCTA.Destination.setup)
                        } else if !current.actions.contains(where: { $0.kind != .setCommentOrigin }), let destination = current.primaryCTA?.destination,
                                  destination != .drafts {
                            Text(.Remote.remoteCompleteOnMac).foregroundStyle(.secondary)
                        }
                        if current.id.hasPrefix("mr:") {
                            detailReadStatus(fresh)
                        }
                        draftSection(shown).id(RemoteCardCTA.Destination.drafts)
                        // Like the Mac detail, the decision and its controls lead; reference sections follow.
                        if let result = model.state.result {
                            Text(result.status.title).font(.callout).foregroundStyle(.secondary)
                            Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
                        }
                        actionSection.id(RemoteCardCTA.Destination.actions)
                        if current.id.hasPrefix("mr:") {
                            if let details = shown {
                                RemoteMRDetailContent(details: details, card: current,
                                    onCommentOrigin: current.actions.contains { $0.kind == .setCommentOrigin } ? { request in
                                        Task { await model.setCommentOrigin(request, card: current) }
                                    } : nil)
                            }
                        }
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
                .onChange(of: fresh) { _, value in if let value { retainedDetails = value } }
                .onChange(of: detailIdentity.session) { _, _ in retainedDetails = nil }
                .onChange(of: detailIdentity.account) { _, _ in retainedDetails = nil }
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
                Button(role: confirmation?.kind == .deleteDraft || confirmation?.kind == .stopJob ? .destructive : nil) {
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
    private func draftSection(_ details: RemoteMRDetails?) -> some View {
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
                        publishAction: boardCard?.actions.first { $0.kind == .publishDraft && $0.id == "publishDraft:\(draft.id)" },
                        extraContext: details?.draftContexts?[String(draft.id)],
                        canAct: boardCard != nil && model.state.canAct(now: .now),
                        onAction: showConfirmation)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if boardCard != nil, model.state.pending != nil || !buttonActions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // The header card above already states the explanation; repeat only the controls.
                Text(.RemoteDetail.remoteDetailActions).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                RemoteDetailActionButtons(actions: buttonActions, running: model.state.pending != nil,
                    onAction: showConfirmation)
                    .modifier(RemoteActionAvailability(state: model.state))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Draft-level actions live on their draft cards.
    private var buttonActions: [RemoteAction] {
        current.actions.filter { $0.kind != .deleteDraft && $0.kind != .publishDraft && $0.kind != .setCommentOrigin }
    }

    private func detailReadStatus(_ loadedDetails: RemoteMRDetails?) -> some View {
        // Each tick only reads cheap time-based state; the details were matched once by the caller.
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
                            Button { Task { await model.refresh(fromGitLab: true) } } label: {
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

private struct RemoteActionAvailability: ViewModifier {
    let state: RemotePhoneState
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content.disabled(!state.canAct(now: context.date))
        }
    }
}

private struct RemoteDetailActionButtons: View {
    let actions: [RemoteAction]
    let running: Bool
    let onAction: (RemoteAction) -> Void
    private static let secondaryKinds: Set<RemoteActionKind> = [.ignoreSuggestion, .restoreSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if running { ProgressView(.Remote.remoteRunning) }
            ForEach(actions.filter { !Self.secondaryKinds.contains($0.kind) }) { action in
                Button(role: action.kind == .stopJob ? .destructive : nil) { onAction(action) } label: {
                    title(action).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            ForEach(actions.filter { Self.secondaryKinds.contains($0.kind) }) { action in
                VStack(alignment: .leading, spacing: 8) {
                    if let label = action.label {
                        Text(verbatim: label).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { onAction(action) } label: {
                        Text(action.kind.title).font(.callout.weight(.medium)).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(action.kind == .ignoreSuggestion ? Color.orange : Color.accentColor)
                }
                .padding(.vertical, 4)
            }
        }
    }
    private func title(_ action: RemoteAction) -> Text {
        if let label = action.label { Text(verbatim: label) } else { Text(action.kind.title) }
    }
}
