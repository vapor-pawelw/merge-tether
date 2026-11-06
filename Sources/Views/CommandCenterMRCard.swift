import AppKit
import SwiftUI

struct CommandCenterMRCard: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var allowsRemoval = false
    var onAttention: ((CommandCenterMRDetailSection) -> Void)? = nil
    let onDetails: () -> Void
    @State private var isStarting = false
    @State private var retryError: String?
    @State private var confirmRemoval = false
    @Environment(\.openSettings) private var openSettings

    private var item: MergeRequestAttentionMonitor.Item { row.item }
    private var automaticConflictProgress: Bool {
        item.mergeRequest.map { monitor.automaticConflictIsProcessing(for: $0) } ?? false
    }
    private var busy: Bool {
        let state = monitor.attention.confirmationStates[item.id]
        return state == .publishing || state == .approving || item.authorFeedbackStatus?.phase == .checking
            || item.reReviewReadiness == .checking
            || (automaticConflictProgress && row.latestJob?.execution?.state.isActive != true)
    }
    private var nextIntent: MRTodoIntent? {
        row.intents.first { $0.state == .failed } ?? row.intents.first { $0.state == .pending }
    }
    private var needsCLI: Bool { !monitor.availableAssistants.contains(monitor.settings.automation.assistant) }
    private var humanAction: MRHumanAction? {
        guard row.needsAttention, !busy else { return nil }
        let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
        let automatic = target.map {
            item.draftIDsHandledAutomatically(automation: monitor.settings.automation, target: $0,
                assistantPreparing: !needsCLI || monitor.assistantDependencies.isChecking)
        } ?? []
        return MRHumanAction(row: row, assistantReady: !needsCLI,
            confirmationState: monitor.attention.confirmationStates[item.id], automaticallyPublishedDraftIDs: automatic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: onDetails) {
                    MergeRequestTitle(title: item.title, isDraft: item.section == .draftMergeRequests,
                                      lineLimit: 2, font: .callout.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(.Board.boardDetails))
                moreMenu
            }
            HStack(spacing: 6) {
                if allowsRemoval {
                    foreignAuthor
                    Text(verbatim: "·")
                }
                Text(verbatim: "!\(item.id.iid)").monospacedDigit().fixedSize()
                Text(verbatim: "·")
                RepositoryPathText(item.url.gitLabProjectPath).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(metadataHelp)
            if let action = humanAction {
                Group {
                    if let detail = action.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(verbatim: detail).help(Text(verbatim: detail))
                    } else {
                        Text(action.message)
                    }
                }
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let retryError {
                Text(verbatim: retryError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy || row.latestJob?.execution?.state.isActive == true || humanAction != nil || neutralStatus != nil {
                HStack(spacing: 6) {
                    if let job = row.latestJob, job.execution?.state.isActive == true {
                        ProgressView().controlSize(.mini)
                        Text(.Board.boardCompactWorking)
                        Text(verbatim: "·")
                        Text(job.key.assistant.displayName)
                    } else if busy {
                        ProgressView().controlSize(.mini)
                        Text(.Board.boardCompactWorking)
                    } else if humanAction?.action == .retryRun {
                        Button { openAttention(.assistantRuns) } label: { Text(.MRHumanAction.mrHumanActionActionReviewRun) }
                            .buttonStyle(.plain)
                    } else if humanAction == nil, let status = neutralStatus {
                        Text(status).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    primaryAction
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        BoardStatusChip(title: chip.title, symbol: chip.symbol)
                    }
                }
            }
        }
        .onChange(of: row.latestJob?.id) { _, _ in retryError = nil }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if humanAction != nil {
                RoundedRectangle(cornerRadius: 2).fill(.orange.opacity(0.65)).frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { monitor.removeReviewedMergeRequest(item) } label: { Text(.Board.boardRemove) }
        } message: { Text(.Board.boardRemoveExplanation) }
    }

    @ViewBuilder
    private var foreignAuthor: some View {
        let context = ReviewingContext(row: row)
        if let author = context.author {
            HStack(spacing: 4) {
                AvatarView(url: author.avatarURL, size: 18).accessibilityHidden(true)
                Text(verbatim: "@\(author.username)").lineLimit(1)
            }
            .help(Text(verbatim: "\(author.name) (@\(author.username))"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorLabel) + Text(verbatim: ": \(author.name) (@\(author.username))"))
        } else {
            AvatarView(url: nil, size: 18)
                .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
        }
    }

    private var metadataHelp: Text {
        if allowsRemoval {
            let context = ReviewingContext(row: row)
            return Text(context.presenceMessage) + Text(verbatim: "\n") + Text(context.statusMessage)
        }
        return Text(verbatim: item.url.gitLabProjectPath)
    }

    private var neutralStatus: LocalizedStringResource? {
        if item.authorFeedbackStatus?.waitingForReviewer == true { return .AuthorFeedback.authorFeedbackWaitingChip }
        guard allowsRemoval else { return nil }
        let context = ReviewingContext(row: row)
        return context.status == .activityUnknown ? context.presenceMessage : context.statusMessage
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let job = row.latestJob, job.execution?.state.isActive == true {
            Button(role: .destructive) { monitor.cancelAssistantJob(job.id) } label: { Text(.AssistantJobs.assistantJobsStop) }
                .buttonStyle(.plain)
        } else if !busy, let action = humanAction {
            humanActionButton(action)
        }
    }

    @ViewBuilder
    private func humanActionButton(_ action: MRHumanAction) -> some View {
        switch action.action {
        case .reviewRun:
            primary(action.actionLabel) { openAttention(.assistantRuns) }
        case .retryRun:
            if let job = row.latestJob {
                primary(action.actionLabel,
                        enabled: job.execution?.state.isActive == false
                            && monitor.availableAssistants.contains(job.key.assistant)
                            && !AssistantAutomationRunner.isWorking(on: job.key.work)) {
                    guard !isStarting else { return }
                    retryError = nil
                    start {
                        guard monitor.assistantHandoffs.contains(where: { $0.id == job.id }) else { return }
                        await monitor.retryAssistantJob(job.id)
                        retryError = monitor.assistantJobActionError
                    }
                }
            }
        case .reviewDrafts, .reviewApproval:
            primary(action.actionLabel) { openAttention(.drafts) }
        case .verifyFeedback:
            primary(action.actionLabel) { monitor.attention.retryAuthorFeedback(item.id) }
        case .setupAssistant:
            primary(action.actionLabel) { openSettings() }
        case .reviewDecision, .reviewFeedback:
            primary(action.actionLabel) { openAttention(.feedback) }
        case .reviewHandoff, .reviewMerge, .reviewIssue:
            primary(action.actionLabel) { openAttention(.overview) }
        case .handleFeedback:
            primary(action.actionLabel) {
                start {
                    if let status = item.authorFeedbackStatus, !status.followUpNoteIDs.isEmpty,
                       let request = item.authoredRequest {
                        await monitor.runVerifiedAuthorFeedback(request: request, noteIDs: status.followUpNoteIDs,
                                                               fingerprint: status.fingerprint)
                    } else { await monitor.runAttentionFeedback(for: item) }
                }
            }
        case .retryIntent:
            if let intent = nextIntent {
                primary(action.actionLabel) { start { await monitor.runMRTodoIntent(id: intent.id) } }
            } else {
                primary(action.actionLabel) { openAttention(.overview) }
            }
        }
    }

    private func openAttention(_ section: CommandCenterMRDetailSection) {
        if let onAttention { onAttention(section) }
        else { onDetails() }
    }

    private func primary(_ title: LocalizedStringResource, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isStarting { ProgressView().controlSize(.mini) }
            else { Text(title).lineLimit(1) }
        }
        .buttonStyle(.bordered).disabled(isStarting || !enabled)
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        isStarting = true
        Task { defer { isStarting = false }; await operation() }
    }

    private var moreMenu: some View {
        Menu {
            Button(action: onDetails) { Text(.Board.boardDetails) }
            Link(destination: item.url) { Text(.CommandCenter.commandCenterOpenGitLab) }
            if !item.isAuthored {
                Button { start { await monitor.runReview(for: item) } } label: { Text(.CommandCenter.commandCenterReviewRun) }
                    .disabled(isStarting || busy || !monitor.canRunReview(for: item))
            }
            AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                                 workspace: monitor.settings.automation.assistantWorkspace)
            if let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
                Divider()
                MRAutomationScopeMenu(settings: monitor.settings, target: target, projectPath: item.url.gitLabProjectPath)
                if !item.isAuthored, monitor.settings.automation.autoApproveEnabled {
                    Toggle(isOn: Binding(get: { !monitor.settings.autoApproveOptOuts.contains(target) }, set: { enabled in
                        if enabled { monitor.settings.autoApproveOptOuts.remove(target) }
                        else { monitor.settings.autoApproveOptOuts.insert(target) }
                        monitor.settings.save()
                    })) { Text(.CommandCenter.commandCenterAutoApprove) }
                }
            }
            if allowsRemoval {
                Divider()
                Button(role: .destructive) { confirmRemoval = true } label: { Text(.Board.boardRemove) }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
    }

    private struct Chip { let title: LocalizedStringResource; let symbol: String }
    private var chips: [Chip] {
        var result: [Chip] = []
        if item.hasConflict || item.mergeRequest?.hasMergeConflict == true {
            result.append(.init(title: .Board.boardCompactConflict, symbol: "arrow.triangle.branch"))
        }
        if item.failedPipeline || item.mergeRequest?.headPipeline?.status == "failed" {
            result.append(.init(title: .Board.boardCompactPipelineFailed, symbol: "xmark.circle"))
        } else if let pipeline = item.mergeRequest?.headPipeline,
                  ["running", "pending", "created", "preparing", "waiting_for_resource"].contains(pipeline.status) {
            result.append(.init(title: .Board.boardCompactPipelineRunning, symbol: "clock"))
        }
        if humanAction == nil, !busy, !allowsRemoval, max(item.draftCount, item.drafts.count) > 0 {
            result.append(.init(title: .Board.boardCompactDrafts(max(item.draftCount, item.drafts.count)), symbol: "text.bubble"))
        }
        return Array(result.prefix(2))
    }
}

