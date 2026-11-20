import AppKit
import SwiftUI

struct CommandCenterBoardView: View {
    let monitor: TodoMonitorService
    let board: MergeRequestBoardSnapshot
    var refreshState: BoardRefreshState = .current
    private var dimUnverifiedContent: Bool { refreshState != .current }
    private enum Lane: Hashable {
        case own, reviewing

        var title: LocalizedStringResource {
            self == .own ? .Board.boardLaneOwn : .Board.boardLaneReviewing
        }

        var symbol: String { self == .own ? "arrow.triangle.pull" : "text.magnifyingglass" }
    }

    private struct Selection: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let section: CommandCenterMRDetailSection
        let account: GlabService.AuthedHost?
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
    }
    @State private var selected: Selection?
    @State private var compactLane: Lane = .own
    @State private var detailPopoverPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var account: GlabService.AuthedHost? {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return nil }
        return .init(host: host, username: username)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 18) {
                if geometry.size.width < 900 {
                    lane(compactLane, compact: true)
                } else {
                    lane(.own)
                    lane(.reviewing)
                }
            }
            .id(account)
            .padding(14)
            .sheet(item: $selected) { selection in
                detailSheet(selection, availableWidth: max(1, geometry.size.width - 24))
            }
        }
        .background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.95))
        .onChange(of: account) { _, _ in selected = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "main" { selected = nil }
        }
        .task {
            await monitor.attention.observePendingDrafts()
        }
    }

    private func detailSheet(_ selection: Selection, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.section.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(detailPopoverPresented)
                    .accessibilityLabel(Text(.CommandCenter.commandCenterClose))
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if selection.account == account {
                CommandCenterMRDetail(item: selection.item, monitor: monitor, initialSection: selection.section)
                    .id(selection.id)
            }
        }
        .frame(minWidth: min(700, availableWidth), idealWidth: min(820, availableWidth), maxWidth: availableWidth,
               minHeight: 600, idealHeight: 780)
        .interactiveDismissDisabled(detailPopoverPresented)
        .onPreferenceChange(BoardDetailPopoverPresentedKey.self) { detailPopoverPresented = $0 }
    }

    private func card(_ row: MergeRequestBoardSnapshot.Row, removable: Bool = false) -> some View {
        CommandCenterMRCard(row: row, monitor: monitor, allowsRemoval: removable, onAttention: { section in
            selected = Selection(item: row.item, section: section, account: account)
        }, onDetails: {
            selected = Selection(item: row.item, section: .overview, account: account)
        })
    }

    private func laneCards(_ rows: [MergeRequestBoardSnapshot.Row], removable: Bool = false) -> some View {
        let inactiveAttentionCount = rows.filter { row in
            activity(row) == .inactive && row.needsAttention
                && MRCardPresentation(row: row, monitor: monitor, allowsRemoval: removable).humanAction != nil
        }.count
        return ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(spacing: 10) {
                activityDivider(activity(row), previous: index > 0 ? activity(rows[index - 1]) : nil,
                    attentionCount: inactiveAttentionCount)
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

    @ViewBuilder private func activityDivider(_ group: MRBoardActivity.Group, previous: MRBoardActivity.Group?,
                                              attentionCount: Int) -> some View {
        if group != previous, group == .inactive || group == .drafts {
            HStack(spacing: 10) {
                Text(group == .inactive ? .BoardActivity.inactiveSection : .DraftMR.sectionTitle)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if group == .inactive, attentionCount > 0 {
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Text(.BoardActivity.attentionCount(attentionCount))
                        .foregroundStyle(.orange)
                }
                Rectangle().fill(.secondary.opacity(0.16)).frame(height: 0.5)
            }
            .font(.caption.weight(.medium))
            .padding(.top, previous == nil ? 2 : 14)
            .padding(.horizontal, 4)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }

    private func lane(_ lane: Lane, compact: Bool = false) -> some View {
        let reviewing = lane == .reviewing
        let rows = reviewing ? board.reviewed : board.own
        let cardIDs = rows.map(\.id)
        return VStack(spacing: 0) {
            HStack {
                if compact {
                    Picker(selection: $compactLane) {
                        Text(Lane.own.title).tag(Lane.own)
                        Text(Lane.reviewing.title).tag(Lane.reviewing)
                    } label: { Text(.Board.boardTitle) }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("command-center.board-lane")
                } else {
                    Label { Text(lane.title) } icon: { Image(systemName: lane.symbol) }
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(cardIDs.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty {
                        empty(reviewing ? .Board.boardEmptyReviewingTitle : .Board.boardEmptyOwnTitle,
                              message: reviewing ? .Board.boardLaneReviewingEmpty : .Board.boardLaneOwnEmpty,
                              symbol: lane.symbol)
                    }
                    laneCards(rows, removable: reviewing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10).padding(.horizontal, 1)
                .opacity(dimUnverifiedContent && !cardIDs.isEmpty ? 0.55 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: cardIDs)
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: rows.map { $0.item.dependencies })
            }
            .id(lane)
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
