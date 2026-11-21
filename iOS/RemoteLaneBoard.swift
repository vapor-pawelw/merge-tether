import SwiftUI
import MergeTetherRemote

struct RemoteLaneBoard: View {
    let lanes: [RemoteLane]
    let onOpen: (RemoteCard) -> Void
    let onOpenCTA: (RemoteCard, RemoteCardCTA) -> Void
    let model: RemotePhoneModel
    var onRefresh: (() async -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibleLane: RemoteLaneID?
    @State private var dragSession = BoardDragSession<RemoteBoardOrderMove.Source>()

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
    }

    private var laneSwitch: some View {
        let selectedLane = visibleLane ?? lanes.first?.id
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(lanes) { lane in
                let selected = lane.id == selectedLane
                Button {
                    withAnimation(reduceMotion ? nil : .default) { visibleLane = lane.id }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(lane.id.title)
                            .font(.subheadline.weight(selected ? .bold : .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(lane.cards.count, format: .number)
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
                .accessibilityValue(Text(lane.cards.count, format: .number))
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
                    RemoteLaneView(lane: lane, showsHeader: showsLaneHeader, onOpen: onOpen, onOpenCTA: onOpenCTA,
                        model: model, dragSession: dragSession, onRefresh: onRefresh)
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
    var onRefresh: (() async -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lane.id.title).font(.headline)
                    Spacer()
                    Text(lane.cards.count, format: .number)
                        .font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.secondary.opacity(0.08), in: Capsule())
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remote.lane.header.\(lane.id.rawValue)")
            }
            GeometryReader { viewport in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        laneCards
                        if let last = lane.cards.last, last.orderGroup != nil {
                            Spacer(minLength: 16)
                                .frame(maxWidth: .infinity)
                                .modifier(dropTarget(at: last.id, fixedInsertion: .after))
                        }
                    }
                    .frame(minHeight: viewport.size.height, alignment: .top)
                    .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: lane.cards.map(\.dependencies))
                    .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: lane.cards.map(\.id))
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await onRefresh?() }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("remote.lane.\(lane.id.rawValue)")
    }

    private var laneCards: some View {
        LazyVStack(spacing: 0) {
            if lane.cards.isEmpty {
                Text(.Remote.remoteEmpty).foregroundStyle(.secondary).padding(.top, 30)
            }
            ForEach(Array(lane.cards.enumerated()), id: \.element.id) { index, card in
                if let group = card.orderGroup,
                   index == 0 || lane.cards[index - 1].orderGroup?.automationEnabled != group.automationEnabled {
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