struct BoardStatusChip: View {
    let title: LocalizedStringResource
    var symbol: String = ""
    var tint: Color = .secondary

    var body: some View {
        Label { Text(title) } icon: { if !symbol.isEmpty { Image(systemName: symbol) } }
            .font(.caption2.weight(.medium)).lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint.opacity(0.08), in: Capsule())
            .help(Text(title))
    }
}

/// Only events the router cannot interpret are presented for manual reading.
struct BoardTodoRow: View {
    let todo: Todo
    let monitor: TodoMonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: todo.displayTitle).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
            RepositoryPathText(todo.project.pathWithNamespace).font(.caption).foregroundStyle(.secondary)
            ActionDescriptionText(todo: todo, currentUsername: monitor.glab.currentUsername)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !todo.body.isEmpty && todo.body != todo.displayTitle {
                Text(verbatim: todo.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Link(destination: todo.targetURL) { Text(.Board.boardEventOpen) }.buttonStyle(.plain)
                Spacer()
                Button { withAnimation { monitor.markDoneWithUndo(todo) } } label: { Text(.Board.boardEventMarkRead) }
                    .buttonStyle(.bordered)
                if todo.targetType == .mergeRequest {
                    AssistantContextMenu(mergeRequestURL: todo.targetURL, title: todo.displayTitle,
                                         workspace: monitor.settings.automation.assistantWorkspace)
                        .labelStyle(.iconOnly)
                }
            }
            .font(.caption)
        }
        .controlSize(.small)
    }
}
