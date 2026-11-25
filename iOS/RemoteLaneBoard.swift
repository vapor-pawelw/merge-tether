import SwiftUI
import MergeTetherRemote

struct RemoteLaneBoard: View {
    let lanes: [RemoteLane]
    let onOpen: (RemoteCard) -> Void
    let onOpenCTA: (RemoteCard, RemoteCardCTA) -> Void
    let model: RemotePhoneModel
    var onOpenHiddenReviews: (() -> Void)?
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
                if showsLaneSwitch { laneSwitch }
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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(lane.id.title)
                            .font(.subheadline.weight(selected ? .bold : .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(visibleCount, format: .number)
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(lane.id.title))
                .accessibilityValue(Text(visibleCount, format: .number))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("remote.lane.switch.\(lane.id.rawValue)")
            }
        }
        .padding(.horizontal, 16)
    }

    private func laneScroll(size: CGSize, compact: Bool, showsLaneHeader: Bool) -> some View {
        let laneWidth = max(1, compact ? size.width - 32 : min(360, (size.width - 46) / 2))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(lanes) { lane in
                    let filter = Binding(get: { filters[lane.id] ?? .init() }, set: {
                        filters[lane.id] = $0
                        dragSession.finish()
                    })
                    RemoteLaneView(lane: lane, showsHeader: showsLaneHeader, onOpen: onOpen, onOpenCTA: onOpenCTA,
                        model: model, dragSession: dragSession, filter: filter, supportsReviewBoard: supportsReviewBoard,
                        onOpenHiddenReviews: lane.id == .reviewed ? onOpenHiddenReviews : nil, onRefresh: onRefresh)
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
    let onOpenHiddenReviews: (() -> Void)?
    var onRefresh: (() async -> Void)? = nil

    var body: some View {
        let cards = lane.cards.filter(filter.matches)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if showsHeader {
                    HStack(spacing: 8) {
                        Text(lane.id.title).font(.headline)
                        Text(cards.count, format: .number)
                            .font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.secondary.opacity(0.08), in: Capsule())
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("remote.lane.header.\(lane.id.rawValue)")
                }
                Spacer()
                if let onOpenHiddenReviews {
                    Button(action: onOpenHiddenReviews) {
                        Image(systemName: "eye.slash")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(.RemoteCardActions.remoteCardActionsHiddenReviews))
                    .accessibilityIdentifier("remote.reviewed.hidden")
                }
                RemoteLaneFilterMenu(lane: lane.id, selection: $filter, supportsReviewBoard: supportsReviewBoard)
            }
            GeometryReader { viewport in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        laneCards(cards)
                        if let last = cards.last, last.orderGroup != nil {
                            Spacer(minLength: 16)
                                .frame(maxWidth: .infinity)
                                .modifier(dropTarget(at: last.id, fixedInsertion: .after))
                        }
                    }
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
    }

    private func laneCards(_ cards: [RemoteCard]) -> some View {
        LazyVStack(spacing: 0) {
            if cards.isEmpty {
                Text(filter.isActive ? .Board.boardFiltersEmpty : .Remote.remoteEmpty)
                    .foregroundStyle(.secondary).padding(.top, 30)
            }
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if let group = card.orderGroup,
                   index == 0 || cards[index - 1].orderGroup?.automationEnabled != group.automationEnabled {
                    Text(group.automationEnabled ? .Remote.remoteBoardAutomationOn : .Remote.remoteBoardAutomationOff)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.vertical, 6)
                        .modifier(dropTarget(at: card.id, fixedInsertion: .before))
                }
                boardCard(card)
            }
        }
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

struct RemoteHiddenReviewsView: View {
    let model: RemotePhoneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let reviews = model.state.board?.hiddenReviews ?? []
            List(reviews) { card in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: card.title).font(.headline)
                        Text(verbatim: card.mergeRequestIID.map { "\(card.project) · !\($0)" } ?? card.project)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let action = card.actions.first(where: { $0.id == RemoteAction.restoreHiddenReviewID }) {
                        Button(.Board.boardReviewAssignmentRestore) {
                            Task { await model.perform(card: card, action: action) }
                        }
                        .buttonStyle(.bordered)
                        .modifier(RemoteActionAvailability(state: model.state))
                        .accessibilityIdentifier("remote.review.restore.\(card.id)")
                    }
                }
            }
            .overlay {
                if reviews.isEmpty { Text(.RemoteCardActions.remoteCardActionsHiddenReviewsEmpty).foregroundStyle(.secondary) }
            }
            .navigationTitle(Text(.RemoteCardActions.remoteCardActionsHiddenReviews))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(.Remote.remoteClose) { dismiss() }
                }
            }
            .alert(Text(model.resultTitle), isPresented: Binding(
                get: { model.state.result != nil }, set: { if !$0 { model.state.acknowledgeResult() } }
            )) {
                Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
            }
        }
    }
}
