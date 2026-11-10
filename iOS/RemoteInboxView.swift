import SwiftUI
import MergeTetherRemote

struct RemoteInboxView: View {
    let cards: [RemoteCard]
    let onOpen: (RemoteCard) -> Void
    var onFinishCommentReview: ((RemoteCard) -> Void)? = nil
    var canAct: ((Date) -> Bool)? = nil
    @Environment(\.dismiss) private var dismiss

    private var triageCards: [RemoteCard] {
        cards.filter { $0.id.hasPrefix("mr:") || $0.id.hasPrefix("todo:") }
    }
    private var jobCards: [RemoteCard] { cards.filter { $0.id.hasPrefix("job:") } }
    private var updateCards: [RemoteCard] { cards.filter { $0.id.hasPrefix("completion:") } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(.Board.boardInboxButton).font(.title2.weight(.semibold))
                    Text(.Board.boardInboxAccessibilityCount(cards.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(.Board.boardInboxClose))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            if cards.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text(.Board.boardInboxEmptyTitle).font(.title3.weight(.medium))
                    Text(.Board.boardInboxEmptyMessage)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section(.Board.boardInboxTriage, symbol: "tray.2", cards: triageCards)
                        section(.Board.boardInboxAssistantJobs, symbol: "cpu", cards: jobCards)
                        section(.Board.boardInboxUpdates, symbol: "clock.arrow.circlepath", cards: updateCards)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringResource, symbol: String, cards: [RemoteCard]) -> some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    Text(cards.count, format: .number)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityAddTraits(.isHeader)
                ForEach(cards) { card in
                    RemoteCardView(card: card, onOpen: { onOpen(card) },
                        onFinishCommentReview: onFinishCommentReview.map { action in { action(card) } }, canAct: canAct)
                }
            }
        }
    }
}
