import SwiftUI

/// Status and results precede the shared action row on both cards and Details.
struct MergeActionsView<StatusTrailer: View, AdditionalActions: View>: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var evidenceMatchesCatalogContext = true
    var actionsBlocked = false
    var onReviewFeedback: (() -> Void)? = nil
    /// Cards keep the longer scope explanation in the button help; Details shows it inline.
    var showsExplanations = true
    /// Details hides reply sources while its feedback check already lists them.
    var showsReplySources = true
    var textFont: Font = .subheadline
    var statusTrailer: () -> StatusTrailer
    var additionalActions: () -> AdditionalActions
    @Environment(\.openURL) private var openURL
    @State private var showingConfirmation = false
    @State private var working = false
    @State private var result: MergeSubmissionState?
    @State private var prepared: ManualDiscussionResolution.Prepared?
    @State private var resolutionMessage: String?

    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         showsReplySources: Bool = true,
         textFont: Font = .subheadline, @ViewBuilder statusTrailer: @escaping () -> StatusTrailer,
         @ViewBuilder additionalActions: @escaping () -> AdditionalActions) {
        self.item = item; self.monitor = monitor
        self.evidenceMatchesCatalogContext = evidenceMatchesCatalogContext
        self.actionsBlocked = actionsBlocked; self.onReviewFeedback = onReviewFeedback
        self.showsExplanations = showsExplanations; self.showsReplySources = showsReplySources
        self.textFont = textFont
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
    private var hasDiscussionBlock: Bool { status?.blockers.contains(.discussions) == true || item.mergeRequest?.blockingDiscussionsResolved == false }
    private var needsGitLabCheck: Bool { state == .uncertain || state == .changed || status?.action == nil && status != nil }
    private var feedbackRecovery: ManualFeedbackRecovery? {
        guard evidenceMatchesCatalogContext, monitor.authoredMergeRequests.hasSyncedCurrentCatalog else { return nil }
        return item.manualFeedbackRecovery()
    }
    private var feedbackRecheckRoute: ManualFeedbackRecheckRoute {
        guard let request = item.mergeRequest, let host = monitor.glab.resolvedHost,
              let username = monitor.glab.currentUsername else { return .review }
        return .init(backgroundCheckAllowed: AuthorFeedbackCoordinator.permitsBackgroundCheck(for: request,
            configuration: monitor.settings.automation, host: host, username: username))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if owned, hasStatusText {
                VStack(alignment: .leading, spacing: 5) { statusText }
                    .font(textFont)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusTrailer()
            HStack(spacing: 8) {
                if owned {
                    if state == .none, blocker == nil, let action = status?.action {
                        Button { prepared = nil; showingConfirmation = true } label: {
                            if working { ProgressView().controlSize(.small) }
                            else { Text(action.title) }
                        }
                        .buttonStyle(.borderedProminent).disabled(actionsBlocked || working)
                    }
                    if hasDiscussionBlock {
                        Button { prepareResolution() } label: {
                            if working { ProgressView().controlSize(.small) }
                            else { Text(.MergeActions.mergeActionsResolveAll) }
                        }
                        .buttonStyle(.bordered).disabled(working || actionsBlocked)
                        .help(Text(.MergeActions.mergeActionsResolveScope))
                    }
                    feedbackRecoveryAction
                    if needsGitLabCheck { Link(destination: item.url) { Text(.MergeActions.mergeActionsCheckGitLab) } }
                }
                additionalActions()
            }
        }
        .font(.caption)
        .alert(Text(prepared == nil ? .MergeActions.mergeActionsConfirmMerge : .MergeActions.mergeActionsResolveTitle),
               isPresented: $showingConfirmation) {
            if let prepared {
                if !prepared.plan.eligibleIDs.isEmpty {
                    Button { resolve(prepared) } label: { Text(.MergeActions.mergeActionsResolveConfirm) }
                }
            } else {
                Button { merge() } label: { Text(status?.action?.title ?? .MergeActions.mergeActionsMergeNow) }
            }
            Button(role: .cancel) { prepared = nil } label: { Text(.MergeActions.mergeActionsCancel) }
        } message: {
            if let prepared {
                Text(.MergeActions.mergeActionsResolvePreview(prepared.plan.eligibleIDs.count, prepared.plan.heldIDs.count))
                + Text(verbatim: "\n\n" + prepared.plan.confirmationDetails + "\n\n")
                + Text(.MergeActions.mergeActionsResolveHelp)
            } else { Text(.MergeActions.mergeActionsConfirmHelp) }
        }
        .onChange(of: item.mergeRequest?.sha) { _, _ in result = nil; prepared = nil; showingConfirmation = false }
        .onChange(of: monitor.authoredMergeRequests.lastRefresh) { _, _ in result = nil }
    }

    private var hasStatusText: Bool {
        status?.request.mergeTrainConflict != nil || status?.request.mergeTrainEvidenceUnavailable == true
            || state.title != nil || blocker != nil || hasDiscussionBlock
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
        } else if let title = state.title {
            statusLine(title, symbol: state.isDelegated ? "clock" : "exclamationmark.circle", emphasized: !state.isDelegated)
        } else if let blocker {
            statusLine(blocker.title, symbol: "lock")
            if feedbackRecovery?.recoveryAction == .verifyFeedback, feedbackRecheckRoute == .review {
                statusLine(.MergeActions.mergeActionsFeedbackChecksPaused, symbol: "pause.circle")
            }
        }
        if hasDiscussionBlock, blocker != .prerequisite(.discussions) {
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
                Button {
                    feedbackRecheckRoute.perform(verify: { monitor.attention.retryAuthorFeedback(item.id) },
                        review: reviewFeedback)
                } label: {
                    Text(.AuthorFeedback.authorFeedbackRecheck)
                }
                .buttonStyle(.bordered).disabled(working || actionsBlocked)
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

    private func merge() {
        guard let request = item.mergeRequest, !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            result = await monitor.authoredMergeRequests.mergeManually(request)
            if result == .merged || result?.isDelegated == true { await monitor.refreshNow() }
        }
    }
    private func prepareResolution() {
        guard let request = item.mergeRequest else { return }
        working = true; resolutionMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                prepared = try await ManualDiscussionResolution.prepare(request, monitor: monitor)
                showingConfirmation = true
            } catch { resolutionMessage = String(localized: .MergeActions.mergeActionsFailed) }
        }
    }
    private func resolve(_ confirmed: ManualDiscussionResolution.Prepared) {
        prepared = nil; working = true
        Task { @MainActor in
            defer { working = false }
            let result = await ManualDiscussionResolution.resolve(confirmed, glab: monitor.glab, settings: monitor.settings)
            resolutionMessage = String(localized: .MergeActions.mergeActionsResolveResult(result.resolved, result.selected, result.held))
            await monitor.refreshNow()
        }
    }
}

