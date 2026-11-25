import AppKit
import SwiftUI
import MergeTetherRemote

struct CommandCenterMRCard: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var allowsRemoval = false
    var onAttention: ((CommandCenterMRDetailSection) -> Void)? = nil
    let onDetails: () -> Void

    private var isNewReview: Bool { monitor.isNewReviewAssignment(row) }

    var body: some View {
        CommandCenterMRCardContent(row: row, monitor: monitor, allowsRemoval: allowsRemoval,
            onAttention: onAttention, onDetails: onDetails, onActivate: activate, isNewReview: isNewReview,
            presentation: .init(row: row, monitor: monitor, allowsRemoval: allowsRemoval))
    }

    func activate() {
        if isNewReview {
            monitor.markReviewAssignmentSeen(row.displayItem)
        } else {
            onDetails()
        }
    }
}

private struct CommandCenterMRCardContent: View {
    let row: MergeRequestBoardSnapshot.Row
    let monitor: TodoMonitorService
    var allowsRemoval = false
    var onAttention: ((CommandCenterMRDetailSection) -> Void)? = nil
    let onDetails: () -> Void
    let onActivate: () -> Void
    let isNewReview: Bool
    @State private var isStarting = false
    @State private var pendingPrimary: (title: LocalizedStringResource, cta: MRActionCTA?)?
    @State private var finishingCommentReview = false
    @State private var retryError: String?
    @State private var confirmRemoval = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    private let contentTopInset: CGFloat = 14

