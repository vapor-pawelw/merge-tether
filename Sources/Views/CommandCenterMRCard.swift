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
                    BoardCardTitle(title: item.title, repositoryPath: item.url.gitLabProjectPath)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(item.title)\n\(item.url.gitLabProjectPath)\n") + Text(.Board.boardDetails))
                BoardPinButton(pin: .mergeRequest(host: monitor.glab.resolvedHost,
                    username: monitor.glab.currentUsername, projectID: item.id.projectID, iid: item.id.iid),
                    settings: monitor.settings)
                moreMenu
            }
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
            footer
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let author = ReviewingContext(row: row).author {
                    BoardCardAuthor(author: author)
                } else if allowsRemoval {
                    AvatarView(url: nil, size: 16)
                        .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                        .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
                }
                Spacer(minLength: 4)
                if item.section == .draftMergeRequests { BoardDraftBadge() }
                BoardMRIdentifier(iid: item.id.iid)
            }
            BoardRepositoryFooter(path: item.url.gitLabProjectPath)
        }
        .help(metadataHelp)
    }

    private var metadataHelp: Text {
        if allowsRemoval {
            let context = ReviewingContext(row: row)
            return Text(context.presenceMessage) + Text(verbatim: "\n") + Text(context.statusMessage)
                + Text(verbatim: "\n\(item.url.gitLabProjectPath)")
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
            Button(action: onDetails) { Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") } }
            Link(destination: item.url) { Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") } }
            if !item.isAuthored {
                Button { start { await monitor.runReview(for: item) } } label: { Label { Text(.CommandCenter.commandCenterReviewRun) } icon: { Image(systemName: "text.magnifyingglass") } }
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
                    })) { Label { Text(.CommandCenter.commandCenterAutoApprove) } icon: { Image(systemName: "checkmark.seal") } }
                }
            }
            if allowsRemoval {
                Divider()
                Button(role: .destructive) { confirmRemoval = true } label: { Label { Text(.Board.boardRemove) } icon: { Image(systemName: "minus.circle") } }
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
            HStack(alignment: .top, spacing: 6) {
                Link(destination: todo.targetURL) {
                    ActionDescriptionText(todo: todo, currentUsername: monitor.glab.currentUsername,
                        repositoryPath: todo.project.pathWithNamespace)
                        .font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(todo.displayTitle)\n\(todo.project.pathWithNamespace)"))
                BoardPinButton(pin: .todo(host: monitor.glab.resolvedHost,
                    username: monitor.glab.currentUsername, id: todo.id), settings: monitor.settings)
                moreMenu
            }
            if let title = todo.target.title ?? (todo.body.isEmpty ? nil : todo.body), !title.isEmpty {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: title))
            }
            HStack {
                Spacer(minLength: 0)
                Button { monitor.markDoneWithUndo(todo) } label: { Text(.Board.boardEventMarkRead) }
                    .buttonStyle(.bordered)
            }
            .font(.caption)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BoardCardAuthor(author: todo.target.author ?? todo.author,
                        roleLabel: todo.targetType == .mergeRequest && todo.target.author != nil
                            ? .ReviewingContext.reviewingAuthorLabel : nil)
                    Spacer(minLength: 4)
                    if todo.isDraft { BoardDraftBadge() }
                    if todo.targetType == .mergeRequest, let iid = todo.target.iid {
                        BoardMRIdentifier(iid: iid)
                    } else if !todo.relativeIdentifier.isEmpty {
                        Text(verbatim: todo.relativeIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
                BoardRepositoryFooter(path: todo.project.pathWithNamespace)
            }
        }
        .controlSize(.small)
    }

    private var moreMenu: some View {
        Menu {
            Link(destination: todo.targetURL) {
                Label { Text(.Board.boardEventOpen) } icon: { Image(systemName: "arrow.up.right.square") }
            }
            Button { monitor.markDoneWithUndo(todo) } label: {
                Label { Text(.Board.boardEventMarkRead) } icon: { Image(systemName: "checkmark") }
            }
            if todo.targetType == .mergeRequest {
                AssistantContextMenu(mergeRequestURL: todo.targetURL, title: todo.displayTitle,
                    workspace: monitor.settings.automation.assistantWorkspace)
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
    }
}
