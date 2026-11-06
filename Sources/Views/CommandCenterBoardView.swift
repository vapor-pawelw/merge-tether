import SwiftUI

struct CommandCenterBoardView: View {
    let monitor: TodoMonitorService
    var dimUnverifiedContent = false
    private struct Selection: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let section: CommandCenterMRDetailSection
        let account: GlabService.AuthedHost?
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
    }
    @State private var selected: Selection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var account: GlabService.AuthedHost? {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return nil }
        return .init(host: host, username: username)
    }

    private var snapshot: MergeRequestBoardSnapshot {
        let own = monitor.ownMergeRequestItems
        let reviewed = monitor.reviewedMergeRequestItems
        let attention = monitor.attentionItems
        return .init(own: own, reviewed: reviewed, todos: monitor.currentAccountTodos, attention: attention,
              handoffs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost, username: monitor.glab.currentUsername,
              intents: monitor.currentMRTodoIntents, routedTodoIDs: monitor.routedMRTodoIDs,
              ignoredTargets: monitor.settings.ignoredMergeRequests, humanAttention: monitor.userAttention,
              pinnedCards: monitor.settings.boardPins)
    }

    var body: some View {
        let board = snapshot
        let otherCards = board.otherCards(jobs: monitor.assistantHandoffs, host: account?.host, username: account?.username,
            pinnedCards: monitor.settings.boardPins)
        HStack(alignment: .top, spacing: 18) {
            lane(title: .Board.boardLaneOwn, symbol: "arrow.triangle.pull", cardIDs: board.own.map(\.id)) {
                if board.own.isEmpty { empty(.Board.boardLaneOwnEmpty) }
                ForEach(board.own) { row in card(row) }
            }
            lane(title: .Board.boardLaneReviewing, symbol: "text.magnifyingglass", cardIDs: board.reviewed.map(\.id)) {
                if board.reviewed.isEmpty { empty(.Board.boardLaneReviewingEmpty) }
                ForEach(board.reviewed) { row in card(row, removable: true) }
            }
            lane(title: .Board.boardLaneOther, symbol: "tray", cardIDs: otherCards.map(\.id)) {
                if otherCards.isEmpty { empty(.Board.boardLaneOtherEmpty) }
                ForEach(otherCards) { entry in
                    otherCard(entry).transition(cardTransition)
                }
            }
        }
        .id(account)
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $selected) { selection in
            VStack(spacing: 0) {
                HStack {
                    Text(selection.section.title).font(.headline)
                    Spacer()
                    Button { selected = nil } label: { Image(systemName: "xmark") }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text(.CommandCenter.commandCenterClose))
                }
                .padding(16)
                Divider()
                if selection.account == account {
                    CommandCenterMRDetail(item: current(selection.item), monitor: monitor, initialSection: selection.section)
                        .id(selection.id)
                }
            }
            .frame(minWidth: 700, idealWidth: 820, minHeight: 600, idealHeight: 780)
        }
        .onChange(of: account) { _, _ in selected = nil }
        .task {
            while !Task.isCancelled {
                await monitor.attention.refreshPendingDrafts()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func current(_ original: MergeRequestAttentionMonitor.Item) -> MergeRequestAttentionMonitor.Item {
        let board = snapshot
        return (board.own + board.reviewed + board.otherMergeRequests).first { $0.id == original.id && $0.item.url == original.url }?.item ?? original
    }

    private func card(_ row: MergeRequestBoardSnapshot.Row, removable: Bool = false) -> some View {
        CommandCenterMRCard(row: row, monitor: monitor, allowsRemoval: removable, onAttention: { section in
            selected = Selection(item: row.item, section: section, account: account)
        }, onDetails: {
            selected = Selection(item: row.item, section: .overview, account: account)
        })
        .transition(cardTransition)
    }

    @ViewBuilder
    private func otherCard(_ card: MergeRequestBoardSnapshot.OtherCard) -> some View {
        switch card.content {
        case .proposal(let proposal): BoardMRProposalCard(proposal: proposal, monitor: monitor)
        case .todo(let todo):
            BoardTodoRow(todo: todo, monitor: monitor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        case .job(let job): BoardCompactJobCard(handoff: job, monitor: monitor)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func lane<Content: View, ID: Hashable>(title: LocalizedStringResource, symbol: String, cardIDs: [ID],
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label { Text(title) } icon: { Image(systemName: symbol) }
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(cardIDs.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10).padding(.horizontal, 1)
                    .opacity(dimUnverifiedContent ? 0.55 : 1)
                    .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: cardIDs)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

    }

    private func empty(_ title: LocalizedStringResource) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(cardTransition)
    }
}
