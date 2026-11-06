import AppKit
import SwiftUI

struct CommandCenterMRCard: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var allowsRemoval = false
    var onAttention: ((CommandCenterMRDetailSection) -> Void)? = nil
    let onDetails: () -> Void
    @State private var isStarting = false
    @State private var confirmRemoval = false
    @Environment(\.openSettings) private var openSettings

    private var item: MergeRequestAttentionMonitor.Item { row.item }
    private var busy: Bool {
        let state = monitor.attention.confirmationStates[item.id]
        return state == .publishing || state == .approving || item.authorFeedbackStatus?.phase == .checking
            || item.reReviewReadiness == .checking
    }
    private var nextIntent: MRTodoIntent? {
        row.intents.first { $0.state == .failed } ?? row.intents.first { $0.state == .pending }
    }
    private var needsCLI: Bool { !monitor.availableAssistants.contains(monitor.settings.automation.assistant) }
    private var humanAction: MRHumanAction? {
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
                Text(verbatim: "!\(item.id.iid)").monospacedDigit()
                Text(verbatim: "·")
                RepositoryPathText(item.url.gitLabProjectPath).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            if !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(chips.prefix(3).enumerated()), id: \.offset) { _, chip in
                        BoardStatusChip(title: chip.title, symbol: chip.symbol, tint: chip.tint)
                    }
                    if chips.count > 3 {
                        Text(verbatim: "+\(chips.count - 3)").font(.caption2).foregroundStyle(.secondary)
                            .help(Text(.Board.boardCompactMoreStatuses(chips.count - 3)))
                    }
                }
            }
            if let action = humanAction {
                Group {
                    if let detail = action.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(verbatim: detail)
                    } else {
                        Text(action.message)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let job = row.latestJob, job.execution?.state.isActive == true {
                    ProgressView().controlSize(.mini)
                    Text(job.key.assistant.displayName).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: onDetails) { Text(.Board.boardDetails) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                primaryAction
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if row.needsAttention {
                RoundedRectangle(cornerRadius: 2).fill(.orange.opacity(0.65)).frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { monitor.removeReviewedMergeRequest(item) } label: { Text(.Board.boardRemove) }
        } message: { Text(.Board.boardRemoveExplanation) }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if let job = row.latestJob, job.execution?.state.isActive == true {
            Button(role: .destructive) { monitor.cancelAssistantJob(job.id) } label: { Text(.AssistantJobs.assistantJobsStop) }
                .buttonStyle(.plain)
        } else if let action = humanAction {
            humanActionButton(action)
        } else if item.awaitingRemoteVerification || item.requiresDiscussionRecheck
                    || monitor.attention.confirmationStates[item.id] == .changed {
            primary(.Board.boardCompactReviewChecks, action: onDetails)
        } else if item.canConfirmReReview {
            primary(.Board.boardCompactReviewDecision, action: onDetails)
        } else if !item.drafts.isEmpty {
            primary(.Board.boardCompactReviewDrafts, action: onDetails)
        } else if item.canApprove {
            primary(.Board.boardCompactReviewApproval, action: onDetails)
        } else if item.authorFeedbackStatus?.phase == .failed {
            primary(.AuthorFeedback.authorFeedbackRetry) { monitor.attention.retryAuthorFeedback(item.id) }
        } else if item.authorFeedbackStatus?.needsAttention == true {
            primary(.Board.boardCompactReviewChecks, action: onDetails)
        } else if let intent = nextIntent {
            if intent.kind != .refresh && needsCLI {
                primary(.Board.boardCompactSetupCli) { openSettings() }
            } else {
                primary(intent.state == .failed ? .Board.boardIntentRetry : BoardMRIntentActions.action(intent.kind)) {
                    start { await monitor.runMRTodoIntent(id: intent.id) }
                }
            }
        } else if let job = row.latestJob, MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state) {
            if needsCLI { primary(.Board.boardCompactSetupCli) { openSettings() } }
            else { primary(.AssistantJobs.assistantJobsRetry) { start { await monitor.retryAssistantJob(job.id) } } }
        } else if item.needsMerge {
            primary(.Board.boardCompactMerge, action: onDetails)
        } else if item.needsPipelineHandoff {
            primary(.Board.boardCompactReviewHandoff, action: onDetails)
        } else if item.reReviewReadiness != nil {
            primary(.Board.boardCompactReviewChecks, action: onDetails)
        } else if let action = monitor.attentionFeedbackAction(for: item), action == .ready(.assistant) || action == .failed {
            primary(.Board.boardIntentHandleFeedback) { start { await monitor.runAttentionFeedback(for: item) } }
        } else if !item.isAuthored {
            if needsCLI { primary(.Board.boardCompactSetupCli) { openSettings() } }
            else {
                primary(.CommandCenter.commandCenterReviewRun, enabled: monitor.canRunReview(for: item)) {
                    start { await monitor.runReview(for: item) }
                }
            }
        }
    }

    @ViewBuilder
    private func humanActionButton(_ action: MRHumanAction) -> some View {
        switch action.action {
        case .reviewRun:
            primary(action.actionLabel) { openAttention(.assistantRuns) }
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

    private struct Chip { let title: LocalizedStringResource; let symbol: String; let tint: Color }
    private var chips: [Chip] {
        var result: [Chip] = []
        if let feedback = item.authorFeedbackStatus {
            switch feedback.phase {
            case .failed:
                result.append(.init(title: .AuthorFeedback.authorFeedbackVerificationFailedChip, symbol: "exclamationmark.shield", tint: .orange))
            case .checking:
                result.append(.init(title: .AuthorFeedback.authorFeedbackVerifyingChip, symbol: "arrow.triangle.2.circlepath", tint: .blue))
            case .waitingPublication:
                if item.drafts.isEmpty && !item.awaitingRemoteVerification && !item.requiresDiscussionRecheck {
                    result.append(.init(title: .AuthorFeedback.authorFeedbackPendingRepliesChip, symbol: "text.bubble", tint: .blue))
                }
            case .complete:
                if feedback.needsAttention {
                    result.append(.init(title: .AuthorFeedback.authorFeedbackNeedsWorkChip, symbol: "text.bubble", tint: .orange))
                } else if feedback.waitingForReviewer {
                    result.append(.init(title: .AuthorFeedback.authorFeedbackWaitingChip, symbol: "clock", tint: .secondary))
                }
            }
        }
        if let intent = nextIntent, intent.kind != .refresh, needsCLI {
            result.append(.init(title: .Board.boardCompactCliRequired, symbol: "terminal", tint: .orange))
        }
        if humanAction == nil && (item.awaitingRemoteVerification || item.requiresDiscussionRecheck) {
            result.append(.init(title: .Board.boardCompactVerification, symbol: "shield.lefthalf.filled", tint: .orange))
        }
        if monitor.attention.confirmationStates[item.id] == .failed || monitor.attention.confirmationStates[item.id] == .changed {
            result.append(.init(title: .Board.boardCompactRecheck, symbol: "exclamationmark.circle", tint: .orange))
        }
        if let job = row.latestJob {
            if job.execution?.state.isActive == true {
                result.append(.init(title: .Board.boardCompactWorking, symbol: "arrow.triangle.2.circlepath", tint: .blue))
            } else if humanAction == nil && MergeRequestBoardSnapshot.Row.jobNeedsAttention(job.execution?.state) {
                result.append(.init(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle", tint: .orange))
            }
        }
        if !item.drafts.isEmpty { result.append(.init(title: .Board.boardCompactDrafts(item.drafts.count), symbol: "text.bubble", tint: .blue)) }
        if item.hasConflict { result.append(.init(title: .Board.boardCompactConflict, symbol: "arrow.triangle.branch", tint: .orange)) }
        if item.failedPipeline || item.mergeRequest?.headPipeline?.status == "failed" {
            result.append(.init(title: .Board.boardCompactPipelineFailed, symbol: "xmark.circle", tint: .orange))
        }
        if let pipeline = item.mergeRequest?.headPipeline, ["running", "pending", "created", "preparing", "waiting_for_resource"].contains(pipeline.status) {
            result.append(.init(title: .Board.boardCompactPipelineRunning, symbol: "clock", tint: .blue))
        }
        let showResidualDiscussion = item.authorFeedbackStatus.map { $0.phase == .complete && !$0.needsAttention } ?? true
        if showResidualDiscussion && (item.needsDiscussion || !item.feedback.isEmpty) {
            result.append(.init(title: .Board.boardCompactFeedback, symbol: "text.bubble", tint: .orange))
        }
        if item.needsChanges { result.append(.init(title: .Board.boardCompactChanges, symbol: "pencil", tint: .orange)) }
        if item.reReviewReadiness != nil || item.canConfirmReReview {
            result.append(.init(title: .Board.boardCompactReReview, symbol: "person.crop.circle.badge.checkmark", tint: .orange))
        }
        if let intent = nextIntent, result.isEmpty {
            result.append(.init(title: BoardMRIntentActions.title(intent.kind), symbol: "bolt", tint: .orange))
        }
        return result
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
