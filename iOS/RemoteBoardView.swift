import SwiftUI
import MergeTetherRemote

struct RemoteBoardView: View {
    @Bindable var model: RemotePhoneModel
    @State private var pairingSheet = false
    @State private var selected: RemoteCard?
    @State private var showingInbox = false
    @State private var pendingInboxCard: RemoteCard?
    var body: some View {
        NavigationStack {
            Group {
                if !model.paired { RemotePairingView(model: model) }
                else if let board = model.state.board {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionStatus
                        if board.partial { Text(.Remote.remotePartial).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                        RemoteLaneBoard(lanes: board.lanes.filter { $0.id != .other }, onOpen: { selected = $0 },
                            onFinishCommentReview: finishCommentReview, canAct: { model.state.canAct(now: $0) })
                        if let updated = board.updatedAt {
                            HStack { Text(.Remote.remoteUpdated); Text(updated, style: .relative) }
                                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 4)
                        }
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let status = model.connectionStatus(now: context.date)
                        ContentUnavailableView {
                            Label(status.title, systemImage: status.symbol)
                        } description: {
                            Text(status.help)
                        } actions: {
                            if status == .connecting {
                                ProgressView().accessibilityLabel(Text(.Remote.remoteConnecting))
                            } else {
                                reconnectButton
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .accessibilityIdentifier("remote.connection.empty")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.error && !model.paired { Text(.Remote.remoteError).font(.caption).foregroundStyle(.red).padding() }
            }
            .navigationTitle(Text(.Remote.remoteTitle)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            Button { showingInbox = true } label: {
                                Image(systemName: "tray")
                                    .overlay(alignment: .topTrailing) {
                                        if inboxCards.count > 0 {
                                            Text(inboxCards.count, format: .number)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .frame(minWidth: 16, minHeight: 16)
                                                .background(.red, in: Capsule())
                                                .offset(x: 9, y: -8)
                                        }
                                    }
                            }
                            .accessibilityLabel(Text(.Board.boardInboxButton))
                            .accessibilityValue(Text(.Board.boardInboxAccessibilityCount(inboxCards.count)))
                            .accessibilityIdentifier("remote.inbox")
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let status = model.connectionStatus(now: context.date)
                                HStack(spacing: 16) {
                                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                                        .accessibilityLabel(Text(.Remote.remoteRefreshData))
                                        .accessibilityIdentifier("remote.refresh")
                                        .disabled(status != .connected)
                                    Menu {
                                        reconnectButton.disabled(status == .connecting)
                                    } label: { Image(systemName: "ellipsis.circle") }
                                        .accessibilityLabel(Text(.Remote.remoteConnectionMenu))
                                        .accessibilityIdentifier("remote.connection.menu")
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { pairingSheet = true } label: { Image(systemName: "qrcode.viewfinder") }.accessibilityLabel(Text(.Remote.remoteReplace))
                    }
                }
            }
            .alert(Text(.Remote.remotePair), isPresented: Binding(
                get: { model.paired && !pairingSheet && model.pairingCandidate != nil },
                set: { if !$0 { model.pairingCandidate = nil } }
            )) {
                Button(.Remote.remoteConnect) { model.acceptPairing() }
                Button(.Remote.remoteCancel, role: .cancel) { model.pairingCandidate = nil }
            } message: {
                Text(.Remote.remotePairingTrust) + Text(verbatim: "\n" + (model.pairingCandidate?.origin.absoluteString ?? ""))
            }
            .sheet(isPresented: $pairingSheet) { NavigationStack { RemotePairingView(model: model) }.presentationDetents([.medium, .large]) }
            .onChange(of: model.pairingRevision) {
                pairingSheet = false; selected = nil; showingInbox = false; pendingInboxCard = nil
            }
            .popover(isPresented: $showingInbox, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                RemoteInboxView(cards: inboxCards, onOpen: { pendingInboxCard = $0; showingInbox = false },
                    onFinishCommentReview: finishCommentReview, canAct: { model.state.canAct(now: $0) })
                    .frame(idealWidth: 520, idealHeight: 680)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: showingInbox) { _, isPresented in
                if !isPresented, let pendingInboxCard {
                    selected = pendingInboxCard
                    self.pendingInboxCard = nil
                }
            }
            .sheet(item: $selected) { card in RemoteCardDetail(model: model, original: card) }
            .alert(Text(model.state.result?.status.title ?? .Remote.remoteCompleted), isPresented: Binding(
                get: { model.state.result != nil }, set: { if !$0 { model.state.acknowledgeResult() } }
            )) { Button(.Remote.remoteClose) { model.state.acknowledgeResult() } }
        }
    }
    private var inboxCards: [RemoteCard] {
        model.state.board?.lanes.first(where: { $0.id == .other })?.cards ?? []
    }
    private func finishCommentReview(_ card: RemoteCard) {
        guard let action = card.actions.first(where: { $0.kind == .finishCommentReview }) else { return }
        Task { await model.perform(card: card, action: action) }
    }
    private var reconnectButton: some View {
        Button { model.reconnect() } label: { Label(.Remote.remoteReconnect, systemImage: "arrow.triangle.2.circlepath") }
            .accessibilityIdentifier("remote.reconnect")
    }
    private var connectionStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = model.connectionStatus(now: context.date)
            let refreshing = status == .connecting || (status == .connected && model.state.isRefreshing(now: context.date))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(status.title, systemImage: status.symbol)
                        .foregroundStyle(status == .connected ? .green : .secondary)
                        .accessibilityIdentifier("remote.connection.status")
                    ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                        .opacity(refreshing ? 1 : 0).accessibilityHidden(!refreshing)
                        .accessibilityLabel(Text(.Remote.remoteRefreshData))
                        .accessibilityIdentifier("remote.refresh.progress")
                    Spacer()
                    if status == .offline || status == .failed { reconnectButton }
                }
                if status != .connected {
                    Text(.Remote.remoteCachedBoard).foregroundStyle(.secondary)
                    if status != .connecting { Text(status.help).foregroundStyle(.secondary) }
                }
            }
            .font(.caption).padding(.horizontal).padding(.top, 8)
        }
    }
}

