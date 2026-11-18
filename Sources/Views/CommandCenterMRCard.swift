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
    private var isDraft: Bool { row.isDraft }
    private var finishedState: MergeRequestFinishedState? { .init(row.displayRequest) }
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
                    BoardCardTitle(title: row.displayTitle, repositoryPath: row.displayURL.gitLabProjectPath,
                        titleColor: isMuted ? .secondary : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: "\(row.displayTitle)\n\(row.displayURL.gitLabProjectPath)\n") + Text(.Board.boardDetails))
                BoardMRReferenceLine(iid: item.id.iid, projectID: item.id.projectID, dependencies: row.displayItem.dependencies)
            }
            if finishedState != nil {
                FinishedMergeRequestStatus(item: row.displayItem, monitor: monitor)
            } else {
                if humanAction != nil {
                    // The orange icon and edge carry urgency; the sentence stays high-contrast.
                    Label { Text(verbatim: presentation.message).foregroundStyle(Color.primary) } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                    }
                    .labelStyle(BoardCardStatusLabelStyle())
                    .font(.callout.weight(.medium))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(Text(verbatim: presentation.message))
                }
                if let retryError {
                    Label { Text(verbatim: retryError) } icon: {
                        Image(systemName: "xmark.octagon").foregroundStyle(isMuted ? Color.secondary : Color.red)
                    }
                    .labelStyle(BoardCardStatusLabelStyle())
                    .font(.subheadline).foregroundStyle(isMuted ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let state = monitor.attention.confirmationStates[item.id], state == .failed || state == .changed {
                    Label { Text(state == .failed ? .Menu.menuConfirmFailed : .Menu.menuConfirmChanged) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(isMuted ? Color.secondary : Color.orange)
                    }
                    .labelStyle(BoardCardStatusLabelStyle())
                    .font(.subheadline).foregroundStyle(isMuted ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let job = row.latestJob { AssistantJobPreflightNotice(jobID: job.id, monitor: monitor) }
                if presentation.working || presentation.refreshFailed || humanAction != nil || neutralStatus != nil || (isDraft && item.isAuthored) {
                    HStack(spacing: 6) {
                        if presentation.working {
                            if let status = presentation.status {
                                MRActivityStatus(status: status,
                                    startedAt: monitor.activityStartedAt(for: item, activity: presentation.activity), effect: presentation.activityEffect)
                            }
                        } else if presentation.refreshFailed {
                            Label { Text(verbatim: presentation.refreshFailureLabel ?? String(localized: .AutomationProgress.progressRefreshFailed)) }
                                icon: { Image(systemName: "arrow.clockwise") }
                                .help(presentation.refreshFailureHelp ?? "")
                        } else if let waiting = shownRequirements {
                            // One blocker per line, in the same style as the merge blockers below.
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(waiting.requirements.enumerated()), id: \.offset) { _, line in
                                    BoardRequirementLine(text: line, isMuted: isMuted)
                                }
                            }
                            .font(.callout)
                        } else if humanAction == nil, let status = neutralStatus {
                            Text(status).font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary).lineLimit(2)
                                .help(Text(reviewingContext.presenceMessage)
                                      + Text(verbatim: "\n") + Text(reviewingContext.statusMessage))
                        }
                        Spacer(minLength: 6)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !presentation.working, let drafts = MRPendingDraftsSummary(item: item) {
                    Label { Text(drafts.message).foregroundStyle(isMuted ? Color.secondary : Color.primary) } icon: {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                    }
                    .labelStyle(BoardCardStatusLabelStyle())
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let chain = presentation.stepChain {
                    BoardStepChain(steps: chain.steps.map { String(localized: $0) }, current: chain.current)
                } else if let nextStep = presentation.nextStep {
                    Text(verbatim: nextStep)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MergeActionsView(item: item, monitor: monitor, evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext,
                    actionsBlocked: presentation.actionsBlocked, onReviewFeedback: { openAttention(.feedback) },
                    showsExplanations: false, showsRecoveryActions: false, textFont: .callout,
                    coveredBlockers: shownRequirements?.coveredBlockers ?? [],
                    hidesBlockedActions: presentation.working, statusTrailer: {
                        // Short state chips and automation rules sit together, above the action row.
                        VStack(alignment: .leading, spacing: 5) {
                            if !chips.isEmpty {
                                HStack(spacing: 5) {
                                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                                        BoardStatusChip(title: chip.title, symbol: chip.symbol)
                                    }
                                }
                            }
                            MREffectivePolicySummary(row: row, monitor: monitor,
                                excluding: [presentation.message, presentation.nextStep ?? ""], holdsOnly: true)
                        }
                    }) { hasDirectMergeAction in
                    if humanAction?.action == .retryRun {
                        Button { openAttention(.assistantRuns) } label: { Text(.MRHumanAction.mrHumanActionActionReviewRun) }
                            .buttonStyle(.plain)
                    }
                    Spacer(minLength: 6)
                    primaryAction(hasDirectMergeAction: hasDirectMergeAction)
                    if presentation.showsAdditionalCommentReview {
                        Button { start { await monitor.attention.finishCommentReview(item) } } label: {
                            Text(.CommentReview.commentReviewFinish)
                        }
                        .buttonStyle(.bordered)
                        .disabled(presentation.actionsBlocked || !item.canFinishCommentReview)
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
                PersonAvatar(url: nil, size: 16)
                    .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                    .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
            }
            Spacer(minLength: 4)
            if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
            else if isDraft { BoardDraftBadge() }
            if finishedState == nil {
                BoardApprovalProgressBadge(progress: row.displayItem.approvalProgress, reviewers: row.displayRequest?.reviewers,
                    viewerUsername: monitor.glab.currentUsername, isOwnMergeRequest: row.isOwnMergeRequest(viewer: monitor.glab.currentUsername))
            }
            HStack(spacing: 0) {
                if finishedState == nil, let scopeTarget {
                    BoardAutomationToggle(monitor: monitor, target: scopeTarget,
                        projectPath: item.url.gitLabProjectPath, isDraft: isDraft,
                        policy: MREffectivePolicySummary.presentation(row: row, monitor: monitor).0)
                }
                BoardPinButton(pin: .mergeRequest(host: monitor.glab.resolvedHost,
                    username: monitor.glab.currentUsername, projectID: item.id.projectID, iid: item.id.iid),
                    settings: monitor.settings)
                moreMenu
            }
        }
    }

    private var reviewingContext: ReviewingContext { presentation.reviewingContext }
    /// Requirements are listed only where the neutral status would have shown them.
    private var shownRequirements: MRWaitingStatus? {
        guard humanAction == nil, neutralStatus != nil, let waiting = presentation.waitingStatus,
              !waiting.requirements.isEmpty else { return nil }
        return waiting
    }
    private var neutralStatus: LocalizedStringResource? {
        if monitor.authoredMergeRequests.requests.contains(where: {
            $0.request.projectID == item.id.projectID && $0.request.iid == item.id.iid
                && $0.request.sha == item.mergeRequest?.sha && $0.submissionState != .none
        }) { return nil }
        return presentation.neutralStatus
    }

    @ViewBuilder
    private func primaryAction(hasDirectMergeAction: Bool) -> some View {
        if let job = row.latestJob, job.execution?.state.isActive == true {
            Button(role: .destructive) { monitor.cancelAssistantJob(job.id) } label: { Text(.AssistantJobs.assistantJobsStop) }
                .buttonStyle(.plain)
        } else if let action = humanAction {
            if !hasDirectMergeAction || ![.reviewMerge, .reviewDecision].contains(action.action) {
                humanActionButton(action).disabled(actionWaitsForRefresh(action) && (busy || presentation.isRefreshingAttention))
            }
        } else if !busy, allowsRemoval {
            reviewingAction
        } else if isDraft, item.isAuthored {
            MarkMergeRequestReadyButton(item: item, monitor: monitor).buttonStyle(.bordered)
        }
    }

    private func actionWaitsForRefresh(_ action: MRHumanAction) -> Bool {
        switch action.action {
        case .reviewDrafts where action.draftPublicationShortcut(for: item.drafts) == .publishAll: true
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
                    primary(label, cta: .runReview, enabled: monitor.canRunReview(for: item)) {
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
                primary(action.actionLabel, cta: .retryRun,
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
            if action.kind == .commentReview {
                primary(.CommentReview.commentReviewFinish, cta: .finishCommentReview, enabled: item.canFinishCommentReview) {
                    start { await monitor.attention.finishCommentReview(item) }
                }
            } else {
                switch action.draftPublicationShortcut(for: item.drafts) {
                case .review:
                    primary(.CommentReview.commentReviewReviewBeforePublishing) { openAttention(.drafts) }
                case .publishAll:
                    primary(.CommentReview.commentReviewPublishAll, cta: .publishComments, enabled: scopeTarget != nil) {
                        let displayed = item
                        start { await monitor.attention.publishDrafts(of: displayed.id, boardSnapshot: displayed) }
                    }
                case nil:
                    primary(action.actionLabel) { openAttention(.drafts) }
                }
            }
        case .reviewApproval:
            primary(action.actionLabel) { openAttention(.drafts) }
        case .verifyFeedback:
            primary(action.actionLabel, cta: .verifyFeedback) { monitor.attention.retryAuthorFeedback(item.id) }
        case .retryDraftVerification:
            primary(action.actionLabel, cta: .retryDraftVerification) { monitor.attention.retryDraftProofRecovery(item.id) }
        case .setupAssistant:
            primary(action.actionLabel) { openSettings() }
        case .reviewDecision, .reviewFeedback:
            primary(action.actionLabel) { openAttention(.feedback) }
        case .reviewHandoff, .reviewMerge, .reviewIssue:
            primary(action.actionLabel) { openAttention(.overview) }
        case .handleFeedback:
            primary(action.actionLabel, cta: .handleFeedback) {
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
                primary(action.actionLabel, cta: MRActionCTA(intent: intent.kind)) {
                    start { await monitor.runMRTodoIntent(id: intent.id) }
                }
            } else {
                primary(action.actionLabel) { openAttention(.overview) }
            }
        }
    }

    private func openAttention(_ section: CommandCenterMRDetailSection) {
        if let onAttention { onAttention(section) }
        else { onDetails() }
    }

    @ViewBuilder
    private func primary(_ title: LocalizedStringResource, cta: MRActionCTA? = nil, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        if let cta {
            Button(action: action) { MRActionLabel(title: title, cta: cta, working: isStarting) }
                .buttonStyle(.bordered).disabled(isStarting || !enabled).mrActionHelp(cta)
        } else {
            Button(action: action) {
                if isStarting { ProgressView().controlSize(.mini) }
                else { Text(title).lineLimit(1) }
            }
            .buttonStyle(.bordered).disabled(isStarting || !enabled)
        }
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

/// Keeps wrapped status text aligned after a fixed-width leading symbol.
struct BoardCardStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 14)
            configuration.title
        }
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
                    MRActivityStatus(status: MRActivity.agentStatus(.AutomationProgress.progressNotice,
                        assistant: monitor.settings.automation.assistant), startedAt: nil, effect: .aiCheck)
                        .foregroundStyle(.secondary)
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
            HStack(spacing: 0) {
                if let scopeTarget {
                    BoardAutomationToggle(monitor: monitor, target: scopeTarget,
                        projectPath: todo.project.pathWithNamespace, isDraft: isDraft)
                }
                BoardPinButton(pin: .todo(host: monitor.glab.resolvedHost,
                    username: monitor.glab.currentUsername, id: todo.id), settings: monitor.settings)
                moreMenu
            }
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
            CopyMergeRequestLinkButton(url: todo.targetURL)
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

/// A merge requirement that someone else must satisfy; the lock marks it as a blocker, not app work.
struct BoardRequirementLine: View {
    let text: LocalizedStringResource
    var isMuted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 14)
            Text(text).foregroundStyle(isMuted ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The automation order with the current step emphasised and later steps dimmed.
struct BoardStepChain: View {
    let steps: [String]
    let current: Int

    var body: some View {
        StatusFlowLayout(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 4) {
                    if index > 0 { Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary) }
                    Text(verbatim: step)
                        .fontWeight(index == current ? .semibold : .regular)
                        .foregroundStyle(index == current ? AnyShapeStyle(.primary)
                            : index < current ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
            }
        }
        .font(.subheadline)
        .help(Text(.CommentReview.commentReviewStepsHelp))
        .accessibilityElement(children: .combine)
    }
}
