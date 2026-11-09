import SwiftUI

struct CommandCenterInboxView: View {
    let monitor: TodoMonitorService
    @Environment(\.dismiss) private var dismiss

    private var items: [MergeRequestBoardSnapshot.OtherCard] { monitor.inboxItems }

    private var triageItems: [MergeRequestBoardSnapshot.OtherCard] {
        items.filter { item in
            switch item.content {
            case .proposal(_), .todo(_): return true
            case .job(_), .completion(_): return false
            }
        }
    }

    private var jobItems: [MergeRequestBoardSnapshot.OtherCard] {
        items.filter {
            if case .job(_) = $0.content { return true }
            return false
        }
    }

    private var updateItems: [MergeRequestBoardSnapshot.OtherCard] {
        items.filter {
            if case .completion(_) = $0.content { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 760, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await monitor.attention.refreshPendingDrafts()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }

    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(.Board.boardInboxButton).font(.title2.weight(.semibold))
                Text(.Board.boardInboxAccessibilityCount(items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help(Text(.Board.boardInboxClose))
                .accessibilityLabel(Text(.Board.boardInboxClose))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty && monitor.boardRefreshState == .syncing {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    itemSection(.Board.boardInboxTriage, symbol: "tray.2", items: triageItems)
                    itemSection(.Board.boardInboxAssistantJobs, symbol: "cpu", items: jobItems)
                    itemSection(.Board.boardInboxUpdates, symbol: "clock.arrow.circlepath", items: updateItems)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(.Board.boardInboxEmptyTitle)
                .font(.title3.weight(.medium))
            Text(.Board.boardInboxEmptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func itemSection(
        _ title: LocalizedStringResource,
        symbol: String,
        items: [MergeRequestBoardSnapshot.OtherCard]
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    Text(items.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityAddTraits(.isHeader)

                ForEach(items) { item in
                    card(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func card(for item: MergeRequestBoardSnapshot.OtherCard) -> some View {
        switch item.content {
        case .completion(let completion):
            BoardMRCompletionCard(completion: completion, monitor: monitor)
        case .proposal(let proposal):
            BoardMRProposalCard(proposal: proposal, monitor: monitor)
        case .todo(let todo):
            BoardTodoRow(todo: todo, monitor: monitor)
        case .job(let job):
            BoardCompactJobCard(handoff: job, monitor: monitor)
        }
    }
}
