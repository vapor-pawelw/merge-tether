import SwiftUI
import MergeTetherRemote

struct RemoteBoardView: View {
    @Bindable var model: RemotePhoneModel
    @State private var pairingSheet = false
    @State private var selected: RemoteCardSelection?
    @State private var showingInbox = false
    @State private var pendingInboxCard: RemoteCardSelection?
    var body: some View {
        NavigationStack {
            Group {
                if !model.paired { RemotePairingView(model: model) }
                else if let board = model.state.board {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionStatus
                        if board.automationPaused == true {
                            Text(.Remote.remoteAutomationPaused).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                        }
                        if board.partial { Text(.Remote.remotePartial).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                        RemoteLaneBoard(lanes: board.lanes.filter { $0.id != .other }, onOpen: { selected = .init(card: $0) },
                            onOpenCTA: { selected = .init(card: $0, cta: $1) },
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
            .background(Color(uiColor: .systemGroupedBackground))
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
                            RemoteConnectionToolbar(model: model)
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
                RemoteInboxView(cards: inboxCards, onOpen: { pendingInboxCard = .init(card: $0); showingInbox = false },
                    onOpenCTA: { pendingInboxCard = .init(card: $0, cta: $1); showingInbox = false },
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
            .sheet(item: $selected) { selection in
                RemoteCardDetail(model: model, original: selection.card, initialSelection: selection)
            }
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

private struct RemoteCardCTAButton: View {
    let cta: RemoteCardCTA
    let canAct: ((Date) -> Bool)?
    let onTap: () -> Void

    var body: some View {
        if cta.actionID != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button.disabled(canAct?(context.date) != true)
            }
        } else { button }
    }

    private var button: some View {
        Button(action: onTap) { Text(verbatim: cta.title) }
    }
}

// TimelineView inside ToolbarItem causes a continuous toolbar preference-update loop.
private struct RemoteConnectionToolbar: View {
    let model: RemotePhoneModel
    @State private var now = Date()

    var body: some View {
        let status = model.connectionStatus(now: now)
        HStack(spacing: 16) {
            Button { Task { await model.refresh(fromGitLab: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text(.Remote.remoteRefreshData))
            .accessibilityIdentifier("remote.refresh")
            .disabled(status != .connected)
            Menu {
                if let origin = model.relayConfiguration.origin {
                    Text(.Remote.remoteRelayConfigured)
                    Text(verbatim: origin.absoluteString)
                    Text(.Remote.remoteRelayOwnership)
                    Divider()
                }
                Button { model.reconnect() } label: {
                    Label(.Remote.remoteReconnect, systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("remote.reconnect")
                .disabled(status == .connecting)
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel(Text(.Remote.remoteConnectionMenu))
            .accessibilityIdentifier("remote.connection.menu")
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

struct RemoteCardView: View {
    let card: RemoteCard
    var expanded = false
    var onOpen: (() -> Void)?
    var onOpenCTA: ((RemoteCardCTA) -> Void)? = nil
    var onFinishCommentReview: (() -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 16 : 12) {
            if let onOpen {
                Button(action: onOpen) { header.contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityIdentifier("remote.card.\(card.id)")
            } else { header }
            content
            if !expanded, onOpen != nil {
                HStack {
                    if let secondary = card.presentation?.secondaryCTA {
                        RemoteCardCTAButton(cta: secondary, canAct: canAct) { onOpenCTA?(secondary) }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("remote.secondary-cta.\(card.id)")
                    }
                    Spacer(minLength: 0)
                    if card.actions.contains(where: { $0.kind == .finishCommentReview }), let onFinishCommentReview {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Button(action: onFinishCommentReview) { Text(.CommentReview.commentReviewFinish) }
                                .font(.subheadline.weight(.semibold)).buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(canAct?(context.date) != true)
                                .accessibilityIdentifier("remote.finish-comment-review.\(card.id)")
                        }
                    } else if let cta = card.primaryCTA {
                        RemoteCardCTAButton(cta: cta, canAct: canAct) { onOpenCTA?(cta) }
                            .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("remote.cta.\(card.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .overlay(alignment: .leading) {
            if card.needsAttention == true {
                RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 4).padding(.vertical, 12)
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: expanded ? card.project : (card.presentation?.repository ?? card.project))
                    .fontWeight(.medium).lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .foregroundStyle(.tint)
                Spacer(minLength: 4)
                if let iid = card.mergeRequestIID {
                    Text(verbatim: "!\(iid)").monospacedDigit().fixedSize()
                }
            }.font(.caption).foregroundStyle(.secondary)
            title
            if card.presentation?.author != nil || card.presentation?.draftBadge != nil || card.id.hasPrefix("mr:") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        author
                        Spacer(minLength: 0)
                        badges
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        author
                        badges
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder
    private var author: some View {
        if let presentation = card.presentation, presentation.author != nil {
            PersonLabel(person: .init(name: presentation.author, username: presentation.authorUsername,
                                      avatarURL: presentation.authorAvatarURL))
        }
    }
    private var badges: some View {
        HStack(spacing: 6) {
            if let badge = card.presentation?.draftBadge {
                Text(verbatim: badge).fontWeight(.medium)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }
            if card.id.hasPrefix("mr:") { RemoteApprovalProgressBadge(progress: card.approvals) }
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !card.detail.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if card.needsAttention == true { Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true) }
                    Text(verbatim: card.detail).lineLimit(expanded ? nil : 2)
                }
                .font(expanded ? .callout : .subheadline)
                .foregroundStyle(card.needsAttention == true ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let requirements = card.presentation?.requirements, !requirements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(requirements.enumerated()), id: \.offset) { _, line in
                        Label { Text(verbatim: line).foregroundStyle(.primary) } icon: {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.subheadline)
            } else if let status = card.visibleStatus {
                HStack(spacing: 5) {
                    if card.presentation?.working == true {
                        ProgressView().controlSize(.mini)
                        if let symbol = card.presentation?.statusSymbol { Image(systemName: symbol).accessibilityHidden(true) }
                    }
                    Text(verbatim: status).font(.subheadline)
                }.foregroundStyle(.secondary)
            }
            if let drafts = card.presentation?.pendingDrafts {
                Label { Text(verbatim: drafts).foregroundStyle(.primary) } icon: {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary)
                }
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if let dependencies = card.dependencies { RemoteMRDependencyRow(dependencies: dependencies) }
            if let steps = card.presentation?.steps, !steps.isEmpty {
                RemoteStepChain(steps: steps, current: card.presentation?.currentStep ?? 0)
                    .font(expanded ? .callout : .caption)
            } else if let nextStep = card.visibleNextStep {
                Text(verbatim: nextStep).font(expanded ? .callout : .caption).foregroundStyle(.secondary)
            }
            if let chips = card.presentation?.chips {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Label { Text(verbatim: chip.title) } icon: { Image(systemName: chip.symbol) }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.secondary.opacity(0.06), in: Capsule())
                }
            } else if !card.drafts.isEmpty, card.presentation?.pendingDrafts == nil {
                Label(.Remote.remoteComments, systemImage: "text.bubble").font(.caption).foregroundStyle(.tint)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var title: some View {
        Text(verbatim: card.title)
            .font(expanded ? .title3.weight(.semibold) : .headline)
            .foregroundStyle(.primary)
            .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: true)
    }
}
/// The automation order with the current step emphasised, matching the Mac card.
private struct RemoteStepChain: View {
    let steps: [String]
    let current: Int
    var body: some View {
        steps.enumerated().reduce(Text(verbatim: "")) { text, entry in
            let (index, step) = entry
            let separator = index > 0 ? Text(verbatim: " › ").foregroundStyle(.tertiary) : Text(verbatim: "")
            let word = Text(verbatim: step)
                .fontWeight(index == current ? .semibold : .regular)
                .foregroundStyle(index == current ? AnyShapeStyle(.primary)
                    : index < current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            return text + separator + word
        }
        .fixedSize(horizontal: false, vertical: true)
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
        else if let progress { Text(.Board.boardApprovalsHelp(received, progress.required)) }
        else { Text(.Board.boardApprovalsUnavailable) }
    }
    private var complete: Bool { progress.map { received > 0 && ($0.requirementsSatisfied ?? ($0.required == 0 || received >= $0.required)) } ?? false }

    var body: some View {
        if progress.map({ $0.required > 0 || received > 0 }) ?? true {
            HStack(spacing: 3) {
                Image(systemName: complete ? "checkmark.seal.fill" : "checkmark.seal").accessibilityHidden(true)
                if let progress, progress.required == 0 { Text(verbatim: "\(received)") }
                else if let progress { Text(.Board.boardApprovalRatio(received, progress.required)) }
                else { Text(.Board.boardApprovalsUnknownRatio) }
            }
            .font(.caption2).monospacedDigit().foregroundStyle(complete ? Color.green : .secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.secondary.opacity(0.08), in: Capsule()).fixedSize()
            .accessibilityElement(children: .ignore).accessibilityLabel(explanation)
        }
    }
}
