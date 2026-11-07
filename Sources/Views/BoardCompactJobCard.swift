import SwiftUI

struct BoardCompactJobCard: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    @State private var showingDetails = false

    private var repositoryPath: String {
        handoff.mergeRequestURL?.gitLabProjectPath ?? handoff.repository ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            HStack(alignment: .top, spacing: 6) {
                BoardCardTitle(title: handoff.title, repositoryPath: repositoryPath)
                Menu {
                    Button { showingDetails = true } label: {
                        Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
                    }
                    GitLabRefreshButton(monitor: monitor)
                    if let url = handoff.mergeRequestURL {
                        Link(destination: url) {
                            Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
                        }
                        AssistantContextMenu(mergeRequestURL: url, title: handoff.title,
                            workspace: monitor.settings.automation.assistantWorkspace)
                    }
                } label: { BoardCardActionIcon(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 24, height: 24)
                .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
            }
            BoardJobStatusActions(handoff: handoff, monitor: monitor)
            AssistantJobPreflightNotice(jobID: handoff.id, monitor: monitor)
            Button { showingDetails = true } label: {
                Text(.MRHumanAction.mrHumanActionActionReviewRun)
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .boardCardInteraction { showingDetails = true }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                Text(verbatim: handoff.title).font(.title3).textSelection(.enabled)
                Text(verbatim: repositoryPath).foregroundStyle(.secondary)
                AssistantJobRow(handoff: handoff, monitor: monitor)
            }
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            Text(handoff.key.assistant.displayName)
            Text(verbatim: "·")
            Text(handoff.createdAt, style: .relative)
            Spacer(minLength: 4)
            BoardMRIdentifier(iid: handoff.key.work.iid)
            BoardPinButton(pin: .mergeRequest(host: handoff.key.work.host,
                username: handoff.key.username, projectID: handoff.key.work.projectID, iid: handoff.key.work.iid),
                settings: monitor.settings)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Shared visible controls keep a proposal's attached run as actionable as a standalone run.
struct BoardJobStatusActions: View {
    let handoff: AssistantAutomationRunner.Handoff
    let monitor: TodoMonitorService
    @State private var retrying = false
    @Environment(\.openSettings) private var openSettings

    private var active: Bool { handoff.operationalExecution?.state.isActive == true }

    var body: some View {
        if active || (MergeRequestBoardSnapshot.Row.jobNeedsAttention(handoff.operationalExecution?.state)
            && !PipelineJobReconciliation.isObsolete(handoff, request: monitor.currentRequest(for: handoff))) {
            HStack {
                BoardStatusChip(title: active ? .Board.boardCompactWorking : .Board.boardCompactBlocked,
                    symbol: active ? "arrow.triangle.2.circlepath" : "exclamationmark.circle",
                    tint: active ? .blue : .orange)
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
