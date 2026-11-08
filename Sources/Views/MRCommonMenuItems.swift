import SwiftUI

struct GitLabRefreshButton: View {
    let monitor: TodoMonitorService
    var itemID: MergeRequestAttentionMonitor.Item.ID? = nil
    var afterRefresh: @MainActor () async -> Void = {}
    @State private var refreshing = false

    var body: some View {
        Button {
            refreshing = true
            Task {
                defer { refreshing = false }
                if let itemID { await monitor.refreshFromGitLab(for: itemID) }
                else { await monitor.forceRefreshFromGitLab() }
                await afterRefresh()
            }
        } label: {
            Label { Text(.MRFreshness.mrFreshnessRefresh) } icon: {
                if refreshing { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise") }
            }
        }
        .disabled(refreshing)
    }
}

/// One set of MR actions for the board card and its Details header.
struct MRCommonMenuItems: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var onRemove: (() -> Void)? = nil
    @State private var startingReview = false
    private var isFinished: Bool { MergeRequestFinishedState(item.mergeRequest) != nil }

    var body: some View {
        Link(destination: item.url) {
            Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
        }
        GitLabRefreshButton(monitor: monitor, itemID: item.id)
        if isFinished {
            Button { monitor.acknowledgeFinishedMergeRequest(item) } label: {
                Label { Text(.MRLifecycle.seen) } icon: { Image(systemName: "checkmark") }
            }
        } else {
            MarkMergeRequestReadyButton(item: item, monitor: monitor)
        }
        if !isFinished, monitor.canRunReview(for: item) {
            Button {
                startingReview = true
                Task {
                    defer { startingReview = false }
                    await monitor.runReview(for: item)
                }
            } label: {
                Label { Text(.CommandCenter.commandCenterReviewRun) } icon: { Image(systemName: "text.magnifyingglass") }
            }
            .disabled(startingReview || !monitor.canRunReview(for: item))
        }
        AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                             workspace: monitor.settings.automation.assistantWorkspace)
        if !isFinished, monitor.settings.automation.hasEnabledAutomation,
           let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
            Divider()
            MRAutomationScopeMenu(settings: monitor.settings, target: target, projectPath: item.url.gitLabProjectPath,
                isDraft: item.section == .draftMergeRequests)
            if !item.isAuthored, monitor.settings.automation.autoApproveEnabled {
                Toggle(isOn: Binding(get: { !monitor.settings.autoApproveOptOuts.contains(target) }, set: { enabled in
                    if enabled { monitor.settings.autoApproveOptOuts.remove(target) }
                    else { monitor.settings.autoApproveOptOuts.insert(target) }
                    monitor.settings.save()
                })) {
                    Label { Text(.CommandCenter.commandCenterAutoApprove) } icon: { Image(systemName: "checkmark.seal") }
                }
            }
        }
        if !isFinished, let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label { Text(.Board.boardRemove) } icon: { Image(systemName: "minus.circle") }
            }
        }
    }
}

struct AssistantJobPreflightNotice: View {
    let jobID: UUID
    let monitor: TodoMonitorService

    var body: some View {
        if let notice = monitor.assistantJobActionNotices[jobID] {
            Text(verbatim: notice).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
