import SwiftUI
import MergeTetherRemote

struct RemoteLaneBoard: View {
    let lanes: [RemoteLane]
    let onOpen: (RemoteCard) -> Void
    let onOpenCTA: (RemoteCard, RemoteCardCTA) -> Void
    var onFinishCommentReview: ((RemoteCard) -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
    var onRefresh: (() async -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var visibleLane: RemoteLaneID?

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
                        onFinishCommentReview: onFinishCommentReview, canAct: canAct, onRefresh: onRefresh)
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
    var onFinishCommentReview: ((RemoteCard) -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
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
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if lane.cards.isEmpty {
                        Text(.Remote.remoteEmpty).foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(lane.cards) { card in
                        RemoteCardView(card: card, onOpen: { onOpen(card) },
                            onOpenCTA: { onOpenCTA(card, $0) },
                            onFinishCommentReview: onFinishCommentReview.map { action in { action(card) } }, canAct: canAct)
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: lane.cards.map(\.dependencies))
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .refreshable { await onRefresh?() }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("remote.lane.\(lane.id.rawValue)")
    }
}
