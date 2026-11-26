import SwiftUI
import MergeTetherRemote

struct RemoteBoardView: View {
    @Bindable var model: RemotePhoneModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pairingSheet = false
    @State private var selected: RemoteCardSelection?
    @State private var showingInbox = false
    @State private var showingHiddenReviews = false
    @State private var pendingInboxCard: RemoteCardSelection?
    @State private var regenerationPresentation: DraftRegenerationPresentation?

    private var viewerUsername: String? {
        guard let account = model.state.board?.account else { return nil }
        let parts = account.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }

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
                        if let batch = model.draftRegenerationBatch {
                            draftRegenerationStatus(batch)
                        }
                        RemoteLaneBoard(lanes: board.lanes.filter { $0.id != .other }, onOpen: { selected = .init(card: $0) },
                            onOpenCTA: { selected = .init(card: $0, cta: $1) },
                            model: model, onOpenHiddenReviews: board.hiddenReviews?.isEmpty == false ? { showingHiddenReviews = true } : nil,
                            onRefresh: { await model.refreshContent() })
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
                                        if let cards = model.state.inboxCards, !cards.isEmpty {
                                            Text(cards.count, format: .number)
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
                            .accessibilityValue(model.state.inboxCards.map {
                                Text(.Board.boardInboxAccessibilityCount($0.count))
                            } ?? Text(verbatim: ""))
                            .accessibilityIdentifier("remote.inbox")
                            RemoteConnectionToolbar(model: model, onRegenerateDrafts: {
                                regenerationPresentation = .init(scope: .all)
                            })
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
            .sheet(isPresented: $pairingSheet) {
                RemotePairingView(model: model)
                    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(300), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $regenerationPresentation) { model.draftRegenerationSheet($0) }
            .sheet(isPresented: $showingHiddenReviews) { RemoteHiddenReviewsView(model: model) }
            .onChange(of: model.pairingRevision) {
                pairingSheet = false; selected = nil; showingInbox = false; pendingInboxCard = nil
                showingHiddenReviews = false
                regenerationPresentation = nil
            }
            .onChange(of: model.state.board?.account) { _, _ in
                selected = nil
                showingHiddenReviews = false
                regenerationPresentation = nil
            }
            .popover(isPresented: $showingInbox, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let status = model.connectionStatus(now: context.date)
                    RemoteInboxView(cards: model.state.inboxCards,
                        isLoading: status == .connecting || (status == .connected && model.state.isRefreshing(now: context.date)),
                        onRetry: retryInbox,
                        onOpen: { pendingInboxCard = .init(card: $0); showingInbox = false },
                        onOpenCTA: { pendingInboxCard = .init(card: $0, cta: $1); showingInbox = false },
                        model: model,
                        onRefresh: { await model.refreshContent() })
                }
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
                    .presentationDragIndicator(.visible)
            }
            .alert(Text(model.resultTitle), isPresented: Binding(
                get: { selected == nil && !showingInbox && !showingHiddenReviews && model.state.result != nil },
                set: { if !$0, selected == nil, !showingInbox, !showingHiddenReviews { model.state.acknowledgeResult() } }
            )) {
                Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
            } message: {
                if model.showsAutomaticApprovalOffResult { Text(.Board.boardApprovalsAutomationOff) }
            }
            .alert(Text(.Remote.remoteBoardOrderRejected), isPresented: $model.boardOrderMoveRejected) {
                Button(.Remote.remoteClose, role: .cancel) {}
            } message: {
                Text(.Remote.remoteBoardOrderRejectedHelp)
            }
        }
        .environment(\.gitLabViewerUsername, viewerUsername)
    }

    private func draftRegenerationStatus(_ batch: DraftRegenerationBatch) -> some View {
        Button { regenerationPresentation = .init(scope: nil) } label: {
            HStack(spacing: 10) {
                if batch.phase == .generating || batch.phase == .saving {
                    ProgressView().controlSize(.small)
                } else {
                    CodingProviderIcon().foregroundStyle(.tint)
                }
                Text(batch.phase.regenerationTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).padding(.horizontal)
        .accessibilityIdentifier("draft-regeneration.resume")
    }
    private func retryInbox() {
        if model.connectionStatus() == .connected {
            Task { await model.refreshContent() }
        } else {
            model.reconnect()
        }
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
    var action: RemoteAction? = nil
    var labelHitArea: CardControlHitArea? = nil
    let onTap: () -> Void

    var body: some View {
        if cta.actionID != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button.disabled(canAct?(context.date) != true)
            }
        } else { button }
    }

    private var button: some View {
        Button(action: onTap) {
            let label = RemoteActionLabel(action: action, title: Text(verbatim: cta.title))
            if let labelHitArea {
                label.contentShape(.interaction, labelHitArea)
            } else {
                label
            }
        }
    }
}

