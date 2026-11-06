import SwiftUI

struct CommandCenterBoardView: View {
    let monitor: TodoMonitorService
    private struct Selection: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let section: CommandCenterMRDetailSection
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
    }
    @State private var selected: Selection?

    private var snapshot: MergeRequestBoardSnapshot {
        let own = monitor.ownMergeRequestItems
        let reviewed = monitor.reviewedMergeRequestItems
        let attention = monitor.attentionItems
        return .init(own: own, reviewed: reviewed, todos: monitor.visibleTodos, attention: attention,
              handoffs: monitor.assistantHandoffs, host: monitor.glab.resolvedHost, username: monitor.glab.currentUsername,
              intents: monitor.currentMRTodoIntents, routedTodoIDs: monitor.routedMRTodoIDs,
              ignoredTargets: monitor.settings.ignoredMergeRequests, humanAttention: monitor.userAttention)
    }

    private var unattachedJobs: [AssistantAutomationRunner.Handoff] {
        let rows = snapshot.own + snapshot.reviewed + snapshot.otherMergeRequests
        let latest = Dictionary(grouping: monitor.assistantHandoffs, by: \.key.work)
            .values.compactMap { $0.max { $0.createdAt < $1.createdAt } }
        return latest.filter { job in
            !monitor.settings.ignoredMergeRequests.contains(.init(host: job.key.work.host, username: job.key.username,
                projectID: job.key.work.projectID, iid: job.key.work.iid))
                && (job.execution?.state.isActive == true || MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state))
                && !rows.contains { row in
                    row.item.id.projectID == job.key.work.projectID && row.item.id.iid == job.key.work.iid
                        && row.item.url.isGitLabMergeRequest(host: job.key.work.host, iid: job.key.work.iid)
                }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let board = snapshot
        HStack(alignment: .top, spacing: 18) {
            lane(title: .Board.boardLaneOwn, symbol: "arrow.triangle.pull", count: board.own.count) {
                if board.own.isEmpty { empty(.Board.boardLaneOwnEmpty) }
                ForEach(board.own) { row in card(row) }
            }
            lane(title: .Board.boardLaneReviewing, symbol: "text.magnifyingglass", count: board.reviewed.count) {
                if board.reviewed.isEmpty { empty(.Board.boardLaneReviewingEmpty) }
                ForEach(board.reviewed) { row in card(row, removable: true) }
            }
            lane(title: .Board.boardLaneOther, symbol: "tray", count: board.otherTodos.count + board.proposals.count + unattachedJobs.count) {
                if board.otherTodos.isEmpty && board.proposals.isEmpty && unattachedJobs.isEmpty {
                    empty(.Board.boardLaneOtherEmpty)
                }
                ForEach(board.proposals) { proposal in BoardMRProposalCard(proposal: proposal, monitor: monitor) }
                ForEach(board.otherTodos) { todo in
                    BoardTodoRow(todo: todo, monitor: monitor)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(unattachedJobs) { job in BoardCompactJobCard(handoff: job, monitor: monitor) }
            }
        }
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
                CommandCenterMRDetail(item: current(selection.item), monitor: monitor, initialSection: selection.section)
                    .id(selection.id)
            }
            .frame(minWidth: 700, idealWidth: 820, minHeight: 600, idealHeight: 780)
        }
        .task {
            while !Task.isCancelled {
                await monitor.attention.refreshPendingDrafts()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func current(_ original: MergeRequestAttentionMonitor.Item) -> MergeRequestAttentionMonitor.Item {
        (snapshot.own + snapshot.reviewed + snapshot.otherMergeRequests).first { $0.id == original.id && $0.item.url == original.url }?.item ?? original
    }

    private func card(_ row: MergeRequestBoardSnapshot.Row, removable: Bool = false) -> some View {
        CommandCenterMRCard(row: row, monitor: monitor, allowsRemoval: removable, onAttention: { section in
            selected = Selection(item: row.item, section: section)
        }, onDetails: {
            selected = Selection(item: row.item, section: .overview)
        })
    }

    private func lane<Content: View>(title: LocalizedStringResource, symbol: String, count: Int,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label { Text(title) } icon: { Image(systemName: symbol) }
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10).padding(.horizontal, 1)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

    }

    private func empty(_ title: LocalizedStringResource) -> some View {
        Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BoardCompactJobCard: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    @State private var retrying = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: handoff.title).font(.callout.weight(.semibold)).lineLimit(2)
            HStack {
                Text(handoff.key.assistant.displayName)
                Spacer()
                Text(handoff.createdAt, style: .relative)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                BoardStatusChip(title: handoff.execution?.state.isActive == true
                    ? .Board.boardCompactWorking : .Board.boardCompactBlocked,
                    symbol: handoff.execution?.state.isActive == true ? "arrow.triangle.2.circlepath" : "exclamationmark.circle",
                    tint: handoff.execution?.state.isActive == true ? .blue : .orange)
                Spacer()
                if handoff.execution?.state.isActive == true {
                    Button(role: .destructive) { monitor.cancelAssistantJob(handoff.id) } label: { Text(.AssistantJobs.assistantJobsStop) }
                        .buttonStyle(.plain)
                } else if !monitor.availableAssistants.contains(handoff.key.assistant) {
                    Button { openSettings() } label: { Text(.Board.boardCompactSetupCli) }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        retrying = true
                        Task { defer { retrying = false }; await monitor.retryAssistantJob(handoff.id) }
                    } label: { Text(.AssistantJobs.assistantJobsRetry) }
                    .buttonStyle(.bordered)
                    .disabled(retrying || AssistantAutomationRunner.isWorking(on: handoff.key.work))
                }
            }
            DisclosureGroup {
                AssistantJobRow(handoff: handoff, monitor: monitor)
            } label: { Text(.Board.boardDetails) }
            .font(.caption)
        }
        .padding(12).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