struct RemoteCardView: View {
    let card: RemoteCard
    var expanded = false
    var onOpen: (() -> Void)?
    var onFinishCommentReview: (() -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onOpen {
                Button(action: onOpen) { header }.buttonStyle(.plain)
                    .accessibilityIdentifier("remote.card.\(card.id)")
            } else { header }
            content
            if !expanded, let onOpen {
                HStack {
                    if let secondary = card.presentation?.secondaryCTA {
                        Button(action: onOpen) { Text(verbatim: secondary.title) }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if card.actions.contains(where: { $0.kind == .finishCommentReview }), let onFinishCommentReview {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Button(action: onFinishCommentReview) { Text(.CommentReview.commentReviewFinish) }
                                .font(.caption.weight(.semibold)).buttonStyle(.borderedProminent)
                                .disabled(canAct?(context.date) != true)
                                .accessibilityIdentifier("remote.finish-comment-review.\(card.id)")
                        }
                    } else if let cta = card.primaryCTA {
                        Button(action: onOpen) { Text(verbatim: cta.title) }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            .accessibilityIdentifier("remote.cta.\(card.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            if card.needsAttention == true {
                RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 4).padding(.vertical, 12)
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let author = card.presentation?.author { Text(verbatim: author).lineLimit(1) }
                else if card.presentation == nil { Text(verbatim: card.project).lineLimit(1) }
                Spacer(minLength: 4)
                if let badge = card.presentation?.draftBadge { Text(verbatim: badge).fontWeight(.semibold) }
                if let iid = card.mergeRequestIID {
                    if card.id.hasPrefix("mr:") { RemoteApprovalProgressBadge(progress: card.approvals) }
                    Text(verbatim: "!\(iid)").monospacedDigit().fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
            title
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !card.detail.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if card.needsAttention == true { Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true) }
                    Text(verbatim: card.detail).lineLimit(expanded ? nil : 2)
                }.font(.caption).foregroundStyle(card.needsAttention == true ? .orange : .secondary)
            }
            if let status = card.presentation?.status {
                HStack(spacing: 5) {
                    if card.presentation?.working == true { ProgressView().controlSize(.mini) }
                    Text(verbatim: status).font(.caption)
                }.foregroundStyle(.secondary)
            }
            if let dependencies = card.dependencies { RemoteMRDependencyRow(dependencies: dependencies) }
            if let nextStep = card.presentation?.nextStep {
                Text(verbatim: nextStep).font(.caption).foregroundStyle(.secondary)
            }
            if let chips = card.presentation?.chips {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Label { Text(verbatim: chip.title) } icon: { Image(systemName: chip.symbol) }
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if !card.drafts.isEmpty {
                Label(.Remote.remoteComments, systemImage: "text.bubble").font(.caption).foregroundStyle(.tint)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var title: some View {
        let titleText = Text(verbatim: card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        let repository = card.presentation?.repository ?? ""
        let repositoryText = Text(verbatim: repository).font(.caption).foregroundStyle(.tint)
        return (titleText + Text(verbatim: repository.isEmpty ? "" : "  ") + repositoryText)
            .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct RemoteMRDependencyRow: View {
    let dependencies: RemoteMRDependencies
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !description.characters.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = dependencies.notice {
                Text(verbatim: notice).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var description: AttributedString {
        var text = AttributedString()
        if let position = dependencies.stackPosition {
            text = AttributedString(String(localized: .MRDependencies.mrDependenciesStackPosition(position)))
        }
        if !dependencies.predecessors.isEmpty {
            if dependencies.stackPosition != nil { text += AttributedString(" · ") }
            text += AttributedString(String(localized: .MRDependencies.mrDependenciesAfter) + " ")
            for (index, predecessor) in dependencies.predecessors.enumerated() {
                if index > 0 { text += AttributedString(", ") }
                var reference = predecessor.reference
                if !predecessor.isCurrent { reference += " (\(String(localized: .MRDependencies.mrDependenciesLastKnown)))" }
                var link = AttributedString(reference)
                link.link = predecessor.url
                text += link
            }
        }
        return text
    }
}

private struct RemoteApprovalProgressBadge: View {
    let progress: RemoteApprovalProgress?

    private var received: Int { progress?.received ?? progress?.completed ?? 0 }

    private var explanation: Text {
        if let progress, progress.required == 0 { Text(.Board.boardApprovalsReceived(received)) }
        else if let progress { Text(.Board.boardApprovalsHelp(progress.completed, progress.required)) }
        else { Text(.Board.boardApprovalsUnavailable) }
    }
    private var complete: Bool { progress.map { ($0.required == 0 ? received > 0 : $0.completed == $0.required) } ?? false }

    var body: some View {
        if progress.map({ $0.required > 0 || received > 0 }) ?? true {
            HStack(spacing: 3) {
                Image(systemName: complete ? "checkmark.seal.fill" : "checkmark.seal").accessibilityHidden(true)
                if let progress, progress.required == 0 { Text(verbatim: "\(received)") }
                else if let progress { Text(.Board.boardApprovalRatio(progress.completed, progress.required)) }
                else { Text(.Board.boardApprovalsUnknownRatio) }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(complete ? Color.green : .secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.secondary.opacity(0.08), in: Capsule()).fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel(explanation)
        }
    }
}

struct RemoteCardDetail: View {
    @Bindable var model: RemotePhoneModel
    let original: RemoteCard
    @State private var confirmation: RemoteAction?
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
                    VStack(alignment: .leading, spacing: 20) {
                        RemoteCardView(card: current, expanded: true).id(headerDestination)
                        if current.primaryCTA?.destination == .setup {
                            Text(.Remote.remoteSetupOnMac).foregroundStyle(.secondary).id(RemoteCardCTA.Destination.setup)
                        } else if current.actions.isEmpty, let destination = current.primaryCTA?.destination,
                                  destination != .drafts {
                            Text(.Remote.remoteCompleteOnMac).foregroundStyle(.secondary)
                        }
                        if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { Label(.Remote.remoteOpen, systemImage: "arrow.up.right.square") }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(current.drafts) { draft in
                                VStack(alignment: .leading, spacing: 8) {
                                    if let action = current.actions.first(where: { $0.kind == .deleteDraft && $0.id == "deleteDraft:\(draft.id)" }) {
                                        HStack {
                                            Spacer()
                                            Button { confirmation = action } label: { Image(systemName: "trash") }
                                                .accessibilityLabel(Text(.CommentReview.commentReviewDelete))
                                                .disabled(!model.state.canAct(now: .now))
                                        }
                                    }
                                    if let context = draft.context { Text(verbatim: context).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                    Text(verbatim: draft.body).textSelection(.enabled)
                                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }.id(RemoteCardCTA.Destination.drafts)
                        if let result = model.state.result {
                            Text(result.status.title).font(.callout).foregroundStyle(.secondary)
                            Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 12) {
                                ForEach(current.actions.filter { $0.kind != .deleteDraft }) { action in
                                    Button(action.kind.title) { confirmation = action }.buttonStyle(.borderedProminent)
                                        .disabled(!model.state.canAct(now: context.date))
                                }
                                if model.state.pending != nil { ProgressView(.Remote.remoteRunning) }
                            }
                        }
                        .id(RemoteCardCTA.Destination.actions)
                    }.padding()
                }
                .task {
                    if let destination = current.primaryCTA?.destination {
                        proxy.scrollTo(destination, anchor: .top)
                    }
                }
            }
            .navigationTitle(Text(verbatim: current.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(.Remote.remoteClose) { dismiss() } } }
            .alert(Text(confirmation?.kind.title ?? .Remote.remoteConfirm), isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button(role: confirmation?.kind == .deleteDraft ? .destructive : nil) {
                    guard let action = confirmation else { return }; confirmation = nil
                    let card = current
                    Task { await model.perform(card: card, action: action) }
                } label: { Text(confirmation?.kind == .deleteDraft ? .CommentReview.commentReviewDelete : .Remote.remoteConfirm) }
                Button(.Remote.remoteCancel, role: .cancel) { confirmation = nil }
            } message: {
                Text(confirmation?.kind == .deleteDraft ? .CommentReview.commentReviewDeleteHelp : .Remote.remoteConfirmHelp)
            }
        }
    }
}
