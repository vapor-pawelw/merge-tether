import AppKit
import SwiftUI

struct CommandCenterMRCard: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var allowsRemoval = false
    var onAttention: ((CommandCenterMRDetailSection) -> Void)? = nil
    let onDetails: () -> Void

    var body: some View {
        CommandCenterMRCardContent(row: row, monitor: monitor, allowsRemoval: allowsRemoval,
            onAttention: onAttention, onDetails: onDetails,
            presentation: .init(row: row, monitor: monitor, allowsRemoval: allowsRemoval))
    }
}

private struct CommandCenterMRCardContent: View {
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
    private var isDraft: Bool { item.section == .draftMergeRequests }
    private var finishedState: MergeRequestFinishedState? { .init(item.mergeRequest) }
    private var isMuted: Bool {
        monitor.boardActivity(projectID: item.id.projectID, iid: item.id.iid, url: item.url,
            isDraft: isDraft, isFinished: finishedState != nil).isMuted
    }
    private var scopeTarget: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }
    let presentation: MRCardPresentation
    private var busy: Bool { presentation.busy }
    private var nextIntent: MRTodoIntent? {
        row.attentionIntents.first { $0.state == .failed } ?? row.attentionIntents.first { $0.state == .pending }
    }
    private var needsCLI: Bool { !monitor.assistantDependencies.available.contains(monitor.settings.automation.assistant) }
    private var humanAction: MRHumanAction? { presentation.humanAction }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onDetails) {
                    BoardCardTitle(title: item.title, repositoryPath: item.url.gitLabProjectPath,
                        titleColor: isMuted ? .secondary : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(item.title)\n\(item.url.gitLabProjectPath)\n") + Text(.Board.boardDetails))
                BoardMRReferenceLine(iid: item.id.iid, projectID: item.id.projectID, dependencies: item.dependencies)
            }
            if finishedState != nil {
                FinishedMergeRequestStatus(item: item, monitor: monitor)
            } else {
                if humanAction != nil {
                    Text(verbatim: presentation.message).help(Text(verbatim: presentation.message))
                        .font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let retryError {
                    Text(verbatim: retryError).font(.caption).foregroundStyle(isMuted ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let state = monitor.attention.confirmationStates[item.id], state == .failed || state == .changed {
                    Text(state == .failed ? .Menu.menuConfirmFailed : .Menu.menuConfirmChanged)
                        .font(.caption).foregroundStyle(isMuted ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let job = row.latestJob { AssistantJobPreflightNotice(jobID: job.id, monitor: monitor) }
                if presentation.working || presentation.refreshFailed || humanAction != nil || neutralStatus != nil || (isDraft && item.isAuthored) {
                    HStack(spacing: 6) {
                        if presentation.working {
                            ProgressView().controlSize(.mini)
                            if let status = presentation.status { Text(verbatim: status) }
                        } else if presentation.refreshFailed {
                            Label { Text(.AutomationProgress.progressRefreshFailed) } icon: { Image(systemName: "arrow.clockwise") }
                        } else if humanAction?.action == .retryRun {
                            Button { openAttention(.assistantRuns) } label: { Text(.MRHumanAction.mrHumanActionActionReviewRun) }
                                .buttonStyle(.plain)
                        } else if humanAction == nil, let status = neutralStatus {
                            Text(status).font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary).lineLimit(2)
                                .help(Text(reviewingContext.presenceMessage)
                                      + Text(verbatim: "\n") + Text(reviewingContext.statusMessage))
                        }
                        Spacer(minLength: 6)
                        primaryAction
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let nextStep = presentation.nextStep {
                    Text(verbatim: nextStep)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                            BoardStatusChip(title: chip.title, symbol: chip.symbol)
                        }
                    }
                }
            }
        }
        .onChange(of: row.latestJob?.id) { _, _ in retryError = nil }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if humanAction != nil {
                RoundedRectangle(cornerRadius: 2).fill(.orange.opacity(0.65)).frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
        .boardCardInteraction(onDetails: onDetails)
        .contextMenu { menuItems }
        .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { monitor.removeReviewedMergeRequest(item) } label: { Text(.Board.boardRemove) }
        } message: { Text(.Board.boardRemoveExplanation) }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            if let author = ReviewingContext(row: row).author {
                BoardCardAuthor(author: author)
            } else if allowsRemoval {
                AvatarView(url: nil, size: 16)
                    .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                    .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
            }
            Spacer(minLength: 4)
            if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
            else if isDraft { BoardDraftBadge() }
            if finishedState == nil { BoardApprovalProgressBadge(progress: item.approvalProgress) }
            if finishedState == nil, let scopeTarget {
                BoardAutomationToggle(settings: monitor.settings, target: scopeTarget,
                    projectPath: item.url.gitLabProjectPath, isDraft: isDraft)
            }
            BoardPinButton(pin: .mergeRequest(host: monitor.glab.resolvedHost,
                username: monitor.glab.currentUsername, projectID: item.id.projectID, iid: item.id.iid),
                settings: monitor.settings)
            moreMenu
        }
    }

    private var reviewingContext: ReviewingContext { presentation.reviewingContext }
    private var neutralStatus: LocalizedStringResource? { presentation.neutralStatus }

    @ViewBuilder
    private var primaryAction: some View {
        if let job = row.latestJob, job.execution?.state.isActive == true {
            Button(role: .destructive) { monitor.cancelAssistantJob(job.id) } label: { Text(.AssistantJobs.assistantJobsStop) }
                .buttonStyle(.plain)
        } else if let action = humanAction {
            humanActionButton(action).disabled(actionWaitsForRefresh(action) && (busy || presentation.isRefreshingAttention))
        } else if !busy, allowsRemoval {
            reviewingAction
        } else if isDraft, item.isAuthored {
            MarkMergeRequestReadyButton(item: item, monitor: monitor).buttonStyle(.bordered)
        }
    }

    private func actionWaitsForRefresh(_ action: MRHumanAction) -> Bool {
        switch action.action {
        case .reviewDrafts where action.showsDirectPublication && !item.drafts.isEmpty: true
        case .retryRun, .verifyFeedback, .retryDraftVerification, .handleFeedback, .retryIntent: true
        default: false // Opening existing discussions/results never authorizes a GitLab action.
        }
    }

    @ViewBuilder
    private var reviewingAction: some View {
        if let label = reviewingContext.actionLabel {
            switch reviewingContext.nextStep {
            case .runReview:
                if needsCLI {
                    primary(.Board.boardCompactSetupCli) { openSettings() }
                } else {
                    primary(label, enabled: monitor.canRunReview(for: item)) {
                        start { await monitor.runReview(for: item) }
                    }
                }
            case .setupAgent: primary(label) { openSettings() }
            case .monitoring, .viewDiscussions: primary(label) { openAttention(.feedback) }
            case .reviewComments: primary(label) { openAttention(.drafts) }
            case .viewRun: primary(label) { openAttention(.assistantRuns) }
            case .automaticReview, .verifying: EmptyView()
            }
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
        case .reviewDrafts:
            if action.showsDirectPublication && !item.drafts.isEmpty {
                primary(.Menu.menuConfirmPublish, enabled: scopeTarget != nil) {
                    start { await monitor.attention.publishDrafts(of: item.id) }
                }
            } else {
                primary(action.actionLabel) { openAttention(.drafts) }
            }
        case .reviewApproval:
            primary(action.actionLabel) { openAttention(.drafts) }
        case .verifyFeedback:
            primary(action.actionLabel) { monitor.attention.retryAuthorFeedback(item.id) }
        case .retryDraftVerification:
            primary(action.actionLabel) { monitor.attention.retryDraftProofRecovery(item.id) }
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
        BoardActionsMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button(action: onDetails) { Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") } }
        MRCommonMenuItems(item: item, monitor: monitor,
            onRemove: allowsRemoval ? { confirmRemoval = true } : nil)
    }

    private var chips: [MRCardPresentation.Chip] { presentation.chips }

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
    @State private var showingDetails = false

    private var canonicalMRURL: URL? {
        guard todo.targetType == .mergeRequest, let iid = todo.target.iid,
              let host = monitor.glab.resolvedHost else { return nil }
        return todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid)
    }

    private var displayRequest: GitLabMergeRequest? {
        guard let scopeTarget, let iid = scopeTarget.iid,
              let url = todo.targetURL.gitLabTodoMergeRequestURL(host: scopeTarget.host, iid: iid) else { return nil }
        return monitor.boardDisplayRequest(for: scopeTarget, url: url)
    }
    private var isDraft: Bool { displayRequest?.draft ?? todo.isDraft }

    private var isMuted: Bool {
        guard todo.targetType == .mergeRequest, let iid = todo.target.iid, let url = canonicalMRURL else { return todo.isDraft }
        return monitor.boardActivity(projectID: todo.project.id, iid: iid, url: url,
            isDraft: isDraft, isFinished: MergeRequestFinishedState(displayRequest) != nil).isMuted
    }

    private var scopeTarget: MRAutomationScope.Target? {
        guard todo.targetType == .mergeRequest, let iid = todo.target.iid, let url = canonicalMRURL else { return nil }
        return monitor.scopeTarget(projectID: todo.project.id, iid: iid, url: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            VStack(alignment: .leading, spacing: 3) {
                Button { showingDetails = true } label: {
                    ActionDescriptionText(todo: todo, currentUsername: monitor.glab.currentUsername,
                        repositoryPath: todo.project.pathWithNamespace)
                        .font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.leading).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(todo.displayTitle)\n\(todo.project.pathWithNamespace)"))
                if todo.targetType == .mergeRequest, let iid = todo.target.iid {
                    BoardMRReferenceLine(iid: iid, projectID: todo.project.id)
                }
            }
            if let title = todo.target.title ?? (todo.body.isEmpty ? nil : todo.body), !title.isEmpty {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: title))
            }
            HStack {
                if monitor.isAssessingNotice(todo) {
                    ProgressView().controlSize(.small)
                    Text(.AutomationProgress.progressNotice).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                GitLabRefreshButton(monitor: monitor,
                    itemID: scopeTarget?.iid.map { .init(projectID: todo.project.id, iid: $0) })
                Button { monitor.markDoneWithUndo(todo) } label: { Text(.Board.boardEventMarkRead) }
                    .buttonStyle(.bordered)
                    .disabled(monitor.isAssessingNotice(todo))
            }
            .font(.caption)
        }
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .boardCardInteraction { showingDetails = true }
        .contextMenu { menuItems }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                ActionDescriptionText(todo: todo, currentUsername: monitor.glab.currentUsername)
                    .font(.title3).foregroundStyle(.primary)
                Text(verbatim: todo.displayTitle).font(.headline).textSelection(.enabled)
                if todo.targetType == .mergeRequest, let iid = todo.target.iid {
                    BoardMRReferenceLine(iid: iid, projectID: todo.project.id)
                }
                Text(verbatim: todo.project.pathWithNamespace).foregroundStyle(.secondary)
                Text(todo.createdAt, format: .dateTime)
                if !todo.body.isEmpty, todo.body != todo.displayTitle {
                    Text(verbatim: todo.body).textSelection(.enabled)
                }
                Link(destination: todo.targetURL) {
                    Label { Text(.Board.boardEventOpen) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                if let scopeTarget {
                    MRAutomationScopeMenu(monitor: monitor, target: scopeTarget,
                        projectPath: todo.project.pathWithNamespace, isDraft: isDraft)
                }
            }
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            BoardCardAuthor(author: todo.target.author ?? todo.author,
                roleLabel: todo.targetType == .mergeRequest && todo.target.author != nil
                    ? .ReviewingContext.reviewingAuthorLabel : nil)
            Spacer(minLength: 4)
            if isDraft { BoardDraftBadge() }
            if todo.targetType != .mergeRequest, !todo.relativeIdentifier.isEmpty {
                Text(verbatim: todo.relativeIdentifier).font(.caption).foregroundStyle(.secondary)
            }
            if let scopeTarget {
                BoardAutomationToggle(settings: monitor.settings, target: scopeTarget,
                    projectPath: todo.project.pathWithNamespace, isDraft: isDraft)
            }
            BoardPinButton(pin: .todo(host: monitor.glab.resolvedHost,
                username: monitor.glab.currentUsername, id: todo.id), settings: monitor.settings)
            moreMenu
        }
    }

    private var moreMenu: some View {
        BoardActionsMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button { showingDetails = true } label: {
            Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
        }
        Link(destination: todo.targetURL) {
            Label { Text(.Board.boardEventOpen) } icon: { Image(systemName: "arrow.up.right.square") }
        }
        Button { monitor.markDoneWithUndo(todo) } label: {
            Label { Text(.Board.boardEventMarkRead) } icon: { Image(systemName: "checkmark") }
        }
        .disabled(monitor.isAssessingNotice(todo))
        if todo.targetType == .mergeRequest {
            AssistantContextMenu(mergeRequestURL: todo.targetURL, title: todo.displayTitle,
                settings: monitor.settings)
        }
        if let scopeTarget {
            Divider()
            MRAutomationScopeMenu(monitor: monitor, target: scopeTarget,
                projectPath: todo.project.pathWithNamespace, isDraft: isDraft)
        }
    }
}