// TimelineView inside ToolbarItem causes a continuous toolbar preference-update loop.
private struct RemoteConnectionToolbar: View {
    let model: RemotePhoneModel
    let onRegenerateDrafts: () -> Void
    @State private var now = Date()

    var body: some View {
        let status = model.connectionStatus(now: now)
        HStack(spacing: 16) {
            Button { Task { await model.refreshContent(fromGitLab: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(Text(.Remote.remoteRefreshGitLabBoard))
            .accessibilityIdentifier("remote.refresh")
            .disabled(status != .connected || model.isManuallyRefreshingContent)
            Menu {
                if model.supportsDraftRegeneration, model.draftRegenerationBatch == nil,
                   model.draftRegenerationCount(for: .all) > 0 {
                    Button(action: onRegenerateDrafts) {
                        Label { Text(.DraftRegeneration.draftRegenerationAllAction) } icon: { CodingProviderIcon() }
                    }
                    .disabled(!model.draftRegenerationIsAvailable || !model.state.canAct(now: now))
                    .accessibilityIdentifier("draft-regeneration.all")
                    Divider()
                }
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
            .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationBoardMenu))
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

extension RemotePhoneModel {
    func draftRegenerationSheet(_ presentation: DraftRegenerationPresentation) -> some View {
        DraftRegenerationSheet(presentation: presentation,
            isAvailable: { self.draftRegenerationIsAvailable && self.state.canAct(now: .now) },
            batch: { self.draftRegenerationBatch }, count: { self.draftRegenerationCount(for: $0) },
            mergeRequestCount: { self.draftRegenerationMergeRequestCount },
            isLoading: { self.draftRegenerationIsLoading }, loadFailed: { self.draftRegenerationLoadFailed },
            reload: { await self.reloadDraftRegeneration() },
            guidanceChoices: supportsDraftRegenerationStyles ? .styles : .none,
            start: { scope, guidance in
                // The phone offers only Mac-defined styles; free-form instructions stay local to the Mac.
                switch guidance {
                case nil: await self.startDraftRegeneration(scope, style: nil)
                case .style(let style)?: await self.startDraftRegeneration(scope, style: style)
                case .instructions?: false
                }
            },
            apply: { await self.applyDraftRegeneration($0, batchID: $1) },
            discard: { await self.discardDraftRegeneration($0) })
    }
}

struct RemoteCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let card: RemoteCard
    var expanded = false
    var branches: RemoteDetailBranches? = nil
    var mergeRequestDescription: String? = nil
    var onOpen: (() -> Void)?
    var onOpenCTA: ((RemoteCardCTA) -> Void)? = nil
    var actionsModel: RemotePhoneModel? = nil
    private var primaryCTA: RemoteCardCTA? { card.primaryCTA.flatMap { $0.duplicatesCardTap ? nil : $0 } }
    private var secondaryCTA: RemoteCardCTA? { card.presentation?.secondaryCTA.flatMap { $0.duplicatesCardTap ? nil : $0 } }
    private var inboxUpdateDate: Date? { expanded ? nil : card.completionObservedAt }
    private var showsDraftStyle: Bool { !expanded && card.presentation?.showsDraftStyle == true }
    private var contentOpacity: Double { showsDraftStyle ? 0.5 : 1 }
    private var draftBadgeTint: Color {
        colorScheme == .dark
            ? Color(red: 0.79, green: 0.70, blue: 0.92)
            : Color(red: 0.38, green: 0.27, blue: 0.52)
    }
    private var directAction: RemoteAction? {
        guard let actionsModel else { return nil }
        let actions = actionsModel.pendingActionCard.flatMap { $0.id == card.id ? $0.actions : nil } ?? card.actions
        return actions.first {
            $0.kind == .finishCommentReview || ($0.kind == .markDone
                && ((card.id.hasPrefix("completion:") && $0.id == "seen")
                    || (card.id.hasPrefix("todo:") && $0.id == "markDone")))
        }
    }
    private var showsActions: Bool {
        !expanded && onOpen != nil && (primaryCTA != nil || secondaryCTA != nil || directAction != nil)
    }
    private var activationTitle: LocalizedStringResource {
        actionsModel != nil && card.reviewSeenAction != nil ? .Board.boardReviewAssignmentSeen : .Board.boardDetails
    }
    private var activation: (() -> Void)? {
        guard let onOpen else { return nil }
        guard let actionsModel else { return onOpen }
        return { Task { await actionsModel.activateCard(card, showDetails: onOpen) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    expandedHeader.frame(maxWidth: .infinity, alignment: .leading)
                    if !card.detail.isEmpty || hasSupportingInformation {
                        VStack(alignment: .leading, spacing: 8) { informationRows }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                compactContent
                if showsActions { HStack { cardActions } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .bottom], 16)
        .padding(.top, expanded ? 16 : 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(contentOpacity),
                    in: RoundedRectangle(cornerRadius: 16))
        .modifier(RemoteCardInteraction(onActivate: activation, title: activationTitle))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote.card.\(card.id)")
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                .opacity(contentOpacity)
                .allowsHitTesting(false)
        }
        .environment(\.gitLabPersonSourceURL, card.url)
    }

    @ViewBuilder
    private var cardActions: some View {
        if let secondary = secondaryCTA {
            if let actionsModel, card.id.hasPrefix("completion:"),
               let action = card.actions.first(where: { $0.id == secondary.actionID && $0.kind == .markDone }) {
                Button {
                    Task { await actionsModel.perform(card: card, action: action) }
                } label: {
                    RemoteActionProgressLabel(running: actionsModel.pendingActionCard?.id == card.id
                        && actionsModel.state.pending?.actionID == action.id) {
                        Text(verbatim: secondary.title)
                    }
                }
                .font(.subheadline.weight(.medium)).buttonStyle(.bordered).controlSize(.large)
                .modifier(RemoteActionAvailability(state: actionsModel.state))
            } else {
                RemoteCardCTAButton(cta: secondary, canAct: { actionsModel?.state.canAct(now: $0) == true },
                                    action: card.actions.first { $0.id == secondary.actionID },
                                    labelHitArea: CardControlHitArea()) { onOpenCTA?(secondary) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("remote.secondary-cta.\(card.id)")
            }
        }
        Spacer(minLength: 0)
        if let action = directAction, let actionsModel {
            let pending = actionsModel.pendingActionCard?.id == card.id ? actionsModel.state.pending : nil
            let seen = action.kind == .markDone
            let todoRead = seen && card.id.hasPrefix("todo:")
            let actionIdentifier = todoRead ? "mark-read" : (seen ? "seen" : "finish-comment-review")
            let button = Button {
                if seen {
                    Task { await actionsModel.perform(card: card, action: action) }
                } else {
                    onOpenCTA?(.init(title: String(localized: .CommentReview.commentReviewFinish),
                        destination: .actions, actionID: action.id))
                }
            } label: {
                RemoteActionProgressLabel(running: pending?.actionID == action.id) {
                    if let label = action.label { Text(verbatim: label) }
                    else if todoRead { Text(.Board.boardEventMarkRead) }
                    else { Text(seen ? .Remote.remoteSeen : .CommentReview.commentReviewFinish) }
                }
            }
            Group {
                if seen && action.label == nil { button.buttonStyle(.bordered).tint(.secondary) }
                else { button.buttonStyle(.borderedProminent) }
            }
            .font(.subheadline.weight(.semibold)).controlSize(.large)
            .modifier(RemoteActionAvailability(state: actionsModel.state))
            .accessibilityIdentifier("remote.\(actionIdentifier).\(card.id)")
        } else if let cta = primaryCTA {
            RemoteCardCTAButton(cta: cta, canAct: { actionsModel?.state.canAct(now: $0) == true },
                action: card.actions.first { $0.id == cta.actionID }) { onOpenCTA?(cta) }
                .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("remote.cta.\(card.id)")
        }
    }
    private var compactContent: some View {
        MRCardMetadataLayout(referenceToTitleSpacing: 11, titleToPeopleSpacing: 6,
                             keepsBadgesUnderActions: card.presentation?.draftBadge != nil && !showsDraftStyle,
                             alignsActionsAtTop: true) {
            repositoryReference
            title.opacity(contentOpacity)
            people
            RemoteCardCornerActions(card: card, model: actionsModel, onOpenAction: onOpenCTA, onShowDetails: onOpen)
                .fixedSize().zIndex(2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let dependencies = card.dependencies {
                    MRDependencyBadge(dependencies: dependencies)
                }
                draftBadge
                if card.boardTraits?.isNew == true {
                    Text(.Board.boardReviewAssignmentNew)
                        .font(.caption.weight(.semibold)).foregroundStyle(.teal)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.teal.opacity(0.14), in: Capsule())
                        .accessibilityIdentifier("remote.review.new.\(card.id)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .zIndex(1)
            informationRows.opacity(contentOpacity)
            if let date = inboxUpdateDate {
                InboxUpdateTimestamp(date: date)
                    .layoutValue(key: MRCardContentSpacing.self, value: 16)
            }
        }
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        repositoryReference
                        draftBadge
                    }
                    Spacer(minLength: 0)
                    if card.pinned != nil || card.orderGroup?.pinned == true {
                        RemoteCardPinButton(card: card, model: actionsModel)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    title
                    people
                    if let branches {
                        Label { Text(verbatim: branches.source + " → " + branches.target) } icon: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(.RemoteDetail.remoteDetailBranches(branches.source, branches.target)))
                    }
                }.opacity(contentOpacity)
            }
            MergeRequestDescription(source: mergeRequestDescription, title: .RemoteDetail.remoteDetailDescription,
                expandHint: .RemoteDetail.remoteDetailExpandDescription, collapseHint: .RemoteDetail.remoteDetailCollapseDescription)
        }
    }
    private var repositoryReference: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if !card.project.isEmpty {
                RemoteRepositoryLabel(name: card.repositoryName, path: card.project, contentOpacity: contentOpacity)
            }
            if let iid = card.mergeRequestIID {
                Text(verbatim: "!\(iid)").monospacedDigit().fixedSize().opacity(contentOpacity)
                if let issues = card.issues, !issues.isEmpty { MRIssueTag(issues: issues) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder
    private var author: some View {
        if let presentation = card.presentation, presentation.author != nil {
            PersonLabel(person: .init(name: presentation.author, username: presentation.authorUsername,
                                      avatarURL: presentation.authorAvatarURL))
                .font(.caption).foregroundStyle(.secondary)
                .opacity(contentOpacity)
        }
    }
    @ViewBuilder private var people: some View {
        HStack(spacing: 0) {
            author
            Spacer(minLength: 16)
            approvalBadge
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
    @ViewBuilder
    private var draftBadge: some View {
        if let badge = card.presentation?.draftBadge {
            let tint = showsDraftStyle ? draftBadgeTint : Color.secondary
            Text(verbatim: badge).fontWeight(.medium)
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint.opacity(showsDraftStyle ? 0.1 : 0.08), in: Capsule())
        }
    }
    @ViewBuilder
    private var approvalBadge: some View {
        if card.id.hasPrefix("mr:") {
            RemoteApprovalProgressBadge(progress: card.approvals, people: card.presentation?.approvalPeople,
                viewerApprovalID: card.presentation?.viewerApprovalID,
                assignedReviewerCount: card.presentation?.assignedReviewerCount,
                approvedWithOpenFindings: card.presentation?.approvedWithOpenFindings == true,
                personalApproval: card.personalApprovalControl(model: actionsModel),
                reviewerEditing: card.reviewerEditing(model: actionsModel),
                automaticApprovalOff: card.presentation?.automaticApprovalOff == true)
        }
    }
    private var visibleStatus: String? { expanded ? card.visibleStatus : card.boardStatus }
    private var visibleNextStep: String? { expanded ? card.visibleNextStep : card.boardNextStep }
    private var hasSupportingInformation: Bool {
        card.presentation?.requirements?.isEmpty == false || visibleStatus != nil
            || card.presentation?.pendingDrafts != nil || (expanded && card.dependencies != nil)
            || card.presentation?.steps?.isEmpty == false || visibleNextStep != nil
            || !(card.presentation?.chips.isEmpty ?? card.drafts.isEmpty)
    }
    private var informationRows: some View {
        Group {
            if !card.detail.isEmpty {
                if card.needsAttention == true {
                    MergeRequestAttentionCallout(message: card.detail)
                        .font((expanded ? Font.callout : .subheadline).weight(.medium))
                        .lineLimit(expanded ? nil : 2)
                        .padding(.bottom, hasSupportingInformation ? 8 : 0)
                } else {
                    Text(verbatim: card.detail)
                        .font(expanded ? .callout : .subheadline)
                        .lineLimit(expanded ? nil : 2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(MRDetailStatusCard(isPresented: expanded))
                }
            }
            if let requirements = card.presentation?.requirements, !requirements.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(requirements.enumerated()), id: \.offset) { index, line in
                        if index == 0, let message = requirementPeopleMessage {
                            WaitingPeopleLabel(message: message).foregroundStyle(.primary)
                        } else {
                            Label { Text(verbatim: line).foregroundStyle(.primary) } icon: {
                                Image(systemName: "lock").foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.subheadline)
                .modifier(MRDetailStatusCard(isPresented: expanded))
            } else if let status = visibleStatus {
                HStack(spacing: 5) {
                    if card.presentation?.working == true {
                        ProgressView().controlSize(.mini)
                        if let symbol = card.presentation?.statusSymbol {
                            if symbol == "sparkles" || symbol == "sparkle.magnifyingglass" {
                                CodingProviderIcon()
                            } else {
                                Image(systemName: symbol).accessibilityHidden(true)
                            }
                        }
                    }
                    if let message = card.presentation?.statusPeopleMessage {
                        PeopleMessageLabel(message: message).font(.subheadline)
                    } else {
                        Text(verbatim: status).font(.subheadline)
                    }
                }
                .foregroundStyle(.secondary)
                .modifier(MRDetailStatusCard(isPresented: expanded))
            }
            if let drafts = card.presentation?.pendingDrafts {
                Label {
                    Group {
                        if let message = card.presentation?.pendingDraftsPeopleMessage { PeopleMessageLabel(message: message) }
                        else { Text(verbatim: drafts) }
                    }.foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "text.bubble").foregroundStyle(.secondary)
                }
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if expanded, let dependencies = card.dependencies { RemoteMRDependencyRow(dependencies: dependencies) }
            if let steps = card.presentation?.steps, !steps.isEmpty {
                RemoteStepChain(steps: steps, current: card.presentation?.currentStep ?? 0)
                    .font(expanded ? .callout : .caption)
            } else if let nextStep = visibleNextStep {
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
        }
    }
    private var requirementPeopleMessage: RemotePeopleMessage? {
        if let message = card.presentation?.requirementPeopleMessage { return message }
        guard let people = card.presentation?.threadResolutionPeople else { return nil }
        return .init(.AuthorFeedback.authorFeedbackThreadResolutionWait, people: people.map(PersonIdentity.init))
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
private struct RemoteRepositoryLabel: View {
    let name: String
    let path: String
    let contentOpacity: Double
    @State private var showingPath = false

    var body: some View {
        Button { showingPath = true } label: {
            Text(verbatim: name)
                .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.tint)
                .opacity(contentOpacity)
                .contentShape(.interaction, CardControlHitArea(anchor: .bottom))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(.Remote.remoteShowRepositoryPath))
        .popover(isPresented: $showingPath) {
            Text(verbatim: path).font(.callout.monospaced()).textSelection(.enabled)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct RemoteMRDependencyRow: View {
    let dependencies: RemoteMRDependencies
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct RemoteCardInteraction: ViewModifier {
    let onActivate: (() -> Void)?
    let title: LocalizedStringResource
    @ViewBuilder func body(content: Content) -> some View {
        if let onActivate {
            content.contentShape(Rectangle())
                .onTapGesture(perform: onActivate)
                .accessibilityAction(named: Text(title), onActivate)
        } else { content }
    }
}
