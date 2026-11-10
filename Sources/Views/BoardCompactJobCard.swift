import SwiftUI

struct BoardCompactJobCard: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    @State private var showingDetails = false

    private var repositoryPath: String {
        handoff.mergeRequestURL?.gitLabProjectPath ?? handoff.repository ?? ""
    }

    private var scopeTarget: MRAutomationScope.Target {
        .init(host: handoff.key.work.host, username: handoff.key.username,
            projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
    }
    private var currentRequest: GitLabMergeRequest? {
        let metadata = monitor.boardDisplayRequests.first { $0.projectID == scopeTarget.projectID && $0.iid == scopeTarget.iid }
        guard let url = handoff.mergeRequestURL ?? metadata?.webURL ?? monitor.currentRequest(for: handoff)?.webURL else { return nil }
        return monitor.boardDisplayRequest(for: scopeTarget, url: url) ?? monitor.currentRequest(for: handoff)
    }
    private var isDraft: Bool { currentRequest?.draft == true }
    private var finishedState: MergeRequestFinishedState? { .init(currentRequest) }
    private var isMuted: Bool {
        guard let url = currentRequest?.webURL ?? handoff.mergeRequestURL else { return isDraft }
        return monitor.boardActivity(projectID: handoff.key.work.projectID, iid: handoff.key.work.iid,
            url: url, isDraft: isDraft, isFinished: finishedState != nil).isMuted
    }
    private var finishedItem: MergeRequestAttentionMonitor.Item? {
        guard monitor.glab.resolvedHost == scopeTarget.host,
              monitor.glab.currentUsername == scopeTarget.username,
              let request = currentRequest, finishedState != nil,
              request.projectID == scopeTarget.projectID, request.iid == scopeTarget.iid,
              request.webURL.isGitLabMergeRequest(host: scopeTarget.host, iid: request.iid) else { return nil }
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: request.projectID, iid: request.iid),
            title: request.title, url: request.webURL)
        item.mergeRequest = request
        item.isAuthored = request.author.username == handoff.key.username
        item.lifecycleCompletionID = monitor.settings.mrLifecycleLedger.completionID(for: scopeTarget)
        return item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            VStack(alignment: .leading, spacing: 3) {
                BoardCardTitle(title: handoff.title, repositoryPath: repositoryPath,
                    titleColor: isMuted ? .secondary : .primary)
                BoardMRReferenceLine(iid: handoff.key.work.iid, projectID: handoff.key.work.projectID)
            }
            if let finishedItem {
                FinishedMergeRequestStatus(item: finishedItem, monitor: monitor)
            } else {
                AssistantJobPreflightNotice(jobID: handoff.id, monitor: monitor)
                BoardJobStatusActions(handoff: handoff, monitor: monitor, muted: isMuted)
            }
            Button { showingDetails = true } label: {
                Text(.MRHumanAction.mrHumanActionActionReviewRun)
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .boardCardInteraction { showingDetails = true }
        .contextMenu { menuItems }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                Text(verbatim: handoff.title).font(.title3).textSelection(.enabled)
                BoardMRReferenceLine(iid: handoff.key.work.iid, projectID: handoff.key.work.projectID)
                Text(verbatim: repositoryPath).foregroundStyle(.secondary)
                if let finishedItem { FinishedMergeRequestStatus(item: finishedItem, monitor: monitor) }
                AssistantJobRow(handoff: handoff, monitor: monitor, readOnly: finishedState != nil)
                if finishedState == nil {
                    MRAutomationScopeMenu(monitor: monitor, target: scopeTarget, projectPath: repositoryPath, isDraft: isDraft)
                }
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button { showingDetails = true } label: {
            Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
        }
        GitLabRefreshButton(monitor: monitor,
            itemID: .init(projectID: handoff.key.work.projectID, iid: handoff.key.work.iid))
        if let url = handoff.mergeRequestURL {
            Link(destination: url) {
                Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
            }
            AssistantContextMenu(mergeRequestURL: url, title: handoff.title,
                settings: monitor.settings)
        }
        if finishedState == nil {
            Divider()
            MRAutomationScopeMenu(monitor: monitor, target: scopeTarget,
                projectPath: repositoryPath, isDraft: isDraft)
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            Text(handoff.key.assistant.displayName)
            Text(verbatim: "·")
            Text(handoff.createdAt, style: .relative)
            Spacer(minLength: 4)
            if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
            else if isDraft { BoardDraftBadge() }
            HStack(spacing: 0) {
                if finishedState == nil {
                    BoardAutomationToggle(settings: monitor.settings, target: scopeTarget, projectPath: repositoryPath, isDraft: isDraft)
                }
                BoardPinButton(pin: .mergeRequest(host: handoff.key.work.host,
                    username: handoff.key.username, projectID: handoff.key.work.projectID, iid: handoff.key.work.iid),
                    settings: monitor.settings)
                BoardActionsMenu { menuItems }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Shared visible controls keep a proposal's attached run as actionable as a standalone run.
struct BoardJobStatusActions: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    var muted = false
    @State private var retrying = false
    @Environment(\.openSettings) private var openSettings

    private var active: Bool { handoff.operationalExecution?.state.isActive == true }
    private var isFinished: Bool {
        let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
            projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
        return MergeRequestFinishedState(monitor.settings.mrLifecycleLedger.request(for: target)
            ?? monitor.currentRequest(for: handoff)) != nil
    }

    var body: some View {
        if !isFinished && (active || (MergeRequestBoardSnapshot.Row.jobNeedsAttention(handoff.operationalExecution?.state)
            && !PipelineJobReconciliation.isObsolete(handoff, request: monitor.currentRequest(for: handoff)))) {
            HStack {
                if active, handoff.execution?.state == .queued,
                   let hold = monitor.cliHealth.hold(for: handoff.key.assistant) {
                    Text(hold.issue.kind == .loginRequired
                        ? .AutomationProgress.progressPausedLogin : .AutomationProgress.progressPausedLimit)
                        .font(.caption).foregroundStyle(.secondary)
                } else if active {
                    MRActivityStatus(status: String(localized: handoff.progressTitle(intents: monitor.settings.mrActionIntents,
                        conflictReceipts: monitor.settings.conflictReceipts)),
                        startedAt: handoff.execution?.state == .running
                            ? handoff.execution?.startedAt ?? handoff.createdAt : handoff.createdAt)
                        .font(.caption).foregroundStyle(muted ? Color.secondary : Color.blue)
                } else {
                    BoardStatusChip(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle",
                        tint: muted ? .secondary : .orange)
                }
                Spacer(minLength: 6)
                if active {
                    Button(role: .destructive) { monitor.cancelAssistantJob(handoff.id) } label: {
                        Text(.AssistantJobs.assistantJobsStop)
                    }
                    .buttonStyle(.plain)
                } else if !monitor.availableAssistants.contains(handoff.key.assistant) {
                    Button { openSettings() } label: { Text(.Board.boardCompactSetupCli) }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        guard !retrying, !AssistantAutomationRunner.isWorking(on: handoff.key.work) else { return }
                        retrying = true
                        Task {
                            defer { retrying = false }
                            await monitor.retryAssistantJob(handoff.id)
                        }
                    } label: { Text(.MRHumanAction.mrHumanActionActionRetryRun) }
                    .buttonStyle(.bordered)
                    .disabled(retrying || AssistantAutomationRunner.isWorking(on: handoff.key.work))
                }
            }
            .font(.caption)
        }
    }
}
