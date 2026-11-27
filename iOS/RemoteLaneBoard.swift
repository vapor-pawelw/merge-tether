import SwiftUI
import MergeTetherRemote

struct RemoteLaneBoard: View {
    let lanes: [RemoteLane]
    let onOpen: (RemoteCard) -> Void
    let onOpenCTA: (RemoteCard, RemoteCardCTA) -> Void
    let model: RemotePhoneModel
    let hiddenReviews: [RemoteCard]
    var onRefresh: (() async -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibleLane: RemoteLaneID?
    @State private var dragSession = BoardDragSession<RemoteBoardOrderMove.Source>()
    @State private var filters: [RemoteLaneID: RemoteBoardLaneFilter] = [:]

    private var supportsReviewBoard: Bool {
        model.state.board?.hiddenReviews != nil || lanes.contains { $0.cards.contains { $0.boardTraits != nil } }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 700
            let showsLaneSwitch = compact && lanes.count > 1
            VStack(spacing: 8) {
                if showsLaneSwitch {
                    HStack(spacing: 8) {
                        laneSwitch
                        if let lane = visibleLane ?? lanes.first?.id {
                            RemoteLaneFilterMenu(lane: lane, selection: filter(for: lane),
                                supportsReviewBoard: supportsReviewBoard)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                GeometryReader { area in
                    laneScroll(size: area.size, compact: compact, showsLaneHeader: !showsLaneSwitch)
                }
            }
        }
        .onChange(of: lanes.map(\.id)) { _, latest in
            if let visibleLane, !latest.contains(visibleLane) { self.visibleLane = latest.first }
        }
        .onChange(of: model.state.board?.account) { _, _ in resetFilters() }
        .onChange(of: supportsReviewBoard) { _, _ in resetFilters() }
    }

    private func resetFilters() {
        filters = [:]
        dragSession.finish()
    }

    private var laneSwitch: some View {
        let selectedLane = visibleLane ?? lanes.first?.id
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(lanes) { lane in
                let selected = lane.id == selectedLane
                let visibleCount = lane.cards.count(where: (filters[lane.id] ?? .init()).matches)
                Button {
                    withAnimation(reduceMotion ? nil : .default) { visibleLane = lane.id }
                } label: {
                    let label = VStack(spacing: 2) {
                        Text(lane.id.title)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                        Text(verbatim: "(\(visibleCount.formatted()))")
                            .monospacedDigit()
                    }
                    // Use the bold label to size the button in both selection states.
                    label.font(.subheadline.weight(.bold))
                        .hidden()
                        .overlay {
                            label.font(.subheadline.weight(selected ? .bold : .medium))
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lane.id.countedTitle(visibleCount))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("remote.lane.switch.\(lane.id.rawValue)")
            }
        }
    }

    private func filter(for lane: RemoteLaneID) -> Binding<RemoteBoardLaneFilter> {
        Binding(get: { filters[lane] ?? .init() }, set: {
            filters[lane] = $0
            dragSession.finish()
        })
    }

    private func laneScroll(size: CGSize, compact: Bool, showsLaneHeader: Bool) -> some View {
        let laneWidth = max(1, compact ? size.width - 32 : min(360, (size.width - 46) / 2))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(lanes) { lane in
                    RemoteLaneView(lane: lane, showsHeader: showsLaneHeader, onOpen: onOpen, onOpenCTA: onOpenCTA,
                        model: model, dragSession: dragSession, filter: filter(for: lane.id), supportsReviewBoard: supportsReviewBoard,
                        hiddenReviews: lane.id == .reviewed ? hiddenReviews : [], onRefresh: onRefresh)
                        .frame(width: laneWidth, height: max(1, size.height - 12))
                        .id(lane.id)
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, 12)
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $visibleLane, anchor: .leading)
    }
}

private struct RemoteLaneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lane: RemoteLane
    let showsHeader: Bool
    let onOpen: (RemoteCard) -> Void
    let onOpenCTA: (RemoteCard, RemoteCardCTA) -> Void
    let model: RemotePhoneModel
    let dragSession: BoardDragSession<RemoteBoardOrderMove.Source>
    @Binding var filter: RemoteBoardLaneFilter
    let supportsReviewBoard: Bool
    let hiddenReviews: [RemoteCard]
    @State private var hiddenExpanded = false
    var onRefresh: (() async -> Void)? = nil

    var body: some View {
        let cards = lane.cards.filter(filter.matches)
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                HStack(spacing: 12) {
                    lane.id.countedTitle(cards.count).font(.headline).monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("remote.lane.header.\(lane.id.rawValue)")
                    Spacer()
                    RemoteLaneFilterMenu(lane: lane.id, selection: $filter, supportsReviewBoard: supportsReviewBoard)
                }
            }
            GeometryReader { viewport in
                ScrollView(showsIndicators: false) {
                    laneCards(cards)
                        .frame(minHeight: viewport.size.height, alignment: .top)
                        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: cards.map(\.dependencies))
                        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: cards.map(\.id))
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await onRefresh?() }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("remote.lane.\(lane.id.rawValue)")
        .onChange(of: model.state.board?.hostSession) { _, _ in hiddenExpanded = false }
    }

    private func laneCards(_ cards: [RemoteCard]) -> some View {
        let inactiveCount = cards.count(where: isInactive)
        let firstInactive = cards.firstIndex(where: isInactive)
        let cardPositions = positions(in: cards)
        return LazyVStack(spacing: 0) {
            if cards.isEmpty && (hiddenReviews.isEmpty || filter.isActive) {
                Text(filter.isActive ? .Board.boardFiltersEmpty : .Remote.remoteEmpty)
                    .foregroundStyle(.secondary).padding(.top, 30)
            }
            ForEach(cardPositions, id: \.id) { position in
                let index = position.index
                let card = cards[index]
                VStack(spacing: 0) {
                    if index == firstInactive {
                        sectionHeading(.BoardActivity.inactiveSection(inactiveCount), anchor: card)
                    } else if card.orderGroup?.automationEnabled == true,
                              index == 0 || cards[index - 1].orderGroup?.automationEnabled != true {
                        sectionHeading(.Remote.remoteBoardAutomationOn, anchor: card)
                    }
                    boardCard(card)
                }
            }
            if let last = cards.last, last.orderGroup != nil {
                Spacer(minLength: 16)
                    .frame(maxWidth: .infinity)
                    .modifier(dropTarget(at: last.id, fixedInsertion: .after))
            }
            if !hiddenReviews.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .default) { hiddenExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: hiddenExpanded ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                        Text(.BoardActivity.hiddenSection(hiddenReviews.count)).monospacedDigit()
                        Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1).accessibilityHidden(true)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(Text(hiddenExpanded ? .RemoteCardActions.remoteCardActionsSectionExpanded
                    : .RemoteCardActions.remoteCardActionsSectionCollapsed))
                .accessibilityIdentifier("remote.reviewed.hidden")
                if hiddenExpanded {
                    ForEach(positions(in: hiddenReviews), id: \.id) { position in
                        RemoteHiddenReviewCard(card: hiddenReviews[position.index], model: model)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func positions(in cards: [RemoteCard]) -> [(index: Int, id: RemoteCard.ID)] {
        cards.indices.map { (index: $0, id: cards[$0].id) }
    }

    private func isInactive(_ card: RemoteCard) -> Bool {
        card.orderGroup.map { !$0.automationEnabled } ?? card.boardTraits?.isInactive ?? false
    }

    private func sectionHeading(_ title: LocalizedStringResource, anchor: RemoteCard) -> some View {
        Text(title).font(.caption.weight(.medium)).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .padding(.vertical, 6)
            .modifier(dropTarget(at: anchor.id, fixedInsertion: .before))
    }

    @ViewBuilder private func boardCard(_ card: RemoteCard) -> some View {
        let source = model.state.canAct() ? model.state.board?.orderSource(for: card) : nil
        let content = RemoteCardView(card: card, onOpen: { onOpen(card) }, onOpenCTA: { onOpenCTA(card, $0) },
            actionsModel: model)
        if let source {
            content.modifier(RemoteBoardOrderDrag(source: source, session: dragSession))
                .padding(.vertical, 6)
                .modifier(dropTarget(at: card.id))
        } else {
            content.padding(.vertical, 6)
        }
    }

    private func dropTarget(at anchor: String, fixedInsertion: BoardOrderInsertion? = nil) -> BoardInsertionDrop {
        func orderMove(_ insertion: BoardOrderInsertion) -> RemoteBoardOrderMove? {
            guard let source = dragSession.source, model.state.canAct() else { return nil }
            return model.state.board?.orderMove(from: source, beside: anchor, insertion: insertion)
        }
        return .init(type: RemoteBoardOrderDrag.type, fixedInsertion: fixedInsertion, allows: { orderMove($0) != nil }, move: {
            guard let move = orderMove($0) else { return false }
            dragSession.finish()
            Task { await model.moveBoardCard(move) }
            return true
        })
    }
}

private struct RemoteLaneFilterMenu: View {
    let lane: RemoteLaneID
    @Binding var selection: RemoteBoardLaneFilter
    let supportsReviewBoard: Bool

    var body: some View {
        Menu {
            Button(.Board.boardFiltersAll) { selection = .init() }
                .disabled(!selection.isActive)
            Section {
                Toggle(isOn: membership(.needsAttention, in: $selection.cards)) {
                    Text(.CommandCenter.commandCenterStatusAttention)
                }
                if lane == .reviewed, supportsReviewBoard {
                    Toggle(isOn: membership(.new, in: $selection.cards)) { Text(.Board.boardReviewAssignmentNew) }
                }
                Toggle(isOn: membership(.pinned, in: $selection.cards)) { Text(.Board.boardFiltersPinned) }
            } header: { Text(.Board.boardFiltersCards) }
            if supportsReviewBoard {
                Section {
                    Toggle(isOn: membership(.regular, in: $selection.sections)) { Text(.Board.boardFiltersRegular) }
                    Toggle(isOn: membership(.inactive, in: $selection.sections)) { Text(.Board.boardFiltersInactive) }
                } header: { Text(.Board.boardFiltersSections) }
            }
        } label: {
            Image(systemName: selection.isActive
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(selection.isActive ? Color.accentColor : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(Text(.Board.boardFiltersTitle))
        .accessibilityValue(Text(selection.isActive ? .Board.boardFiltersActive : .Board.boardFiltersAll))
        .accessibilityIdentifier("remote.lane.filters.\(lane.rawValue)")
    }

    private func membership<Value: Hashable>(_ value: Value, in values: Binding<Set<Value>>) -> Binding<Bool> {
        Binding {
            values.wrappedValue.contains(value)
        } set: { enabled in
            if enabled { values.wrappedValue.insert(value) }
            else { values.wrappedValue.remove(value) }
        }
    }
}
