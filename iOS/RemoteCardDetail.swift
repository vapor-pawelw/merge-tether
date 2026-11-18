import SwiftUI
import MergeTetherRemote

struct RemoteCardDetail: View {
    @Bindable var model: RemotePhoneModel
    let original: RemoteCard
    var initialSelection: RemoteCardSelection? = nil
    @State private var appliedInitialAction = false
    @State private var initialActionChanged = false
    @State private var scrolledToInitialDestination = false
    @State private var scrollTarget: RemoteCardCTA.Destination?
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
        if let approvals = details?.approvals {
            card.approvals = approvals.progress
            card.presentation?.approvalPeople = approvals.people
            card.presentation?.viewerApprovalID = approvals.viewerApprovalID
        }
        return card
    }
    private struct DetailIdentity: Equatable {
        let session: UUID?, account: String?, context: String?, supportsDetails: Bool
    }
    private var detailIdentity: DetailIdentity {
        .init(session: model.state.board?.hostSession, account: model.state.board?.account,
              context: model.supportsDetailContext ? current.detailContextDigest : (try? RemoteDigest.token(current)),
              supportsDetails: model.supportsDetails)
    }
    var body: some View {
        let fresh = loadedDetails
        let rereading = (model.detailState.pending != nil || model.isSynchronizingDetails) && boardCard != nil
        let shown = fresh ?? (rereading ? retainedDetails : nil)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // Lazy: off-screen sections are not laid out again on each board update.
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            RemoteCardView(card: headerCard(shown), expanded: true, branches: shown?.branches)
                                .id(RemoteCardCTA.Destination.overview)
                            if current.id.hasPrefix("mr:") { detailReadStatus(fresh) }
                        }
                        if current.primaryCTA?.destination == .setup {
                            Text(.Remote.remoteSetupOnMac).foregroundStyle(.secondary).id(RemoteCardCTA.Destination.setup)
                        } else if !current.actions.contains(where: { $0.kind != .setCommentOrigin }),
                                  current.primaryCTA?.destination == .actions {
                            Text(.Remote.remoteCompleteOnMac).foregroundStyle(.secondary)
                        }
                        if initialActionChanged {
                            Text(.Remote.remoteChanged).font(.callout).foregroundStyle(.orange)
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
                    .scrollTargetLayout()
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await model.refreshContent() }
                .background(Color(uiColor: .systemGroupedBackground))
                .scrollPosition(id: $scrollTarget, anchor: .top)
                .task(id: shown != nil) {
                    guard let selection = initialSelection else { return }
                    if !appliedInitialAction {
                        appliedInitialAction = true
                        if selection.cta?.actionID != nil {
                            if model.state.canAct(now: .now), let card = boardCard,
                               let action = selection.action(in: card) {
                                showConfirmation(action)
                            } else { initialActionChanged = true }
                        }
                    }
                    guard !scrolledToInitialDestination, !selection.needsDetails || shown != nil else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollTarget = selection.destination
                    scrolledToInitialDestination = true
                }
                .task(id: detailIdentity) {
                    guard current.id.hasPrefix("mr:") else { return }
                    await model.requestDetails(card: current)
                }
                .onChange(of: fresh) { _, value in if let value { retainedDetails = value } }
                .onChange(of: detailIdentity.session) { _, _ in retainedDetails = nil }
                .onChange(of: detailIdentity.account) { _, _ in retainedDetails = nil }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(Text(.Remote.remoteClose))
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if current.id.hasPrefix("mr:") { RemoteDetailRefreshButton(model: model, card: boardCard) }
                        sectionMenu(proxy)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.expiredApprovalCardID == original.id {
                    expiredApprovalNotice
                }
            }
            .navigationTitle(Text(verbatim: current.mergeRequestIID.map {
                (current.presentation?.repository ?? current.project) + " · !\($0)"
            } ?? current.title))
            .navigationBarTitleDisplayMode(.inline)
            .alert(Text(confirmation?.kind.title ?? .Remote.remoteConfirm), isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button(role: confirmation?.kind == .deleteDraft || confirmation?.kind == .stopJob ? .destructive : nil) {
                    guard let action = confirmation, let card = confirmationCard else { return }
                    let approval = approvalID
                    confirmation = nil; confirmationCard = nil; approvalID = nil
                    Task { await model.perform(card: card, action: action, approvalID: approval) }
                } label: {
                    switch confirmation?.kind {
                    case .deleteDraft: Text(.CommentReview.commentReviewDelete)
                    case .reReview, .merge, .enqueueMerge: Text(confirmation?.kind.title ?? .Remote.remoteConfirm)
                    case .prepare, .retryJob:
                        if let label = confirmation?.label {
                            Text(verbatim: label)
                        } else if let cta = confirmationCard?.primaryCTA, cta.actionID == confirmation?.id {
                            Text(verbatim: cta.title)
                        } else {
                            Text(.Remote.remoteConfirm)
                        }
                    default: Text(.Remote.remoteConfirm)
                    }
                }
                Button(.Remote.remoteCancel, role: .cancel) { confirmation = nil; confirmationCard = nil; approvalID = nil; model.cancelApproval() }
            } message: {
                if confirmation?.kind == .approve, let card = confirmationCard {
                    Text(.RemoteSecurity.remoteSecurityApproveHelp)
                        + Text(verbatim: "\n" + card.project + "\n" + card.title + "\n" + (card.url?.absoluteString ?? "") + "\n")
                        + Text(.RemoteSecurity.remoteSecurityCommit) + Text(verbatim: " " + (card.head ?? "") + "\n")
                        + Text(.RemoteSecurity.remoteSecurityAccount) + Text(verbatim: " " + confirmationAccount)
                } else if let text = confirmation?.confirmationText { Text(verbatim: text) }
                else if confirmation?.kind == .reReview { Text(.Remote.remoteReReviewConfirmation) }
                else { Text(confirmation?.kind == .deleteDraft ? .CommentReview.commentReviewDeleteHelp : .Remote.remoteConfirmHelp) }
            }
            .onDisappear { model.cancelApproval(); model.cancelDetails() }
        }
    }

    private var expiredApprovalNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(.RemoteSecurity.remoteSecurityConfirmationExpired, systemImage: "clock.badge.exclamationmark")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("remote.approval.expired")
            Button(.RemoteSecurity.remoteSecurityReloadCurrentCommit) {
                Task { await model.reloadAfterApprovalExpiry(cardID: original.id) }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("remote.approval.reload")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func sectionMenu(_ proxy: ScrollViewProxy) -> some View {
        Menu {
            Button(.RemoteDetail.remoteDetailOverview) { proxy.scrollTo(RemoteCardCTA.Destination.overview, anchor: .top) }
            Button(.RemoteDetail.remoteDetailPendingDrafts) { proxy.scrollTo(RemoteCardCTA.Destination.drafts, anchor: .top) }
            Button(.RemoteDetail.remoteDetailActions) { proxy.scrollTo(RemoteCardCTA.Destination.actions, anchor: .top) }
            Button(.RemoteDetail.remoteDetailFeedback) { proxy.scrollTo(RemoteCardCTA.Destination.feedback, anchor: .top) }
            Button(.RemoteDetail.remoteDetailDiscussions) { proxy.scrollTo(RemoteCardCTA.Destination.discussions, anchor: .top) }
            Button(.RemoteDetail.remoteDetailApprovals) { proxy.scrollTo(RemoteDetailAnchor.approvals, anchor: .top) }
            Button(.RemoteDetail.remoteDetailActivity) { proxy.scrollTo(RemoteCardCTA.Destination.assistantRuns, anchor: .top) }
            if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Divider()
                Link(destination: url) { Label(.Remote.remoteOpen, systemImage: "arrow.up.right.square") }
            }
        } label: { Image(systemName: "list.bullet") }
        .accessibilityLabel(Text(.RemoteDetail.remoteDetailSections))
        .accessibilityIdentifier("remote.details.sections")
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
                        replyThread: details?.threads?.first { $0.draftIDs?.contains(draft.id) == true },
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
                    if model.isSynchronizingDetails || model.detailState.isLoading(now: context.date) {
                        ProgressView(.RemoteDetail.remoteDetailLoading)
                    }
                    if !model.isSynchronizingDetails, model.detailState.failure != nil || model.detailState.hasTimedOut(now: context.date) {
                        Text(.RemoteDetail.remoteDetailReadFailed)
                            .foregroundStyle(.orange)
                    }
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

private struct RemoteDetailRefreshButton: View {
    let model: RemotePhoneModel
    let card: RemoteCard?
    @State private var now = Date()

    var body: some View {
        let loading = model.isSynchronizingDetails || model.detailState.isLoading(now: now)
        Button {
            guard card != nil else { return }
            Task { await model.refreshContent() }
        } label: {
            Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                .overlay { if loading { ProgressView() } }
        }
        .accessibilityLabel(Text(.RemoteDetail.remoteDetailRefresh))
        .accessibilityIdentifier("remote.details.refresh")
        .disabled(card == nil || !model.supportsDetails || loading || model.connectionStatus(now: now) != .connected)
        .task {
            while !Task.isCancelled {
                now = Date()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
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
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
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
