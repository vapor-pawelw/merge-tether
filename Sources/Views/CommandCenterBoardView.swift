import AppKit
import SwiftUI

struct CommandCenterBoardView: View {
    let monitor: TodoMonitorService
    var refreshState: BoardRefreshState = .current
    private var dimUnverifiedContent: Bool { refreshState != .current }
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

    private var snapshot: MergeRequestBoardSnapshot { monitor.boardSnapshot }

    var body: some View {
        let board = snapshot
        HStack(alignment: .top, spacing: 18) {
            lane(title: .Board.boardLaneOwn, symbol: "arrow.triangle.pull", cardIDs: board.own.map(\.id), dependencies: board.own.map { $0.item.dependencies }) {
                if board.own.isEmpty {
                    empty(.Board.boardEmptyOwnTitle, message: .Board.boardLaneOwnEmpty, symbol: "arrow.triangle.pull")
                }
                laneCards(board.own)
            }
            lane(title: .Board.boardLaneReviewing, symbol: "text.magnifyingglass", cardIDs: board.reviewed.map(\.id), dependencies: board.reviewed.map { $0.item.dependencies }) {
                if board.reviewed.isEmpty {
                    empty(.Board.boardEmptyReviewingTitle, message: .Board.boardLaneReviewingEmpty, symbol: "text.magnifyingglass")
                }
                laneCards(board.reviewed, removable: true)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { selected = nil }
        }
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
    }

    private func laneCards(_ rows: [MergeRequestBoardSnapshot.Row], removable: Bool = false) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(spacing: 10) {
                activityDivider(activity(row), previous: index > 0 ? activity(rows[index - 1]) : nil)
                card(row, removable: removable)
            }
            .transition(cardTransition)
        }
    }

    private func activity(_ row: MergeRequestBoardSnapshot.Row) -> MRBoardActivity.Group {
        monitor.boardActivity(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url,
            isDraft: row.item.section == .draftMergeRequests,
            isFinished: MergeRequestFinishedState(row.item.mergeRequest) != nil).group
    }

    @ViewBuilder private func activityDivider(_ group: MRBoardActivity.Group, previous: MRBoardActivity.Group?) -> some View {
        if group != previous, group == .inactive || group == .drafts {
            HStack(spacing: 10) {
                Text(group == .inactive ? .BoardActivity.inactiveSection : .DraftMR.sectionTitle)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Rectangle().fill(.secondary.opacity(0.16)).frame(height: 0.5)
            }
            .padding(.top, previous == nil ? 2 : 14)
            .padding(.horizontal, 4)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func lane<Content: View, ID: Hashable>(title: LocalizedStringResource, symbol: String, cardIDs: [ID],
                                     dependencies: [MergeRequestDependencySummary?] = [], @ViewBuilder content: () -> Content) -> some View {
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
                    .opacity(dimUnverifiedContent && !cardIDs.isEmpty ? 0.55 : 1)
                    .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: cardIDs)
                    .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: dependencies)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

    }

    private func empty(_ title: LocalizedStringResource, message: LocalizedStringResource, symbol: String) -> some View {
        VStack(spacing: 12) {
            if refreshState == .syncing {
                ProgressView().controlSize(.small)
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.08)).frame(width: 44, height: 44)
                    Image(systemName: refreshState == .unavailable ? "arrow.clockwise" : symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            VStack(spacing: 6) {
                Text(refreshState == .syncing ? .Board.boardEmptyLoadingTitle
                     : refreshState == .unavailable ? .Board.boardEmptyUnavailableTitle : title)
                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                if refreshState != .syncing {
                    Text(refreshState == .unavailable ? .Board.boardEmptyUnavailableDescription : message)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 48)
        .frame(maxWidth: .infinity, minHeight: 210)
        .transition(cardTransition)
    }
}