extension MergeActionsView where StatusTrailer == EmptyView {
    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         textFont: Font = .subheadline, @ViewBuilder additionalActions: @escaping () -> AdditionalActions) {
        self.init(item: item, monitor: monitor, evidenceMatchesCatalogContext: evidenceMatchesCatalogContext,
            actionsBlocked: actionsBlocked, onReviewFeedback: onReviewFeedback, showsExplanations: showsExplanations,
            textFont: textFont, statusTrailer: { EmptyView() }, additionalActions: additionalActions)
    }
}

extension MergeActionsView where StatusTrailer == EmptyView, AdditionalActions == EmptyView {
    init(item: MergeRequestAttentionMonitor.Item, monitor: TodoMonitorService, evidenceMatchesCatalogContext: Bool = true,
         actionsBlocked: Bool = false, onReviewFeedback: (() -> Void)? = nil, showsExplanations: Bool = true,
         textFont: Font = .subheadline) {
        self.init(item: item, monitor: monitor, evidenceMatchesCatalogContext: evidenceMatchesCatalogContext,
            actionsBlocked: actionsBlocked, onReviewFeedback: onReviewFeedback, showsExplanations: showsExplanations,
            textFont: textFont, statusTrailer: { EmptyView() }, additionalActions: { EmptyView() })
    }
}
