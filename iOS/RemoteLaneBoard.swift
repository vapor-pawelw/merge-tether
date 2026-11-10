import SwiftUI
import MergeTetherRemote

struct RemoteLaneBoard: View {
    let lanes: [RemoteLane]
    let onOpen: (RemoteCard) -> Void
    var onFinishCommentReview: ((RemoteCard) -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
    @State private var visibleLane: RemoteLaneID?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let laneWidth = max(1, width >= 700 ? min(360, (width - 46) / 2) : min(360, width - 48))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(lanes) { lane in
                        RemoteLaneView(lane: lane, onOpen: onOpen, onFinishCommentReview: onFinishCommentReview, canAct: canAct)
                            .frame(width: laneWidth, height: max(1, geometry.size.height - 12))
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
}

private struct RemoteLaneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lane: RemoteLane
    let onOpen: (RemoteCard) -> Void
    var onFinishCommentReview: ((RemoteCard) -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lane.id.title).font(.headline)
                Spacer()
                Text(lane.cards.count, format: .number).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote.lane.header.\(lane.id.rawValue)")
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if lane.cards.isEmpty {
                        Text(.Remote.remoteEmpty).foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(lane.cards) { card in
                        RemoteCardView(card: card, onOpen: { onOpen(card) },
                            onFinishCommentReview: onFinishCommentReview.map { action in { action(card) } }, canAct: canAct)
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: lane.cards.map(\.dependencies))
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("remote.lane.\(lane.id.rawValue)")
    }
}
