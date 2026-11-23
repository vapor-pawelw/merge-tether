import SwiftUI

/// Status and results precede the shared action row on both cards and Details.
struct MergeActionsView<StatusLayout: ViewModifier, StatusTrailer: View, AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var evidenceMatchesCatalogContext = true
    var actionsBlocked = false
    var onReviewFeedback: (() -> Void)? = nil
    /// Cards keep the longer scope explanation in the button help; Details shows it inline.
    var showsExplanations = true
    /// Details hides reply sources while its feedback check already lists them.
    var showsReplySources = true
    var showsRecoveryActions = true
    var showsFeedbackVerification = true
    var showsStatusCard = false
    var textFont: Font = .subheadline
    /// Blockers the card already lists as requirements.
    var coveredBlockers: Set<MergeRequestBlocker> = []
    /// Cards hide actions that would only show disabled while MergeTether is working.
    var hidesBlockedActions = false
    var highlightedSubmission: MergeSubmissionState? = nil
    var statusTopPadding: CGFloat
    var statusOpacity: Double
    var statusLayout: StatusLayout
    var statusTrailer: () -> StatusTrailer
    var additionalActions: (Bool) -> AdditionalActions
    @Environment(\.openURL) private var openURL
    private struct MergeConfirmation {
        let request: GitLabMergeRequest
        let action: MergeSubmissionAction
        let verificationAssistant: AutomationAssistant
        let accountRevision: UInt64
    }
    private enum PendingAction: Equatable { case merge(MergeSubmissionAction), threads }

    @State private var attemptedAction: MergeSubmissionAction?
    @State private var pendingAction: PendingAction?
    @State private var result: MergeSubmissionState?
    @State private var resolutionMessage: String?

    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         showsReplySources: Bool = true,
         showsRecoveryActions: Bool = true, showsFeedbackVerification: Bool = true, showsStatusCard: Bool = false,
         textFont: Font = .subheadline, coveredBlockers: Set<MergeRequestBlocker> = [],
         hidesBlockedActions: Bool = false, highlightedSubmission: MergeSubmissionState? = nil,
         statusTopPadding: CGFloat = 0, statusOpacity: Double = 1,
         statusLayout: StatusLayout = EmptyModifier(),
         @ViewBuilder statusTrailer: @escaping () -> StatusTrailer,
         @ViewBuilder additionalActions: @escaping (Bool) -> AdditionalActions) {
        self.item = item; self.monitor = monitor
        self.evidenceMatchesCatalogContext = evidenceMatchesCatalogContext
        self.actionsBlocked = actionsBlocked; self.onReviewFeedback = onReviewFeedback
        self.showsExplanations = showsExplanations; self.showsReplySources = showsReplySources
        self.showsRecoveryActions = showsRecoveryActions
        self.showsFeedbackVerification = showsFeedbackVerification
        self.showsStatusCard = showsStatusCard
        self.textFont = textFont
        self.coveredBlockers = coveredBlockers; self.hidesBlockedActions = hidesBlockedActions
        self.highlightedSubmission = highlightedSubmission
        self.statusTopPadding = statusTopPadding
        self.statusOpacity = statusOpacity
        self.statusLayout = statusLayout
        self.statusTrailer = statusTrailer; self.additionalActions = additionalActions
    }

    private var status: AuthoredMergeRequestStatus? {
        guard evidenceMatchesCatalogContext, monitor.authoredMergeRequests.hasSyncedCurrentCatalog,
              let request = item.mergeRequest, request.webURL == item.url else { return nil }
        return monitor.authoredMergeRequests.requests.first { $0.matchesCurrentRequest(request) }
    }
    private var owned: Bool {
        item.isAuthored && item.mergeRequest?.state == "opened" && item.mergeRequest?.author.username == monitor.glab.currentUsername
    }
    private var blocker: ManualMergeBlocker? {
        guard evidenceMatchesCatalogContext else { return .context }
        guard monitor.authoredMergeRequests.hasSyncedCurrentCatalog else { return .checking }
        if status == nil, let request = item.mergeRequest,
           monitor.authoredMergeRequests.requests.contains(where: {
               $0.request.projectID == request.projectID && $0.request.iid == request.iid
           }) { return .context }
        return item.manualMergeBlocker(using: status)
    }
    private var state: MergeSubmissionState { result ?? status?.submissionState ?? .none }
    private var displayedState: MergeSubmissionState { result ?? status?.displayedSubmissionState ?? .none }
    private var submissionTitle: LocalizedStringResource? {
        displayedState == highlightedSubmission ? nil : displayedState.title
    }
    private var hasDiscussionBlock: Bool { status?.blockers.contains(.discussions) == true || item.mergeRequest?.blockingDiscussionsResolved == false }
    private var shownBlocker: ManualMergeBlocker? {
        if case .prerequisite(let reason) = blocker, coveredBlockers.contains(reason) { return nil }
        return blocker
    }
    private var showsDiscussionLine: Bool {
        hasDiscussionBlock && blocker != .prerequisite(.discussions) && !coveredBlockers.contains(.discussions)
    }
    private var working: Bool { pendingAction != nil }
    private var hidesActions: Bool { hidesBlockedActions && actionsBlocked && !working }
    private var directMergeAction: MergeSubmissionAction? {
        if case let .merge(action) = pendingAction { return action }
        let canConfirmChangedAction = state == .changed && status?.action != attemptedAction
        guard owned, state == .none || canConfirmChangedAction, blocker == nil, !hidesActions,
              item.reReviewReadiness?.hasConcreteConcerns != true else { return nil }
        return status?.action
    }
    private var needsGitLabCheck: Bool {
        displayedState == .uncertain || displayedState == .changed || status?.action == nil && status != nil
    }
    private var feedbackRecovery: ManualFeedbackRecovery? {
        guard evidenceMatchesCatalogContext, monitor.authoredMergeRequests.hasSyncedCurrentCatalog else { return nil }
        return item.manualFeedbackRecovery()
    }
    private var feedbackRecheckRoute: ManualFeedbackRecheckRoute {
        guard let request = item.mergeRequest, let host = monitor.glab.resolvedHost,
              let username = monitor.glab.currentUsername else { return .review }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return .init(backgroundCheckAllowed: AuthorFeedbackCoordinator.permitsBackgroundCheck(for: request,
            configuration: monitor.settings.automation, host: host, username: username,
            mergeOptedIn: monitor.settings.autoMergePreference(for: target) == .on))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if owned, hasStatusText {
                    VStack(alignment: .leading, spacing: 5) { statusText }
                        .font(textFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(MRDetailStatusCard(isPresented: showsStatusCard))
                        .padding(.top, statusTopPadding)
                        .opacity(statusOpacity)
                }
                statusTrailer().opacity(statusOpacity)
            }
            .font(.caption)
            .modifier(statusLayout)
            HStack(spacing: 8) {
                if owned {
                    if let action = directMergeAction, let request = item.mergeRequest {
                        Button {
                            let assistant = monitor.settings.automation.assistant
                            let confirmation = MergeConfirmation(request: request, action: action,
                                verificationAssistant: assistant, accountRevision: monitor.glab.accountRevision)
                            let message = String(localized: .MergeActions.mergeActionsConfirmHelp) + "\n\n"
                                + String(localized: assistant.manualMergeVerificationDisclosure)
                            guard confirmMRAction(id: MRActionCTA.merge.confirmationID(variant: action.rawValue),
                                title: .MergeActions.mergeActionsConfirmMerge, button: action.title, message: message) else { return }
                            merge(confirmation)
                        } label: {
                            MRActionProgressLabel(working: pendingAction == .merge(action)) { Text(action.title) }
                        }
                        .buttonStyle(.borderedProminent).disabled(actionsBlocked || working)
                        .mrActionHelp(.merge)
                    }
                    if showsRecoveryActions, pendingAction == .threads || (hasDiscussionBlock && !hidesActions) {
                        Button { prepareResolution() } label: {
                            MRActionLabel(title: .MergeActions.mergeActionsResolveAll, cta: .resolveThreads,
                                working: pendingAction == .threads)
                        }
                        .buttonStyle(.bordered).disabled(working || actionsBlocked)
                        .mrActionHelp(.resolveThreads, detail: .MergeActions.mergeActionsResolveScope)
                    }
                    if showsRecoveryActions, !hidesActions { feedbackRecoveryAction }
                    if needsGitLabCheck { Link(destination: item.url) { Text(.MergeActions.mergeActionsCheckGitLab) } }
                }
                additionalActions(directMergeAction != nil && !actionsBlocked && !working)
            }
            .font(.caption)
        }
        .onChange(of: item.mergeRequest?.sha) { _, _ in
            result = nil
        }
        .onChange(of: monitor.authoredMergeRequests.lastRefresh) { _, _ in result = nil }
    }

    private var hasStatusText: Bool {
        status?.request.mergeTrainConflict != nil || status?.request.mergeTrainEvidenceUnavailable == true
            || submissionTitle != nil || (displayedState.title == nil && shownBlocker != nil) || showsDiscussionLine
            || (showsReplySources && feedbackRecovery?.replySourceIDs.isEmpty == false) || resolutionMessage != nil || result == .changed
    }

    @ViewBuilder
    private var statusText: some View {
        if let conflict = status?.request.mergeTrainConflict {
            Link(destination: conflict.noteURL) {
                Label { Text(.MergeActions.mergeActionsTrainRebaseConflict) } icon: { Image(systemName: "arrow.triangle.branch") }
            }.foregroundStyle(.orange)
        } else if status?.request.mergeTrainEvidenceUnavailable == true {
            statusLine(.MergeActions.mergeActionsTrainEvidenceUnavailable, symbol: "exclamationmark.triangle", emphasized: true)
        } else if let title = submissionTitle {
            statusLine(title, symbol: displayedState.isDelegated ? "clock" : "exclamationmark.circle", emphasized: !displayedState.isDelegated)
        } else if displayedState.title == nil, let blocker = shownBlocker {
            statusLine(blocker.title, symbol: "lock")
            if feedbackRecovery?.recoveryAction == .verifyFeedback, feedbackRecheckRoute == .review {
                statusLine(.MergeActions.mergeActionsFeedbackChecksPaused, symbol: "pause.circle")
            }
        }
        if showsDiscussionLine {
            statusLine(.Menu.menuAuthoredBlockerDiscussions, symbol: "bubble.left.and.exclamationmark.bubble.right", emphasized: true)
        }
        if showsReplySources, let feedbackRecovery, !feedbackRecovery.replySourceIDs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                statusLine(.MergeActions.mergeActionsReplySources(feedbackRecovery.replySourceIDs.count), symbol: "arrowshape.turn.up.left")
                ForEach(Array(feedbackRecovery.replySourceIDs.prefix(3)), id: \.self) { noteID in
                    if let url = replySourceURL(noteID) {
                        Link(destination: url) { Text(.MergeActions.mergeActionsReplySource(noteID)) }
                            .padding(.leading, statusIndent)
                    }
                }
            }
        }
        if showsExplanations, hasDiscussionBlock, feedbackRecovery != nil {
            Text(.MergeActions.mergeActionsResolveScope).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, statusIndent)
        }
        if let resolutionMessage {
            Text(verbatim: resolutionMessage).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if result == .changed, status?.request.mergeTrainConflict == nil {
            statusLine(.MergeActions.mergeActionsBlocked, symbol: "exclamationmark.triangle", emphasized: true)
        }
    }

    private var statusIndent: CGFloat { 20 }

    /// The icon carries severity; the sentence stays in a readable text colour.
    private func statusLine(_ text: LocalizedStringResource, symbol: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(emphasized ? Color.orange : Color.secondary)
                .frame(width: 14)
            Text(text).foregroundStyle(emphasized ? Color.primary : Color.secondary)
        }
    }

    @ViewBuilder
    private var feedbackRecoveryAction: some View {
        let feedbackAction = feedbackRecovery?.recoveryAction
        let route = feedbackAction == .verifyFeedback ? feedbackRecheckRoute : nil
        if state == .none, let recovery = route?.recoveryAction ?? feedbackAction {
            switch recovery {
            case .refresh:
                GitLabRefreshButton(monitor: monitor, itemID: item.id).buttonStyle(.bordered)
            case .verifyFeedback:
                if showsFeedbackVerification {
                    Button {
                        guard confirmMRAction(.verifyFeedback, title: .AuthorFeedback.authorFeedbackRecheck) else { return }
                        feedbackRecheckRoute.perform(verify: { monitor.attention.retryAuthorFeedback(item.id) },
                            review: reviewFeedback)
                    } label: {
                        MRActionLabel(title: .AuthorFeedback.authorFeedbackRecheck, cta: .verifyFeedback)
                    }
                    .buttonStyle(.bordered).disabled(working || actionsBlocked)
                    .mrActionHelp(.verifyFeedback)
                }
            case .reviewFeedback:
                switch ManualFeedbackReviewDestination(item: item) {
                case .gitLab(let url):
                    Link(destination: url) { Text(.MRHumanAction.mrHumanActionActionReviewFeedback) }
                case .verification:
                    if let onReviewFeedback {
                        Button {
                            (route ?? .review).perform(verify: { monitor.attention.retryAuthorFeedback(item.id) }, review: onReviewFeedback)
                        } label: { Text(.MRHumanAction.mrHumanActionActionReviewFeedback) }
                            .buttonStyle(.bordered)
                    } else {
                        Link(destination: item.url) { Text(.MRHumanAction.mrHumanActionActionReviewFeedback) }
                    }
                }
            }
        }
    }

    private func replySourceURL(_ noteID: Int) -> URL? {
        var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
        components?.fragment = "note_\(noteID)"
        return components?.url
    }

    private func reviewFeedback() {
        switch ManualFeedbackReviewDestination(item: item) {
        case .gitLab(let url): openURL(url)
        case .verification:
            if let onReviewFeedback { onReviewFeedback() }
            else { openURL(item.url) }
        }
    }

    private func merge(_ confirmation: MergeConfirmation) {
        guard !working, monitor.glab.accountRevision == confirmation.accountRevision else { return }
        pendingAction = .merge(confirmation.action)
        attemptedAction = confirmation.action
        Task { @MainActor in
            defer { pendingAction = nil }
            result = await monitor.authoredMergeRequests.mergeManually(confirmation.request,
                action: confirmation.action, verificationAssistant: confirmation.verificationAssistant)
            if result == .merged || result?.isDelegated == true { await monitor.refreshNow() }
        }
    }
    private func prepareResolution() {
        guard !working, let request = item.mergeRequest else { return }
        pendingAction = .threads; resolutionMessage = nil
        Task { @MainActor in
            do {
                let prepared = try await ManualDiscussionResolution.prepare(request, monitor: monitor)
                pendingAction = nil
                let plan = prepared.plan
                let message = String(localized: .MergeActions.mergeActionsResolvePreview(plan.eligibleIDs.count, plan.heldIDs.count))
                    + "\n\n" + plan.confirmationDetails + "\n\n" + String(localized: .MergeActions.mergeActionsResolveHelp)
                guard !plan.eligibleIDs.isEmpty else { resolutionMessage = message; return }
                guard confirmMRAction(id: MRActionCTA.resolveThreads.confirmationID(),
                    title: .MergeActions.mergeActionsResolveTitle, button: .MergeActions.mergeActionsResolveConfirm,
                    message: message) else { return }
                resolve(prepared)
            } catch {
                pendingAction = nil
                resolutionMessage = String(localized: .MergeActions.mergeActionsFailed)
            }
        }
    }
    private func resolve(_ confirmed: ManualDiscussionResolution.Prepared) {
        guard !working else { return }
        pendingAction = .threads
        Task { @MainActor in
            defer { pendingAction = nil }
            let result = await ManualDiscussionResolution.resolve(confirmed, glab: monitor.glab, settings: monitor.settings)
            resolutionMessage = String(localized: .MergeActions.mergeActionsResolveResult(result.resolved, result.selected, result.held))
            await monitor.refreshNow()
        }
    }
}

extension MergeActionsView where StatusLayout == EmptyModifier, StatusTrailer == EmptyView {
    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         textFont: Font = .subheadline, @ViewBuilder additionalActions: @escaping () -> AdditionalActions) {
        self.init(item: item, monitor: monitor, evidenceMatchesCatalogContext: evidenceMatchesCatalogContext,
            actionsBlocked: actionsBlocked, onReviewFeedback: onReviewFeedback, showsExplanations: showsExplanations,
            textFont: textFont, statusTrailer: { EmptyView() }, additionalActions: { _ in additionalActions() })
    }
}

extension MergeActionsView where StatusLayout == EmptyModifier, StatusTrailer == EmptyView, AdditionalActions == EmptyView {
    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         textFont: Font = .subheadline) {
        self.init(item: item, monitor: monitor, evidenceMatchesCatalogContext: evidenceMatchesCatalogContext,
            actionsBlocked: actionsBlocked, onReviewFeedback: onReviewFeedback, showsExplanations: showsExplanations,
            textFont: textFont, statusTrailer: { EmptyView() }, additionalActions: { _ in EmptyView() })
    }
}
