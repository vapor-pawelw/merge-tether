import AppKit
import MergeTetherRemote
import SwiftUI

struct CommandCenterBoardView: View {
    let monitor: TodoMonitorService
    let board: MergeRequestBoardSnapshot
    var refreshState: BoardRefreshState = .current
    @Binding var questionMergeRequest: URL?
    private var dimUnverifiedContent: Bool { refreshState != .current }
    private var usesManualOrder: Bool { monitor.settings.boardOrderingMethod == .manual }
    private static let boardLeadingInset: CGFloat = 10
    private static let laneScrollerGutter: CGFloat = 18

    private enum Lane: Hashable {
        case own, reviewing

        func title(count: Int) -> LocalizedStringResource {
            self == .own ? .Board.boardLaneOwn(count) : .Board.boardLaneReviewing(count)
        }

        var symbol: String { self == .own ? "arrow.triangle.pull" : "text.magnifyingglass" }

        var cardFilters: [MRBoardLaneFilter.Card] {
            switch self {
            case .own: [.needsAttention, .pinned]
            case .reviewing: [.needsAttention, .new, .pinned]
            }
        }
    }

    private struct Selection: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let section: CommandCenterMRDetailSection
        let account: GlabService.AuthedHost?
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
    }
    enum LaneEntry: Identifiable {
        enum ID: Hashable {
            case card(MergeRequestAttentionMonitor.Item.ID)
            case hiddenCard(MRAutomationScope.Target, hideID: UUID?)
            case automationOn(startingAt: MergeRequestAttentionMonitor.Item.ID)
            case automationOff, hidden
        }

        case card(MergeRequestBoardSnapshot.Row, startsDrafts: Bool)
        case automationOn(startingAt: MergeRequestAttentionMonitor.Item.ID)
        case automationOff(count: Int, attentionCount: Int)
        case hidden(count: Int)
        case hiddenCard(HiddenReview)

        var id: ID {
            switch self {
            case let .card(row, _): .card(row.id)
            case let .automationOn(firstCardID): .automationOn(startingAt: firstCardID)
            case .automationOff: .automationOff
            case .hidden: .hidden
            case let .hiddenCard(review): .hiddenCard(review.target, hideID: review.hideID)
            }
        }
    }
    @State private var selected: Selection?
    @State private var compactLane: Lane = .own
    @State private var laneFilters: [Lane: MRBoardLaneFilter] = [:]
    @State private var hiddenExpanded = false
    @State private var detailPopoverPresented = false
    @State private var dragSession = BoardDragSession<BoardCardDrag>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var account: GlabService.AuthedHost? {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return nil }
        return .init(host: host, username: username)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            let laneCount: CGFloat = compact ? 1 : 2
            let contentWidth = max(320, (geometry.size.width - Self.boardLeadingInset) / laneCount - Self.laneScrollerGutter)
            HStack(alignment: .top, spacing: 0) {
                if compact {
                    lane(compactLane, contentWidth: contentWidth, leadingInset: Self.boardLeadingInset, compact: true)
                } else {
                    lane(.own, contentWidth: contentWidth, leadingInset: Self.boardLeadingInset)
                    lane(.reviewing, contentWidth: contentWidth, leadingInset: 0)
                }
            }
            .id(account)
            .padding(.vertical, 14)
            .sheet(item: $selected) { selection in
                detailSheet(selection, availableWidth: max(1, geometry.size.width - 24))
            }
        }
        .background(Color(white: colorScheme == .dark ? 0.095 : 0.99))
        .onChange(of: questionMergeRequest) { _, url in
            guard let url else { return }
            questionMergeRequest = nil
            if let row = (board.own + board.reviewed + board.otherMergeRequests).first(where: { $0.displayURL == url }) {
                selected = Selection(item: row.item, section: .overview, account: account)
            }
        }
        .onChange(of: account) { _, _ in
            selected = nil
            laneFilters.removeAll()
            hiddenExpanded = false
            dragSession.finish()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { selected = nil }
        }
        .task {
            await monitor.attention.observePendingDrafts()
        }
    }

    private func detailSheet(_ selection: Selection, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.section.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(detailPopoverPresented)
                    .accessibilityLabel(Text(.CommandCenter.commandCenterClose))
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if selection.account == account {
                CommandCenterMRDetail(item: selection.item, monitor: monitor, initialSection: selection.section)
                    .id(selection.id)
            }
        }
        .frame(minWidth: min(700, availableWidth), idealWidth: min(820, availableWidth), maxWidth: availableWidth,
               minHeight: 600, idealHeight: 780)
        .interactiveDismissDisabled(detailPopoverPresented)
        .onPreferenceChange(BoardDetailPopoverPresentedKey.self) { detailPopoverPresented = $0 }
    }

    @ViewBuilder private func card(_ row: MergeRequestBoardSnapshot.Row, removable: Bool) -> some View {
        let content = CommandCenterMRCard(row: row, monitor: monitor, allowsRemoval: removable, onAttention: { section in
            selected = Selection(item: row.item, section: section, account: account)
        }, onDetails: {
            selected = Selection(item: row.item, section: .overview, account: account)
        })
        if let entry = row.manualOrderEntry, refreshState == .current {
            let drag = BoardCardDrag(entry: entry, accountRevision: monitor.glab.accountRevision)
            content
                .contentShape([.interaction, .dragPreview], RoundedRectangle(cornerRadius: 8))
                .onDrag { dragSession.begin(drag, type: BoardCardDrag.type) }
                .accessibilityHint(Text(.BoardActivity.reorderCard))
                .padding(.vertical, 5)
                .modifier(dropTarget(at: entry.target))
        } else {
            content.padding(.vertical, 5)
        }
    }

    private func dropTarget(at anchor: MRAutomationScope.Target, fixedInsertion: BoardOrderInsertion? = nil) -> BoardInsertionDrop {
        func destination(_ insertion: BoardOrderInsertion) -> MRAutomationScope.Target? {
            guard refreshState == .current, let source = dragSession.source,
                  source.accountRevision == monitor.glab.accountRevision else { return nil }
            return source.destination(beside: anchor, insertion: insertion, in: monitor.boardSnapshot.manualOrderEntries)
        }
        return .init(type: BoardCardDrag.type, fixedInsertion: fixedInsertion, allows: { destination($0) != nil }, move: {
            guard let source = dragSession.source, let target = destination($0) else { return false }
            defer { dragSession.finish() }
            return monitor.moveBoardCard(source.entry.target, to: target, accountRevision: source.accountRevision)
        })
    }

    static func laneEntries(_ rows: [MergeRequestBoardSnapshot.Row], automationOffExpanded: Bool,
                            showsAutomationOn: Bool = false,
                            hiddenReviews: [HiddenReview] = [], hiddenExpanded: Bool = false,
                            activity: (MergeRequestBoardSnapshot.Row) -> MRBoardActivity.Group,
                            hasHumanAction: (MergeRequestBoardSnapshot.Row) -> Bool) -> [LaneEntry] {
        let groupedRows = rows.map { (row: $0, group: activity($0)) }
        let inactiveRows = groupedRows.compactMap { $0.group == .inactive ? $0.row : nil }
        var entries: [LaneEntry] = []
        var addedAutomationOffHeader = false
        var previousGroup: MRBoardActivity.Group?
        for (row, group) in groupedRows {
            defer { previousGroup = group }
            if showsAutomationOn, group == .regular, previousGroup != .regular {
                entries.append(.automationOn(startingAt: row.id))
            }
            if group == .inactive, !addedAutomationOffHeader {
                let attentionCount = inactiveRows.count { $0.needsAttention && hasHumanAction($0) }
                entries.append(.automationOff(count: inactiveRows.count, attentionCount: attentionCount))
                addedAutomationOffHeader = true
            }
            guard group != .inactive || automationOffExpanded else { continue }
            entries.append(.card(row, startsDrafts: group == .drafts && previousGroup != .drafts))
        }
        if !hiddenReviews.isEmpty {
            entries.append(.hidden(count: hiddenReviews.count))
            if hiddenExpanded { entries.append(contentsOf: hiddenReviews.map(LaneEntry.hiddenCard)) }
        }
        return entries
    }

    private func laneCards(_ rows: [MergeRequestBoardSnapshot.Row], removable: Bool,
                           automationOffExpanded: Binding<Bool>?, hiddenReviews: [HiddenReview],
                           viewportHeight: CGFloat) -> some View {
        let entries = Self.laneEntries(rows, automationOffExpanded: automationOffExpanded?.wrappedValue ?? true,
            showsAutomationOn: usesManualOrder, hiddenReviews: hiddenReviews, hiddenExpanded: hiddenExpanded,
            activity: activity) { row in
            MRCardPresentation(row: row, monitor: monitor, allowsRemoval: removable).humanAction != nil
        }
        let lastBoardEntry = entries.last { entry in
            switch entry {
            case .hidden, .hiddenCard: false
            default: true
            }
        }
        return VStack(spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                laneEntries(entries, removable: removable, automationOffExpanded: automationOffExpanded)
            }
            if case let .card(row, _)? = lastBoardEntry, let target = row.manualOrderEntry?.target {
                Spacer(minLength: 16)
                    .frame(maxWidth: .infinity)
                    .modifier(dropTarget(at: target, fixedInsertion: .after))
            }
        }
        .frame(minHeight: viewportHeight, alignment: .topLeading)
    }

    private func laneEntries(_ entries: [LaneEntry], removable: Bool, automationOffExpanded: Binding<Bool>?) -> some View {
        // Keep SwiftUI's identity lookups from copying the full row payload during layout.
        let positions = entries.indices.map { (index: $0, id: entries[$0].id) }
        return ForEach(positions, id: \.id) { position in
            let index = position.index
            switch entries[index] {
            case let .card(row, startsDrafts):
                VStack(spacing: 10) {
                    if startsDrafts {
                        sectionHeading(.DraftMR.sectionTitle)
                            .padding(.top, index == 0 ? 2 : 14)
                            .padding(.horizontal, 4)
                    }
                    card(row, removable: removable)
                }
                .transition(cardTransition)
            case .automationOn:
                let heading = sectionHeading(.BoardActivity.activeSection)
                    .padding(.top, index == 0 ? 2 : 14)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 5)
                dropBeforeNextCard(heading, entries: entries, index: index)
            case let .automationOff(count, attentionCount):
                let title = sectionHeading(.BoardActivity.inactiveSection(count), attentionCount: attentionCount)
                let heading = Group {
                    if let automationOffExpanded {
                        MRDetailDisclosureButton(isExpanded: automationOffExpanded) { title }
                    } else {
                        title
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, index == 0 ? 2 : 14)
                .padding(.horizontal, 4)
                .padding(.bottom, 5)
                dropBeforeNextCard(heading, entries: entries, index: index)
            case let .hidden(count):
                MRDetailDisclosureButton(isExpanded: $hiddenExpanded) {
                    sectionHeading(.BoardActivity.hiddenSection(count))
                }
                .foregroundStyle(.secondary)
                .padding(.top, index == 0 ? 2 : 14)
                .padding(.horizontal, 4)
                .padding(.bottom, 5)
            case let .hiddenCard(review):
                BoardHiddenAssignmentCard(review: review, monitor: monitor)
                    .padding(.vertical, 5)
                    .transition(cardTransition)
            }
        }
    }

    @ViewBuilder private func dropBeforeNextCard<Heading: View>(_ heading: Heading, entries: [LaneEntry], index: Int) -> some View {
        if entries.indices.contains(index + 1), case let .card(row, _) = entries[index + 1],
           let target = row.manualOrderEntry?.target {
            heading.modifier(dropTarget(at: target, fixedInsertion: .before))
        } else {
            heading
        }
    }

    private func activity(_ row: MergeRequestBoardSnapshot.Row) -> MRBoardActivity.Group {
        monitor.boardActivityGroup(for: row)
    }

    private func isPinned(_ row: MergeRequestBoardSnapshot.Row) -> Bool {
        guard let pin = BoardCardPin.mergeRequest(host: account?.host, username: account?.username,
            projectID: row.id.projectID, iid: row.id.iid) else { return false }
        return monitor.settings.boardPins.contains(pin)
    }

    private func sectionHeading(_ title: LocalizedStringResource, attentionCount: Int = 0) -> some View {
        HStack(spacing: 10) {
            Text(title).monospacedDigit()
            if attentionCount > 0 {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(.BoardActivity.attentionCount(attentionCount))
                    .foregroundStyle(.orange)
            }
            Rectangle().fill(.secondary.opacity(0.16)).frame(height: 0.5).accessibilityHidden(true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func visibleRows(in lane: Lane, matching selection: MRBoardLaneFilter) -> [MergeRequestBoardSnapshot.Row] {
        let allRows = lane == .reviewing ? board.reviewed : board.own
        guard selection.isActive else { return allRows }
        return allRows.filter { row in
            selection.matches(row, activity: activity(row), isPinned: isPinned(row),
                              isNew: lane == .reviewing && monitor.isNewReviewAssignment(row))
        }
    }

    private func lane(_ lane: Lane, contentWidth: CGFloat, leadingInset: CGFloat, compact: Bool = false) -> some View {
        let reviewing = lane == .reviewing
        let filter = Binding(get: { laneFilters[lane] ?? .init() }, set: { laneFilters[lane] = $0 })
        let selection = filter.wrappedValue
        let rows = visibleRows(in: lane, matching: selection)
        let cardIDs = rows.map(\.id)
        let hiddenReviews = reviewing ? monitor.hiddenReviewAssignments : []
        let settings = monitor.settings
        let expansionKey = reviewing ? \SettingsManager.reviewingAutomationOffExpanded : \SettingsManager.ownAutomationOffExpanded
        let automationOffExpanded = Binding(
            get: { settings[keyPath: expansionKey] },
            set: { expanded in
                settings[keyPath: expansionKey] = expanded
                settings.save()
            }
        )
        let animation: Animation? = reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    if compact {
                        Picker(selection: $compactLane) {
                            ForEach([Lane.own, .reviewing], id: \.self) { candidate in
                                let count = candidate == lane ? rows.count
                                    : visibleRows(in: candidate, matching: laneFilters[candidate] ?? .init()).count
                                Text(candidate.title(count: count)).tag(candidate)
                            }
                        } label: { Text(.Board.boardTitle) }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("command-center.board-lane")
                    } else {
                        Label { Text(lane.title(count: rows.count)).monospacedDigit() } icon: { Image(systemName: lane.symbol) }
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    BoardLaneFilterButton(selection: filter, cardChoices: lane.cardFilters)
                }
                .padding(.horizontal, 6).padding(.vertical, 10)
                Divider()
            }
            .frame(width: contentWidth)
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { viewport in
                ScrollView {
                    VStack {
                        if rows.isEmpty && (hiddenReviews.isEmpty || selection.isActive || refreshState != .current) {
                            if selection.isActive, refreshState == .current {
                                Text(.Board.boardFiltersEmpty).foregroundStyle(.secondary).padding()
                            } else {
                                empty(reviewing ? .Board.boardEmptyReviewingTitle : .Board.boardEmptyOwnTitle,
                                      message: reviewing ? .Board.boardLaneReviewingEmpty : .Board.boardLaneOwnEmpty,
                                      symbol: lane.symbol)
                            }
                        }
                        if !rows.isEmpty || !hiddenReviews.isEmpty {
                            laneCards(rows, removable: reviewing,
                                automationOffExpanded: selection.isActive ? nil : automationOffExpanded,
                                hiddenReviews: hiddenReviews,
                                viewportHeight: rows.isEmpty ? 0 : max(0, viewport.size.height - 10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5).padding(.horizontal, 1)
                                .opacity(dimUnverifiedContent ? 0.55 : 1)
                                .animation(animation, value: cardIDs)
                                .animation(animation, value: rows.map { $0.item.dependencies })
                                .animation(animation, value: automationOffExpanded.wrappedValue)
                                .animation(animation, value: hiddenExpanded)
                        }
                    }
                    .frame(width: contentWidth)
                    .padding(.leading, leadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .id(lane)
        }
        .frame(width: contentWidth + leadingInset + Self.laneScrollerGutter)
        .frame(maxHeight: .infinity)
    }

    private func empty(_ title: LocalizedStringResource, message: LocalizedStringResource, symbol: String) -> some View {
        VStack(spacing: 12) {
            if refreshState == .syncing {
                ProgressView().controlSize(.small)
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.08)).frame(width: 44, height: 44)
                    Image(systemName: refreshState == .unavailable ? "arrow.clockwise" : symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            VStack(spacing: 6) {
                Text(refreshState == .syncing ? .Board.boardEmptyLoadingTitle
                     : refreshState == .unavailable ? .Board.boardEmptyUnavailableTitle : title)
                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                if refreshState != .syncing {
                    Text(refreshState == .unavailable ? .Board.boardEmptyUnavailableDescription : message)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 48)
        .frame(maxWidth: .infinity, minHeight: 210)
        .transition(cardTransition)
    }
}