    private var item: MergeRequestAttentionMonitor.Item { row.item }
    private var isDraft: Bool { row.isDraft }
    private var finishedState: MergeRequestFinishedState? { .init(row.displayRequest) }
    private var isMuted: Bool {
        if let entry = row.manualOrderEntry { return !entry.group.automationEnabled }
        return monitor.boardActivity(projectID: item.id.projectID, iid: item.id.iid, url: item.url,
            isDraft: isDraft, isFinished: finishedState != nil).isMuted
    }
    private var scopeTarget: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }
    let presentation: MRCardPresentation
    private var busy: Bool { presentation.busy }
    private var humanAction: MRHumanAction? { presentation.humanAction }

    private var contentOpacity: Double { isDraft ? 0.5 : 1 }
    private var showsInlineHide: Bool { isNewReview && row.waitsForReviewStart && reviewingContext.nextStep == .runReview }
    private var newReviewTint: Color {
        colorScheme == .dark ? Color(red: 0.38, green: 0.88, blue: 0.77) : Color(red: 0.04, green: 0.39, blue: 0.33)
    }

    var body: some View {
        Group {
            if finishedState == nil {
                MergeActionsView(item: item, monitor: monitor, evidenceMatchesCatalogContext: row.evidenceMatchesCatalogContext,
                    actionsBlocked: presentation.actionsBlocked || isStarting || finishingCommentReview,
                    onReviewFeedback: { openAttention(.feedback) },
                    showsExplanations: false, showsRecoveryActions: false, textFont: .callout,
                    coveredBlockers: shownRequirements?.coveredBlockers ?? [],
                    hidesBlockedActions: presentation.working, highlightedSubmission: presentation.mergeStage?.submission,
                    statusTopPadding: humanAction == nil ? 0 : 8, statusOpacity: contentOpacity,
                    statusLayout: MRCardStatusLayout(heading: cardHeading, status: cardStatus.opacity(contentOpacity)),
                    statusTrailer: { mergeActionStatus }) { hasDirectMergeAction in
                    if isNewReview && !showsInlineHide {
                        Button(action: markReviewSeen) {
                            Label { Text(.Board.boardReviewAssignmentSeen) } icon: { Image(systemName: "checkmark") }
                        }
                        .buttonStyle(.bordered)
                    }
                    if humanAction?.action == .retryRun {
                        Button { openAttention(.assistantRuns) } label: { Text(.MRHumanAction.mrHumanActionActionReviewRun) }
                            .buttonStyle(.plain)
                    }
                    Spacer(minLength: 6)
                    if let pendingPrimary {
                        primary(pendingPrimary.title, cta: pendingPrimary.cta, enabled: false) {}
                    } else {
                        primaryAction(hasDirectMergeAction: hasDirectMergeAction)
                    }
                    if showsInlineHide {
                        Button {
                            monitor.removeReviewedMergeRequest(row.displayItem)
                        } label: { Text(.Board.boardReviewAssignmentHide) }
                        .buttonStyle(.plain)
                    }
                    if presentation.showsAdditionalCommentReview || finishingCommentReview {
                        Button {
                            markReviewSeen()
                            guard confirmMRAction(.finishCommentReview, title: .CommentReview.commentReviewFinish) else { return }
                            finishingCommentReview = true
                            Task {
                                defer { finishingCommentReview = false }
                                await monitor.attention.finishCommentReview(item)
                            }
                        } label: {
                            MRActionProgressLabel(working: finishingCommentReview) { Text(.CommentReview.commentReviewFinish) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isStarting || finishingCommentReview || presentation.actionsBlocked || !item.canFinishCommentReview)
                    }
                }
            } else {
                MRCardMetadataLayout(keepsBadgesUnderActions: true) {
                    cardHeading
                    cardStatus.opacity(contentOpacity)
                }
            }
        }
        .onChange(of: row.latestJob?.id) { _, _ in retryError = nil }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.leading, .bottom, .trailing], 16)
        .padding(.top, contentTopInset)
        .overlay {
            Group {
                if isNewReview {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(newReviewTint.opacity(0.65), lineWidth: 1)
                        .shadow(color: newReviewTint.opacity(0.30), radius: 3)
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                        .opacity(contentOpacity)
                }
            }
            .allowsHitTesting(false)
        }
        .boardCardInteraction(title: row.displayTitle, repositoryPath: row.displayURL.gitLabProjectPath,
            iid: item.id.iid, background: colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.95),
            backgroundOpacity: contentOpacity, actionLabel: newReviewActionLabel, onActivate: onActivate)
        .contextMenu { menuItems }
        .confirmationDialog(Text(.Board.boardReviewAssignmentHide), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(role: .destructive) { monitor.removeReviewedMergeRequest(row.displayItem) } label: { Text(.Board.boardReviewAssignmentHide) }
        } message: { Text(.Board.boardReviewAssignmentHideExplanation) }
        .environment(\.gitLabPersonSourceURL, row.displayURL)
    }

    @ViewBuilder private var cardHeading: some View {
        let actionTitle: LocalizedStringResource = isNewReview ? .Board.boardReviewAssignmentSeen : .Board.boardDetails
        cardReference
        Button(action: onActivate) {
            BoardCardTitle(title: row.displayTitle, repositoryPath: row.displayURL.gitLabProjectPath,
                titleColor: !isDraft && isMuted ? .secondary : .primary)
                .opacity(contentOpacity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "\(row.displayTitle)\n\(row.displayURL.gitLabProjectPath)\n") + Text(actionTitle))
        .accessibilityHint(Text(actionTitle))
        HStack(spacing: 0) {
            author
            Spacer(minLength: 16)
            if finishedState == nil {
                BoardMRApprovalBadge(row: row, monitor: monitor)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        cardActions.zIndex(1)
        statusBadges.zIndex(1)
    }

    @ViewBuilder private var cardReference: some View {
        let reference = BoardMRReferenceLine(iid: item.id.iid, projectID: item.id.projectID,
            repositoryPath: row.displayURL.gitLabProjectPath, contentOpacity: contentOpacity)
        let issues = monitor.issueTags(for: row.displayRequest)
        if issues.isEmpty {
            reference
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                reference
                MRIssueTag(issues: issues)
            }
        }
    }

    private var cardStatus: some View {
        let mergeActivity = presentation.mergeActivity
        let showsWorkingStatus = presentation.working && mergeActivity == nil
        return Group {
            if finishedState != nil {
                FinishedMergeRequestStatus(item: row.displayItem, monitor: monitor)
            } else {
                if let stage = presentation.mergeStage {
                    MRMergeStageBanner(stage: stage, startedAt: monitor.activityStartedAt(for: item, activity: mergeActivity))
                }
                if isNewReview, let scopeTarget,
                   let notice = monitor.settings.reviewAssignments.incomingReviewFilter.notice(for: scopeTarget) {
                    IncomingReviewFilterNoticeView(notice: notice)
                }
                attentionAndDrafts
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
                if showsWorkingStatus || presentation.refreshFailed || humanAction != nil || neutralStatus != nil || (isDraft && item.isAuthored) {
                    Group {
                        if showsWorkingStatus {
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
                                BoardWaitingRequirements(waiting: waiting, isMuted: isMuted)
                            }
                            .font(.callout)
                        } else if let message = presentation.statusPeopleMessage {
                            PeopleMessageLabel(message: message)
                                .font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary)
                        } else if humanAction == nil, let status = neutralStatus {
                            Text(status).font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary).lineLimit(2)
                                .help(Text(reviewingContext.presenceMessage)
                                      + Text(verbatim: "\n") + Text(reviewingContext.statusMessage))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let chain = presentation.stepChain {
                    BoardStepChain(steps: chain.steps.map { String(localized: $0) }, current: chain.current)
                } else if let nextStep = presentation.nextStep {
                    Text(verbatim: nextStep)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var attentionAndDrafts: some View {
        let drafts = presentation.working ? nil : MRPendingDraftsSummary(item: item)
        if humanAction != nil {
            MergeRequestAttentionCallout(message: presentation.message)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .help(Text(verbatim: presentation.message))
        }
        if let drafts {
            Label {
                Group {
                    if let message = drafts.peopleMessage { PeopleMessageLabel(message: message) }
                    else { Text(drafts.message) }
                }.foregroundStyle(isMuted ? Color.secondary : Color.primary)
            } icon: {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .labelStyle(BoardCardStatusLabelStyle())
            .layoutValue(key: MRCardContentSpacing.self, value: humanAction != nil ? 16 : 8)
        }
    }

    @ViewBuilder private var mergeActionStatus: some View {
        if chips.isEmpty {
            automationHolds
        } else {
            VStack(alignment: .leading, spacing: 5) {
                StatusFlowLayout(spacing: 5) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        BoardStatusChip(title: chip.title, symbol: chip.symbol)
                    }
                }
                automationHolds
            }
        }
    }

    private var automationHolds: some View {
        MREffectivePolicySummary(row: row, monitor: monitor,
            excluding: [presentation.message, presentation.nextStep ?? "",
                presentation.mergeStage.map { String(localized: $0.title) } ?? ""], holdsOnly: true)
    }

    private var draftBadgeTint: Color {
        colorScheme == .dark
            ? Color(red: 0.79, green: 0.70, blue: 0.92)
            : Color(red: 0.38, green: 0.27, blue: 0.52)
    }

    @ViewBuilder
    private var author: some View {
        if let author = ReviewingContext(row: row).author {
            BoardCardAuthor(author: author, contentOpacity: contentOpacity)
        } else if allowsRemoval {
            PersonAvatar(url: nil, size: 16)
                .opacity(contentOpacity)
                .help(Text(.ReviewingContext.reviewingAuthorUnknown))
                .accessibilityLabel(Text(.ReviewingContext.reviewingAuthorUnknown))
        }
    }

    private var statusBadges: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let dependencies = RemoteMRDependencies(summary: row.displayItem.dependencies, projectID: item.id.projectID) {
                MRDependencyBadge(dependencies: dependencies)
            }
            if isNewReview {
                Button(action: markReviewSeen) {
                    Label { Text(.Board.boardReviewAssignmentNew) } icon: {
                        Circle().fill(newReviewTint).frame(width: 5, height: 5)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(newReviewTint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(newReviewTint.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(.Board.boardReviewAssignmentSeen))
                .help(newReviewHelp)
            }
            if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
            else if isDraft { BoardDraftBadge(tint: draftBadgeTint) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var cardPin: BoardCardPin? {
        .mergeRequest(host: monitor.glab.resolvedHost, username: monitor.glab.currentUsername,
            projectID: item.id.projectID, iid: item.id.iid)
    }

    private var cardActions: some View {
        HStack(spacing: 0) {
            if let cardPin, monitor.settings.boardPins.contains(cardPin) {
                BoardPinButton(pin: cardPin, settings: monitor.settings)
            }
            if finishedState == nil, let scopeTarget {
                BoardAutomationToggle(monitor: monitor, target: scopeTarget,
                    projectPath: item.url.gitLabProjectPath, isDraft: isDraft,
                    policy: MREffectivePolicySummary.presentation(row: row, monitor: monitor).0)
            }
            CopyMergeRequestLinkButton(url: item.url, placement: .header)
            BoardActionsMenu { menuItems }
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
        if presentation.mergeStage != nil { return nil }
        if let state = presentation.confirmedSubmission, state != .none { return nil }
        return presentation.neutralStatus
    }

    @ViewBuilder
    private func primaryAction(hasDirectMergeAction: Bool) -> some View {
        if let job = row.latestJob, job.execution?.state.isActive == true {
            Button(role: .destructive) {
                markReviewSeen()
                monitor.cancelAssistantJob(job.id)
            } label: { Text(.AssistantJobs.assistantJobsStop) }
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
        case .retryRun, .verifyFeedback, .retryDraftVerification, .retryReReview, .handleFeedback, .retryIntent: true
        default: false // Opening existing discussions/results never authorizes a GitLab action.
        }
    }

    @ViewBuilder
    private var reviewingAction: some View {
        if let label = reviewingContext.actionLabel {
            switch reviewingContext.nextStep {
            case .runReview:
                primary(label, cta: .runReview, enabled: monitor.canRunReview(for: row.displayItem)) {
                    let pending = row.waitsForReviewStart ? row.intents.first {
                        $0.kind == .review && $0.state == .pending && $0.jobID == nil
                    } : nil
                    if let pending {
                        guard let consent = confirmManualReview(for: monitor.reviewRequest(for: pending), monitor: monitor) else { return }
                        start { await monitor.runMRTodoIntent(id: pending.id, confirmedReview: consent) }
                    } else {
                        let current = row.displayItem
                        guard let consent = confirmManualReview(for: current, monitor: monitor) else { return }
                        start { await monitor.runReview(for: current, confirmed: consent) }
                    }
                }
            case .setupAgent: primary(label) { SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() }) }
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
            if let job = action.retryJob {
                primary(action.actionLabel, cta: .retryRun,
                        enabled: job.execution?.state.isActive == false
                            && !AssistantAutomationRunner.isWorking(on: job.key.work)) {
                    guard !isStarting else { return }
                    guard confirmAssistantRetry(job, for: item, monitor: monitor, title: action.actionLabel) else { return }
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
                    guard confirmMRAction(.finishCommentReview, title: .CommentReview.commentReviewFinish) else { return }
                    start { await monitor.attention.finishCommentReview(item) }
                }
            } else {
                switch action.draftPublicationShortcut(for: item.drafts) {
                case .review:
                    primary(.CommentReview.commentReviewReviewBeforePublishing) { openAttention(.drafts) }
                case .publishAll:
                    primary(.CommentReview.commentReviewPublishAll, cta: .publishComments, enabled: scopeTarget != nil) {
                        guard confirmMRAction(.publishComments, title: .CommentReview.commentReviewPublishAll,
                            detail: String(localized: .Menu.menuConfirmPublishHelp)) else { return }
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
            primary(action.actionLabel, cta: .verifyFeedback) {
                guard confirmMRAction(.verifyFeedback, title: action.actionLabel, monitor: monitor) else { return }
                monitor.attention.retryAuthorFeedback(item.id)
            }
        case .retryDraftVerification:
            primary(action.actionLabel, cta: .retryDraftVerification) {
                guard confirmMRAction(.retryDraftVerification, title: action.actionLabel, monitor: monitor) else { return }
                monitor.attention.retryDraftProofRecovery(item.id)
            }
        case .retryReReview:
            primary(action.actionLabel, cta: .verifyReReview) {
                guard confirmMRAction(.verifyReReview, title: action.actionLabel, monitor: monitor) else { return }
                start { await monitor.attention.retryReReview(item.id) }
            }
        case .setupAssistant:
            primary(action.actionLabel) { SettingsNavigation.shared.showCodingAgent(openSettings: { openSettings() }) }
        case .reviewDecision, .reviewFeedback:
            primary(action.actionLabel) { openAttention(.feedback) }
        case .reviewHandoff, .reviewMerge, .reviewIssue:
            primary(action.actionLabel) { openAttention(.overview) }
        case .handleFeedback:
            primary(action.actionLabel, cta: .handleFeedback) {
                guard confirmMRAction(.handleFeedback, title: action.actionLabel, monitor: monitor) else { return }
                start { await monitor.handleFeedbackManually(for: item) }
            }
        case .retryIntent:
            if let intent = action.retryIntent {
                primary(action.actionLabel, cta: MRActionCTA(intent: intent.kind)) {
                    start { await runConfirmedIntent(intent, monitor: monitor, title: action.actionLabel) }
                }
            } else {
                primary(action.actionLabel) { openAttention(.overview) }
            }
        }
    }

    private var newReviewActionLabel: LocalizedStringResource? {
        guard isNewReview else { return nil }
        return .Board.boardReviewAssignmentSeenFor(row.displayTitle, "\(row.displayURL.gitLabProjectPath) !\(item.id.iid)")
    }

    private var newReviewHelp: Text {
        let action = Text(.Board.boardReviewAssignmentSeen)
        guard let date = row.newReviewAssignedAt else { return action }
        return action + Text(verbatim: "\n") + Text(date, format: .dateTime.month().day().hour().minute())
    }

    private func markReviewSeen() {
        monitor.markReviewAssignmentSeen(row.displayItem)
    }

    private func openAttention(_ section: CommandCenterMRDetailSection) {
        markReviewSeen()
        if let onAttention { onAttention(section) }
        else { onDetails() }
    }

    @ViewBuilder
    private func primary(_ title: LocalizedStringResource, cta: MRActionCTA? = nil, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button {
            markReviewSeen()
            action()
            if isStarting { pendingPrimary = (title, cta) }
        } label: {
            if let cta {
                MRActionLabel(title: title, cta: cta, working: isStarting)
            } else {
                MRActionProgressLabel(working: isStarting) { Text(title).lineLimit(1) }
            }
        }
        .buttonStyle(.bordered).disabled(isStarting || finishingCommentReview || !enabled).mrActionHelp(cta)
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        isStarting = true
        Task {
            defer { isStarting = false; pendingPrimary = nil }
            await operation()
        }
    }

    @ViewBuilder private var menuItems: some View {
        if isNewReview {
            Button(action: onDetails) {
                Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
            }
        }
        MRCommonMenuItems(item: item, monitor: monitor, boardPin: cardPin,
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
        .boardCardInteraction(title: todo.displayTitle, repositoryPath: todo.project.pathWithNamespace,
            iid: todo.targetType == .mergeRequest ? todo.target.iid : nil) { showingDetails = true }
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
                if todo.targetType == .mergeRequest {
                    CopyMergeRequestLinkButton(url: todo.targetURL, placement: .header)
                }
                moreMenu
            }
        }
        .zIndex(1)
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
            AssistantContextMenu(mergeRequestURL: todo.targetURL, settings: monitor.settings)
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

struct BoardWaitingRequirements: View {
    let waiting: MRWaitingStatus
    var isMuted = false

    var body: some View {
        ForEach(Array(waiting.requirements.enumerated()), id: \.offset) { index, line in
            if index == 0, let message = waiting.reviewerPeopleMessage {
                WaitingPeopleLabel(message: message)
                    .foregroundStyle(isMuted ? Color.secondary : Color.primary)
            } else {
                BoardRequirementLine(text: line, isMuted: isMuted)
            }
        }
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
