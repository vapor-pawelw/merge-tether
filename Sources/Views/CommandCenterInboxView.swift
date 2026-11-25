import SwiftUI

struct CommandCenterInboxView: View {
    let monitor: TodoMonitorService
    @Environment(\.dismiss) private var dismiss
    @State private var isMarkingRead = false

    var body: some View {
        let inbox = monitor.commandCenterDisplayFrame.inbox
        VStack(spacing: 0) {
            header(inbox, accountRevision: monitor.glab.accountRevision)
            Divider()
            content(inbox)
        }
        .frame(width: 760, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await monitor.attention.observePendingDrafts()
        }

    }

    private func header(_ inbox: CommandCenterDisplayFrame.Inbox, accountRevision: UInt64) -> some View {
        let count = inbox.items.count
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(.Board.boardInboxButton).font(.title2.weight(.semibold))
                if count > 0 || monitor.inboxRefreshState == .current {
                    Text(.Board.boardInboxAccessibilityCount(count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isMarkingRead { ProgressView().controlSize(.small) }
            Button(.Board.boardInboxMarkAllRead) {
                isMarkingRead = true
                Task {
                    defer { isMarkingRead = false }
                    await monitor.markInboxNotificationsRead(inbox.notificationIDs, accountRevision: accountRevision)
                }
            }
            .disabled(inbox.notificationIDs.isEmpty || isMarkingRead)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help(Text(.Board.boardInboxClose))
                .accessibilityLabel(Text(.Board.boardInboxClose))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func content(_ inbox: CommandCenterDisplayFrame.Inbox) -> some View {
        if inbox.items.isEmpty {
            switch monitor.inboxRefreshState {
            case .syncing:
                ProgressView()
                    .accessibilityLabel(Text(.Board.boardInitialSync))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                unavailableState
            case .current:
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    itemSection(.Board.boardInboxTriage, symbol: "tray.2", items: inbox.triage)
                    itemSection(.Board.boardInboxAssistantJobs, symbol: "cpu", items: inbox.jobs)
                    itemSection(.Board.boardInboxUpdates, symbol: "clock.arrow.circlepath", items: inbox.updates)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(.Board.boardInboxUnavailable).font(.title3.weight(.medium))
            Button(.Board.boardInboxRetry) { Task { await monitor.refreshManually() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
            LazyVStack(alignment: .leading, spacing: 10) {
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
        case .hiddenReview(let review, let notice):
            BoardHiddenReviewCard(review: review, notice: notice, monitor: monitor)
        case .proposal(let proposal):
            BoardMRProposalCard(proposal: proposal, monitor: monitor)
        case .todo(let todo):
            BoardTodoRow(todo: todo, monitor: monitor)
        case .job(let job):
            BoardCompactJobCard(handoff: job, monitor: monitor)
        }
    }
}
