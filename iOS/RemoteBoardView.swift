import SwiftUI
import MergeTetherRemote

struct RemoteBoardView: View {
    @Bindable var model: RemotePhoneModel
    @Environment(CrashReporting.self) private var crashReporting
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pairingSheet = false
    @State private var selected: RemoteCardSelection?
    @State private var showingInbox = false
    @State private var settingsRoute: RemoteSettingsRoute?
    @State private var pendingSettingsAction: RemoteSettingsAction?
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
                            model: model, hiddenReviews: board.hiddenReviews ?? [],
                            onRefresh: { await model.refreshContent() })
                        if let updated = board.updatedAt {
                            HStack { Text(.Remote.remoteUpdated); Text(updated, style: .relative) }
                                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 4)
                        }
                    }
                } else {
                    RemoteDeadlineTimeline(nextChange: model.nextConnectionChange(after:)) { now in
                        let status = model.connectionStatus(now: now)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if crashReporting.needsConsent {
                    RemoteCrashReportingPrompt(
                        onReview: { settingsRoute = .crashReporting },
                        onDecline: { crashReporting.setEnabled(false) }
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.error && !model.paired { Text(.Remote.remoteError).font(.caption).foregroundStyle(.red).padding() }
            }
            .navigationTitle(Text(.Remote.remoteTitle)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.paired {
                        inboxButton
                        RemoteBoardRefreshButton(model: model)
                    }
                    Button { settingsRoute = .general } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text(.CrashReporting.crashReportingSettings))
                        .accessibilityIdentifier("remote.settings")
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
            .sheet(item: $settingsRoute, onDismiss: handleSettingsAction) { route in
                RemoteSettingsView(model: model, route: route, onAction: { pendingSettingsAction = $0 })
            }
            .onChange(of: model.pairingRevision) {
                pairingSheet = false; selected = nil; showingInbox = false; pendingInboxCard = nil
                regenerationPresentation = nil
            }
            .onChange(of: model.state.board?.account) { _, _ in
                selected = nil
                regenerationPresentation = nil
            }
            .popover(isPresented: $showingInbox, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                RemoteInboxView(cards: model.state.inboxCards,
                    onRetry: retryInbox,
                    onOpen: { pendingInboxCard = .init(card: $0); showingInbox = false },
                    onOpenCTA: { pendingInboxCard = .init(card: $0, cta: $1); showingInbox = false },
                    model: model,
                    onRefresh: { await model.refreshContent() })
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
                get: { selected == nil && !showingInbox && model.state.result != nil },
                set: { if !$0, selected == nil, !showingInbox { model.state.acknowledgeResult() } }
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

    private var inboxButton: some View {
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
    }

    private func handleSettingsAction() {
        defer { pendingSettingsAction = nil }
        switch pendingSettingsAction {
        case .pair: pairingSheet = true
        case .regenerateDrafts: regenerationPresentation = .init(scope: .all)
        case nil: break
        }
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
        RemoteDeadlineTimeline(nextChange: model.nextConnectionChange(after:)) { now in
            let status = model.connectionStatus(now: now)
            let refreshing = model.isLoadingBoard(now: now)
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
    let state: RemotePhoneState?
    var action: RemoteAction? = nil
    var running = false
    var usesPlainLabel = false
    let onTap: () -> Void

    var body: some View {
        if cta.actionID != nil {
            if let state {
                RemoteDeadlineTimeline(nextChange: state.nextTimeChange(after:)) { now in
                    button.disabled(!state.canAct(now: now))
                }
            } else { button.disabled(true) }
        } else { button }
    }

    private var button: some View {
        Button(role: action?.kind == .stopJob ? .destructive : nil, action: onTap) {
            let label = RemoteActionProgressLabel(running: running) {
                RemoteActionLabel(action: action, title: Text(verbatim: cta.title))
            }
            if usesPlainLabel {
                label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            } else {
                label
            }
        }
    }
}

// TimelineView inside ToolbarItem causes a continuous toolbar preference-update loop.
private struct RemoteBoardRefreshButton: View {
    let model: RemotePhoneModel
    @State private var now = Date()

    var body: some View {
        Button { Task { await model.refreshContent(fromGitLab: true) } } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel(Text(.Remote.remoteRefreshGitLabBoard))
        .accessibilityIdentifier("remote.refresh")
        .disabled(model.connectionStatus(now: now) != .connected || model.isManuallyRefreshingContent)
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
    private var claimIsPrimary: Bool {
        card.actions.contains { $0.kind == .claimAssignment && $0.id == primaryCTA?.actionID }
    }
    private var secondaryCTA: RemoteCardCTA? { card.presentation?.secondaryCTA.flatMap { $0.duplicatesCardTap ? nil : $0 } }
    private var additionalCTAs: [RemoteCardCTA] { (card.presentation?.additionalCTAs ?? []).filter { !$0.duplicatesCardTap } }
    private var statusContext: RemoteCardStatusContext? { card.presentation?.statusContext }
    private var gitLabCheckURL: URL? { statusContext?.checkGitLab == true ? card.url : nil }
    private var trainConflictURL: URL? {
        guard let url = statusContext?.trainConflictNoteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = parts.fragment, fragment.hasPrefix("note_"),
              let noteID = Int(fragment.dropFirst("note_".count)), noteID > 0 else { return nil }
        parts.fragment = nil
        return parts.url == card.url ? url : nil
    }
    private var inboxUpdateDate: Date? { expanded ? nil : card.completionObservedAt }
    private var showsDraftStyle: Bool { !expanded && card.presentation?.showsDraftStyle == true }
    static let dimmedOpacity = 0.5
    private var contentOpacity: Double { showsDraftStyle ? Self.dimmedOpacity : 1 }
    private var draftBadgeTint: Color {
        colorScheme == .dark
            ? Color(red: 0.79, green: 0.70, blue: 0.92)
            : Color(red: 0.38, green: 0.27, blue: 0.52)
    }
    private var directAction: RemoteAction? {
        guard let actionsModel else { return nil }
        let actions = actionsModel.pendingActionCard.flatMap { $0.id == card.id ? $0.actions : nil } ?? card.actions
        let boundIDs = [primaryCTA, secondaryCTA].compactMap { $0?.actionID } + additionalCTAs.compactMap(\.actionID)
        return actions.first {
            ($0.kind == .finishCommentReview && !boundIDs.contains($0.id)) || ($0.kind == .markDone
                && ((card.id.hasPrefix("completion:") && $0.id == "seen")
                    || (card.id.hasPrefix("todo:") && $0.id == "markDone")))
        }
    }
    private var actionCount: Int {
        let individualActions = [primaryCTA != nil, secondaryCTA != nil, directAction != nil, gitLabCheckURL != nil]
        return individualActions.filter { $0 }.count + additionalCTAs.count
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
                let count = onOpen == nil ? 0 : actionCount
                if count > 0 {
                    VStack(spacing: 8) { cardActions }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: count > 1 ? .center : .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
        if let cta = primaryCTA { boardCTA(cta, prominent: claimIsPrimary) }
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
                RemoteCardCTAButton(cta: secondary, state: actionsModel?.state,
                                    action: card.actions.first { $0.id == secondary.actionID },
                                    usesPlainLabel: true) { onOpenCTA?(secondary) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("remote.secondary-cta.\(card.id)")
            }
        }
        ForEach(Array(additionalCTAs.enumerated()), id: \.offset) { _, cta in boardCTA(cta) }
        if let gitLabCheckURL { gitLabCheckLink(gitLabCheckURL) }
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
                else if claimIsPrimary { button.buttonStyle(.bordered) }
                else { button.buttonStyle(.borderedProminent) }
            }
            .font(.subheadline.weight(.semibold)).controlSize(.large)
            .modifier(RemoteActionAvailability(state: actionsModel.state))
            .accessibilityIdentifier("remote.\(actionIdentifier).\(card.id)")
        }
    }

    private func boardCTA(_ cta: RemoteCardCTA, prominent: Bool = false) -> some View {
        let pending = actionsModel?.pendingActionCard.flatMap { $0.id == card.id ? $0.actions : nil }
        let action = (pending ?? card.actions).first { $0.id == cta.actionID }
        let button = RemoteCardCTAButton(cta: cta, state: actionsModel?.state,
            action: action, running: action != nil && pending != nil && actionsModel?.state.pending?.actionID == action?.id) {
                if let actionsModel, let action, action.id == RemoteAction.finishedSeenID {
                    Task { await actionsModel.perform(card: card, action: action) }
                } else { onOpenCTA?(cta) }
            }
        return Group {
            if prominent { button.buttonStyle(.borderedProminent) }
            else { button.buttonStyle(.bordered) }
        }
        .font(.subheadline.weight(.semibold)).controlSize(.large)
        .accessibilityIdentifier(action?.kind == .finishCommentReview
            ? "remote.finish-comment-review.\(card.id)" : "remote.cta.\(card.id)")
    }

    private func gitLabCheckLink(_ url: URL) -> some View {
        Link(destination: url) { Text(.MergeActions.mergeActionsCheckGitLab) }
            .font(.subheadline).buttonStyle(.bordered).controlSize(.large)
    }
    private var compactContent: some View {
        MRCardMetadataLayout(referenceToTitleSpacing: 11, titleToPeopleSpacing: 6,
                             keepsBadgesUnderActions: card.presentation?.draftBadge != nil && !showsDraftStyle,
                             placesTitleBelowActions: true) {
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
                if let issues = card.issues, !issues.isEmpty { MRIssueTag(issues: issues, mergeRequestURL: card.url) }
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
            HStack(spacing: 6) {
                author
                if let assignees = card.presentation?.assignees {
                    BoardAssigneesBadge(assignees: assignees.map(PersonIdentity.init), contentOpacity: contentOpacity)
                }
            }
            Spacer(minLength: 16)
            approvalBadge
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
    @ViewBuilder
    private var draftBadge: some View {
        if let badge = card.presentation?.draftBadge {
            let tint = statusContext?.finished == .merged ? Color.green : (showsDraftStyle ? draftBadgeTint : .secondary)
            Text(verbatim: badge).fontWeight(.medium)
                .foregroundStyle(tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint.opacity(showsDraftStyle ? 0.1 : 0.08), in: Capsule())
        }
    }
    @ViewBuilder
    private var approvalBadge: some View {
        if card.id.hasPrefix("mr:"), statusContext?.finished == nil {
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
    private var displayedStatus: String? {
        guard card.presentation?.requirements?.isEmpty != false,
              let status = visibleStatus, status != statusContext?.mergeStage?.title,
              trainConflictURL == nil || card.presentation?.working == true || statusContext?.refreshFailureHelp != nil
        else { return nil }
        return status
    }
    private var hasSupportingInformation: Bool {
        card.presentation?.requirements?.isEmpty == false || visibleStatus != nil
            || card.presentation?.pendingDrafts != nil || (expanded && card.dependencies != nil)
            || card.presentation?.steps?.isEmpty == false || visibleNextStep != nil
            || !(card.presentation?.chips.isEmpty ?? card.drafts.isEmpty)
            || statusContext?.mergeStage != nil || statusContext?.notices?.isEmpty == false
            || (expanded && gitLabCheckURL != nil)
    }
    private var informationRows: some View {
        let status = displayedStatus
        let explanation = status != nil && card.presentation?.nextStepExplainsStatus == true
            && card.presentation?.steps?.isEmpty != false ? visibleNextStep : nil
        return Group {
            if let stage = statusContext?.mergeStage {
                mergeStage(stage)
            }
            if !card.detail.isEmpty, card.detail != trainConflictURL?.absoluteString {
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
            } else if let status {
                VStack(alignment: .leading, spacing: 4) {
                    statusLine(status)
                    if let explanation { nextStepText(explanation) }
                }
            }
            if let trainConflictURL {
                Link(destination: trainConflictURL) {
                    Label(.MergeActions.mergeActionsTrainRebaseConflict, systemImage: "arrow.triangle.branch")
                }
                .font(.subheadline).foregroundStyle(.orange)
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
            } else if explanation == nil, let nextStep = visibleNextStep {
                nextStepText(nextStep)
            }
            if let chips = card.presentation?.chips {
                let notices = statusContext?.notices ?? []
                if !chips.isEmpty || !notices.isEmpty {
                    StatusFlowLayout(spacing: 5) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in statusChip(chip, tint: .secondary) }
                        ForEach(Array(notices.enumerated()), id: \.offset) { _, chip in statusChip(chip, tint: .orange) }
                    }
                }
            } else if !card.drafts.isEmpty, card.presentation?.pendingDrafts == nil {
                Label(.Remote.remoteComments, systemImage: "text.bubble").font(.caption).foregroundStyle(.tint)
            }
            if expanded, let gitLabCheckURL { gitLabCheckLink(gitLabCheckURL) }
        }
    }

    private func nextStepText(_ text: String) -> some View {
        Text(verbatim: text).font(expanded ? .callout : .caption).foregroundStyle(.secondary)
    }

    private func statusLine(_ status: String) -> some View {
        let working = card.presentation?.working == true
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if working { ProgressView().controlSize(.mini) }
                if let symbol = card.presentation?.statusSymbol {
                    if symbol == "sparkles" || symbol == "sparkle.magnifyingglass" {
                        CodingProviderIcon()
                    } else {
                        Image(systemName: symbol).accessibilityHidden(true)
                    }
                }
                if let message = card.presentation?.statusPeopleMessage {
                    PeopleMessageLabel(message: message)
                } else {
                    activityText(status, since: working ? statusContext?.activityStartedAt : nil)
                }
            }
            if working, let detail = statusContext?.activityDetail {
                Text(verbatim: detail).font(.caption)
            }
            if expanded, let help = statusContext?.refreshFailureHelp {
                Text(verbatim: help).font(.caption).textSelection(.enabled)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .modifier(MRDetailStatusCard(isPresented: expanded))
    }

    private func activityText(_ status: String, since startedAt: Date?) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: status)
            if let startedAt { Text(startedAt, style: .timer).monospacedDigit() }
        }
    }

    private func mergeStage(_ stage: RemoteCardStatusContext.MergeStage) -> some View {
        let tint: Color = switch stage.kind {
        case .merging: .green
        case .inTrain: .indigo
        case .queued: .blue
        }
        return HStack(spacing: 6) {
            if stage.kind == .merging {
                ProgressView().controlSize(.mini)
                activityText(stage.title, since: stage.startedAt)
            } else {
                Label { Text(verbatim: stage.title) } icon: {
                    Image(systemName: stage.kind == .inTrain ? "tram.fill" : "clock").foregroundStyle(tint)
                }
            }
        }
        .font(.callout.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private func statusChip(_ chip: RemoteCardChip, tint: Color) -> some View {
        Label { Text(verbatim: chip.title) } icon: { Image(systemName: chip.symbol) }
            .font(.caption).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.08), in: Capsule())
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
