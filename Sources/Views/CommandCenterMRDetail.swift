import AppKit
import SwiftUI

enum CommandCenterMRDetailSection: Hashable {
    case overview, drafts, assistantRuns, feedback

    var title: LocalizedStringResource {
        switch self {
        case .overview: .CommandCenter.commandCenterOverview
        case .drafts: .CommandCenter.commandCenterConfirmations
        case .assistantRuns: .AutomationHistory.automationHistoryTitle
        case .feedback: .CommandCenter.commandCenterFeedback
        }
    }
}

struct CommandCenterMRDetail: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var initialSection: CommandCenterMRDetailSection = .overview

    var body: some View {
        // Resolve the shared board projection once, outside layout-driven child updates.
        let required = item.humanActionRequired ?? needsHumanAttention
        CommandCenterMRDetailContent(item: item, monitor: monitor, initialSection: initialSection,
                                     needsHumanAttention: required)
    }

    private var needsHumanAttention: Bool {
        guard let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
        let key = "\(target.host)/\(target.username)/mr/\(item.id.projectID)/\(item.id.iid)"
        return monitor.userAttention.items.contains { $0.id == key }
    }
}

private struct CommandCenterMRDetailContent: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    let initialSection: CommandCenterMRDetailSection
    let needsHumanAttention: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var isStartingReview = false
    @State private var reviewStartError: String?
    @State private var isRetrying = false
    @State private var retryError: String?
    @State private var confirmRemoval = false
    @State private var discussionStore = MRDiscussionStore()
    @State private var draftSelection = DraftPublicationSelection()
    @State private var detailsExpanded = false
    @State private var feedbackExpanded = false
    @State private var historyExpanded = false
    @State private var focusedJobID: UUID?
    @State private var historyNavigationID = UUID()
    @State private var pendingInitialAnchor: Anchor?
    @State private var initialDiscussionAttemptFinished = false
    @State private var feedbackDecisionConfirmation: FeedbackDecisionConfirmation?
    @State private var isUpdatingFeedbackDecision = false
    @State private var feedbackDecisionError: String?

    private enum Anchor: Hashable { case overview, drafts, comments, details, actions, feedbackStatus, assistantRuns }

    private var finishedState: MergeRequestFinishedState? { .init(item.mergeRequest) }
    private var target: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }
    private var usageMergeRequest: AssistantUsageMergeRequest? {
        guard let target, let request = item.mergeRequest else { return nil }
        return .init(host: target.host, username: target.username, projectID: item.id.projectID, iid: item.id.iid,
            title: request.title, url: item.url.absoluteString)
    }
    private var work: AssistantAutomationRunner.MergeRequestWork? {
        target.map { .init(host: $0.host, projectID: item.id.projectID, iid: item.id.iid) }
    }
    private var presentationItem: MergeRequestAttentionMonitor.Item {
        var value = item
        value.humanActionRequired = finishedState == nil && needsHumanAttention
        return value
    }
    private var jobs: [AssistantAutomationRunner.Handoff] {
        guard let work, let target else { return [] }
        return monitor.assistantHandoffs.filter { $0.key.work == work && $0.key.username == target.username && !$0.isObsoleteReminder }.sorted { $0.createdAt > $1.createdAt }
    }
    private var presentationRow: MergeRequestBoardSnapshot.Row {
        .init(item: presentationItem, latestJob: jobs.first, intents: monitor.mrTodoIntents(for: item),
            pipelineEvidence: jobs.first.flatMap { monitor.currentRequest(for: $0) },
            pipelineEvidenceCheckedAt: monitor.currentPipelineEvidenceDate)
    }
    private var humanAction: MRHumanAction? {
        let reviewing = monitor.reviewedMergeRequestItems.contains { $0.id == item.id && $0.url == item.url }
        return MRCardPresentation(row: presentationRow, monitor: monitor, allowsRemoval: reviewing).humanAction
    }

    private struct FeedbackDecisionConfirmation {
        let target: MRAutomationScope.Target
        var note: GitLabMergeRequestDiscussion.Note? = nil
        var summary = ""
        var reason = ""
        var isReset: Bool { note == nil }

        var message: String {
            guard let note else { return String(localized: .FeedbackSuggestions.feedbackSuggestionsResetExplanation) }
            let quote = note.body ?? ""
            let preview = quote.count > 600 ? String(quote.prefix(600)) + "…" : quote
            let author = note.author?.username.map { "@" + $0 } ?? note.author?.name ?? ""
            let concern = summary == reason ? summary : summary + "\n" + reason
            return String(localized: .FeedbackSuggestions.feedbackSuggestionsConcern) + "\n" + concern
                + "\n\n" + String(localized: .FeedbackSuggestions.feedbackSuggestionsComment)
                + " · " + author + " · #" + String(note.id ?? 0) + "\n" + preview
                + "\n\n" + String(localized: .FeedbackSuggestions.feedbackSuggestionsIgnoreExplanation)
        }
    }

    private var citationContext: MRCommentCitation.Context? {
        guard let target = discussionTarget else { return nil }
        return .init(target: target, loadedTarget: discussionStore.target, request: item.mergeRequest,
            discussions: discussionStore.discussions, hasLoaded: discussionStore.hasLoaded, hasError: discussionStore.hasError)
    }
    private var ignoredSuggestions: [IgnoredFeedbackSuggestion] {
        target.map { monitor.settings.feedbackSuggestionDecisions.entries(for: $0) } ?? []
    }

    private var showsDecisions: Bool { finishedState == nil && (needsHumanAttention || initialSection == .drafts) }
    private var initialDestinationIsReady: Bool {
        guard let anchor = pendingInitialAnchor else { return false }
        // Decisions precede comments, so their position does not depend on the discussion load.
        return anchor == .drafts || (anchor == .feedbackStatus && showsDecisions)
            || (initialDiscussionAttemptFinished && !discussionStore.isLoading)
    }
    private var discussionTarget: MRDiscussionTarget? {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername,
              item.url.isGitLabMergeRequest(host: host, iid: item.id.iid) else { return nil }
        return .init(host: host, username: username, projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }

    var body: some View {
        let citationContext = self.citationContext
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id(Anchor.overview)
                    if showsDecisions { nextStep(proxy: proxy, citationContext: citationContext).id(Anchor.drafts) }
                    if finishedState == nil { supplementaryActions(citationContext: citationContext).id(Anchor.actions) }
                    discussionThreads.id(Anchor.comments)
                    details.id(Anchor.details)
                    MRAutomationEventLogView(target: target, monitor: monitor,
                        initiallyExpanded: historyExpanded, initiallyExpandedJobID: focusedJobID, readOnly: finishedState != nil)
                        .id(historyNavigationID).id(Anchor.assistantRuns)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if finishedState == nil { selectedPublicationActions }
            }
            .task(id: initialSection) {
                pendingInitialAnchor = nil
                if needsHumanAttention && item.authorFeedbackStatus?.needsAttention == true { feedbackExpanded = true }
                switch initialSection {
                case .overview: return
                case .drafts:
                    pendingInitialAnchor = .drafts
                case .assistantRuns:
                    historyExpanded = true
                    focusedJobID = jobs.first?.id
                    historyNavigationID = UUID()
                    pendingInitialAnchor = .assistantRuns
                case .feedback:
                    if item.canConfirmReReview {
                        pendingInitialAnchor = showsDecisions ? .drafts : .actions
                    } else if item.authorFeedbackStatus != nil {
                        feedbackExpanded = true
                        pendingInitialAnchor = .feedbackStatus
                    } else { pendingInitialAnchor = .comments }
                }
            }
            .task(id: initialDestinationIsReady) {
                guard initialDestinationIsReady, let anchor = pendingInitialAnchor else { return }
                await scroll(to: anchor, proxy: proxy)
                guard !Task.isCancelled else { return }
                pendingInitialAnchor = nil
            }
            .task(id: discussionTarget) {
                initialDiscussionAttemptFinished = false
                guard let target = discussionTarget else {
                    discussionStore.clear()
                    initialDiscussionAttemptFinished = true
                    return
                }
                while !Task.isCancelled {
                    await discussionStore.refresh(target: target, glab: monitor.glab)
                    guard !Task.isCancelled else { return }
                    initialDiscussionAttemptFinished = true
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .onChange(of: monitor.attention.confirmationStates[item.id]) { old, current in
                if old == .publishing && current != .publishing { refreshDiscussions() }
            }
            .onChange(of: jobs.first?.id) { _, _ in retryError = nil }
            .onChange(of: item.drafts) { _, drafts in draftSelection.reconcile(with: drafts) }
            .onChange(of: discussionTarget) { _, _ in
                draftSelection = DraftPublicationSelection()
                reviewStartError = nil
                feedbackDecisionConfirmation = nil
                feedbackDecisionError = nil
            }
            .onChange(of: needsHumanAttention) { _, required in
                if required && item.authorFeedbackStatus?.needsAttention == true { feedbackExpanded = true }
            }
            .onDisappear { discussionStore.cancel() }
            .alert(Text(feedbackDecisionConfirmation?.isReset == true
                ? .FeedbackSuggestions.feedbackSuggestionsResetTitle : .FeedbackSuggestions.feedbackSuggestionsIgnoreTitle),
                isPresented: Binding(get: { feedbackDecisionConfirmation != nil },
                    set: { if !$0 { feedbackDecisionConfirmation = nil } }), presenting: feedbackDecisionConfirmation) { choice in
                Button(role: .cancel) { feedbackDecisionConfirmation = nil } label: {
                    Text(.FeedbackSuggestions.feedbackSuggestionsCancel)
                }
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive) { confirmFeedbackDecision(choice) } label: {
                    Text(choice.isReset ? .FeedbackSuggestions.feedbackSuggestionsResetConfirm
                         : .FeedbackSuggestions.feedbackSuggestionsIgnoreConfirm)
                }
            } message: { choice in Text(verbatim: choice.message) }
            .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button(role: .destructive) { monitor.removeReviewedMergeRequest(item) } label: { Text(.Board.boardRemove) }
            } message: { Text(.Board.boardRemoveExplanation) }
        }
    }

    private func scroll(to anchor: Anchor, proxy: ScrollViewProxy) async {
        // Disclosures must mount their content before its anchor can be located.
        await Task.yield()
        await Task.yield()
        guard !Task.isCancelled else { return }
        if anchor == .assistantRuns, let focusedJobID {
            proxy.scrollTo("job/\(focusedJobID)", anchor: .top)
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private var header: some View {
        let reviewing = monitor.reviewedMergeRequestItems.contains { $0.id == item.id && $0.url == item.url }
        let progress = MRCardPresentation(row: presentationRow, monitor: monitor, allowsRemoval: reviewing)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "!\(item.id.iid)").monospacedDigit()
                if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
                else if item.section == .draftMergeRequests { BoardDraftBadge() }
                RepositoryPathText(item.url.gitLabProjectPath).lineLimit(1)
                if let author = item.mergeRequest?.author {
                    AvatarView(url: author.avatarURL, size: 18).accessibilityHidden(true)
                    Text(verbatim: author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? author.username : author.name).lineLimit(1)
                        .help(Text(verbatim: "@\(author.username)"))
                }
                if finishedState == nil, let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
                    BoardAutomationToggle(settings: monitor.settings, target: target, projectPath: item.url.gitLabProjectPath,
                        isDraft: item.section == .draftMergeRequests)
                }
                Spacer()
                BoardPinButton(pin: .mergeRequest(host: monitor.glab.resolvedHost,
                    username: monitor.glab.currentUsername, projectID: item.id.projectID, iid: item.id.iid),
                    settings: monitor.settings)
                headerMenu
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let finishedState {
                        Text(finishedState.status).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        if needsHumanAttention || !progress.working {
                            Label {
                                Text(needsHumanAttention ? .CommandCenter.commandCenterStatusAttention
                                     : item.section == .draftMergeRequests ? .CommandCenter.commandCenterStatusDraft
                                     : .CommandCenter.commandCenterStatusMonitoring)
                            } icon: { Image(systemName: needsHumanAttention ? "exclamationmark.circle" : "arrow.triangle.pull") }
                            .font(.subheadline).foregroundStyle(needsHumanAttention ? .orange : .secondary)
                        }
                        if progress.working, let status = progress.status {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(verbatim: status)
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                        } else if progress.refreshFailed {
                            Label { Text(.AutomationProgress.progressRefreshFailed) } icon: { Image(systemName: "arrow.clockwise") }
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if finishedState != nil {
                    Button { monitor.acknowledgeFinishedMergeRequest(item) } label: { Text(.MRLifecycle.seen) }
                        .buttonStyle(.bordered).help(Text(.MRLifecycle.seenHelp))
                } else {
                    MarkMergeRequestReadyButton(item: item, monitor: monitor).buttonStyle(.bordered)
                }
                GitLabRefreshButton(monitor: monitor, itemID: item.id) {
                    if let target = discussionTarget { await discussionStore.refresh(target: target, glab: monitor.glab) }
                }
                .buttonStyle(.bordered)
                Link(destination: item.url) {
                    Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                .buttonStyle(.bordered)
            }
            if let dependencies = item.dependencies, dependencies.hasPresentation {
                MRDependencyRow(summary: dependencies, projectID: item.id.projectID)
            }
        }
    }

    private var headerMenu: some View {
        Menu {
            MRCommonMenuItems(item: item, monitor: monitor,
                onRemove: monitor.reviewedMergeRequestItems.contains(where: { $0.id == item.id && $0.url == item.url })
                    ? { confirmRemoval = true } : nil)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
    }

    private func nextStep(proxy: ScrollViewProxy, citationContext: MRCommentCitation.Context?) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let action = humanAction {
                    if !item.needsConfirmation || (action.kind != .publication && action.kind != .approval) {
                        Text(verbatim: action.explanation).textSelection(.enabled)
                    }
                    if let detail = action.detail, detail != action.explanation, action.preparedReply == nil {
                        AgentDiagnosticDetails(reason: detail)
                    }
                    attentionSourceEvidence(for: action, citationContext: citationContext)
                    if action.action == .retryRun, let job = jobs.first {
                        HStack {
                            Button {
                                guard !isRetrying else { return }
                                isRetrying = true
                                retryError = nil
                                Task {
                                    defer { isRetrying = false }
                                    guard monitor.assistantHandoffs.contains(where: { $0.id == job.id }) else { return }
                                    await monitor.retryAssistantJob(job.id)
                                    retryError = monitor.assistantJobActionError
                                }
                            } label: {
                                if isRetrying { ProgressView().controlSize(.mini) }
                                else { Text(action.actionLabel) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isRetrying || job.execution?.state.isActive != false
                                      || !monitor.availableAssistants.contains(job.key.assistant)
                                      || AssistantAutomationRunner.isWorking(on: job.key.work))
                            Button { openHistory(proxy: proxy) } label: {
                                Text(.MRHumanAction.mrHumanActionActionReviewRun)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if action.action == .reviewRun {
                        Button { openHistory(proxy: proxy) } label: {
                            Text(action.actionLabel)
                        }
                    } else if action.action == .reviewDrafts, let reply = action.preparedReply {
                        Button {
                            withAnimation { proxy.scrollTo("prepared-reply-\(reply.draftID)", anchor: .top) }
                        } label: { Text(action.actionLabel) }
                            .buttonStyle(.borderedProminent)
                    } else if action.action == .retryDraftVerification {
                        Button { monitor.attention.retryDraftProofRecovery(item.id) } label: { Text(action.actionLabel) }
                            .buttonStyle(.borderedProminent)
                    } else if action.action == .setupAssistant {
                        Button { openSettings() } label: { Text(action.actionLabel) }
                    } else if action.action == .reviewIssue {
                        Button { detailsExpanded = true; Task { await scroll(to: .details, proxy: proxy) } } label: {
                            Text(action.actionLabel)
                        }
                    }
                } else if !needsHumanAttention && !item.needsConfirmation {
                    Text(.CommandCenter.commandCenterNoPendingDecision).foregroundStyle(.secondary)
                }
                if let job = jobs.first { AssistantJobPreflightNotice(jobID: job.id, monitor: monitor) }
                if let retryError {
                    Text(verbatim: retryError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let feedbackDecisionError {
                    Text(verbatim: feedbackDecisionError).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if item.needsConfirmation { confirmationControls }
                decisionActions
                if item.authorFeedbackStatus != nil { feedbackCheck(citationContext: citationContext).id(Anchor.feedbackStatus) }
            }
            .font(.subheadline).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text(.CommandCenter.commandCenterNextStep).font(.headline) }
    }

    private var confirmationControls: some View {
        let publishSelected: (([GitLabDraftNote]) -> Void)? = discussionTarget.map { target in
            { selected in Task { await monitor.attention.publishDrafts(selected, for: target) } }
        }
        return ConfirmationQueueRow(item: item, state: monitor.attention.confirmationStates[item.id],
            onPublish: { Task { await monitor.attention.publishDrafts(of: item.id) } },
            onApprove: { Task { await monitor.attention.approve(item.id) } },
            onOpen: { NSWorkspace.shared.open(item.url) }, initiallyExpanded: initialSection == .drafts,
            showDraftPreview: false, showHeader: false, selection: $draftSelection,
            onPublishSelected: publishSelected, additionalActions: EmptyView())
    }

    @ViewBuilder
    private var selectedPublicationActions: some View {
        let selected = draftSelection.selectedDrafts(from: item.drafts)
        if !selected.isEmpty, let target = discussionTarget {
            let state = monitor.attention.confirmationStates[item.id]
            let busy = state == .publishing || state == .approving
            HStack(spacing: 12) {
                Button { draftSelection = DraftPublicationSelection() } label: {
                    Text(.DraftPublication.draftPublicationClearSelection)
                }
                .buttonStyle(.borderless)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await monitor.attention.publishDrafts(selected, for: target) } } label: {
                    Text(.DraftPublication.draftPublicationPublishSelected(selected.count))
                }
                .help(Text(.DraftPublication.draftPublicationPublishSelectedHelp))
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .disabled(busy)
        }
    }

    private var decisionActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            BoardMRIntentActions(row: presentationRow, monitor: monitor)
            ReReviewControls(item: presentationItem, monitor: monitor.attention)
            InboxAttentionActions(item: presentationItem, feedbackAction: monitor.attentionFeedbackAction(for: item),
                onFeedback: { Task { await monitor.runAttentionFeedback(for: item) } },
                onPipeline: { monitor.confirmPipelineHandoff(for: item.id) },
                onMerge: { NSWorkspace.shared.open(item.url) })
        }
    }

    private func feedbackCheck(citationContext: MRCommentCitation.Context?) -> some View {
        DisclosureGroup(isExpanded: $feedbackExpanded) {
            if feedbackExpanded {
                AuthorFeedbackView(item: presentationItem, monitor: monitor, citationContext: citationContext,
                    decisionUpdating: isUpdatingFeedbackDecision, onIgnoreSuggestion: presentIgnoreSuggestion).padding(.top, 8)
            }
        } label: { Text(.CommandCenter.commandCenterFeedbackCheck).font(.subheadline.weight(.medium)) }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            if detailsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    AssistantUsageMRDetailCost(mergeRequest: usageMergeRequest)
                    if let request = item.mergeRequest {
                        metadata(.CommandCenter.commandCenterAuthor,
                            value: request.author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? request.author.username : request.author.name)
                            .help(Text(verbatim: "@\(request.author.username)"))
                        metadata(.CommandCenter.commandCenterSource, value: request.sourceBranch)
                        metadata(.CommandCenter.commandCenterTarget, value: request.targetBranch)
                        if let sha = request.sha { metadata(.CommandCenter.commandCenterCommit, value: sha, monospaced: true) }
                        metadata(.CommandCenter.commandCenterMergeState,
                            value: request.detailedMergeStatus?.replacingOccurrences(of: "_", with: " ")
                                ?? String(localized: .CommandCenter.commandCenterStatusUnavailable))
                        metadata(.CommandCenter.commandCenterPipeline,
                            value: request.headPipeline?.status.replacingOccurrences(of: "_", with: " ")
                                ?? String(localized: .CommandCenter.commandCenterNoPipeline))
                    }
                    if finishedState == nil { statusReasons }
                    IgnoredFeedbackSuggestionsView(entries: ignoredSuggestions, mergeRequestURL: item.url,
                        isUpdating: isUpdatingFeedbackDecision, onRestore: restoreSuggestion, onReset: {
                            guard let target else { return }
                            feedbackDecisionConfirmation = .init(target: target)
                        })
                    if let feedbackDecisionError {
                        Text(verbatim: feedbackDecisionError).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 12)
            }
        } label: { Text(.CommandCenter.commandCenterDetails).font(.headline) }
    }

    @ViewBuilder
    private func supplementaryActions(citationContext: MRCommentCitation.Context?) -> some View {
        if !showsDecisions {
            if item.needsConfirmation { confirmationControls }
            decisionActions
            if item.authorFeedbackStatus != nil { feedbackCheck(citationContext: citationContext).id(Anchor.feedbackStatus) }
        }
        if !item.isAuthored && !monitor.mrTodoIntents(for: item).contains(where: { $0.kind == .review }) {
            Button {
                isStartingReview = true
                reviewStartError = nil
                let expectedTarget = discussionTarget
                Task {
                    defer { isStartingReview = false }
                    await monitor.runReview(for: item)
                    if discussionTarget == expectedTarget { reviewStartError = monitor.assistantJobActionError }
                }
            } label: {
                Label { Text(isStartingReview ? .CommandCenter.commandCenterReviewStarting : .CommandCenter.commandCenterReviewRun) }
                    icon: { Image(systemName: "text.magnifyingglass") }
            }
            .controlSize(.small)
            .disabled(isStartingReview || !monitor.canRunReview(for: item))
            .help(Text(.CommandCenter.commandCenterReviewHelp))
        }
        if let reviewStartError {
            Text(verbatim: reviewStartError).font(.caption).foregroundStyle(.orange)
        }
    }

    private func openHistory(proxy: ScrollViewProxy) {
        historyExpanded = true
        focusedJobID = jobs.first?.id
        historyNavigationID = UUID()
        Task { await scroll(to: .assistantRuns, proxy: proxy) }
    }

    private func metadata(_ label: LocalizedStringResource, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(verbatim: value).font(monospaced ? .caption.monospaced() : .subheadline)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var statusReasons: some View {
        if item.hasConflict { reason(.Menu.menuAttentionConflict) }
        if item.failedPipeline { reason(.Menu.menuAttentionPipeline) }
        if item.needsChanges { reason(.Menu.menuAttentionChanges) }
        if item.needsDiscussion { reason(.Menu.menuAttentionDiscussions) }
        if item.reReviewRequested { reason(.Menu.menuScopeReReviewRequested) }
        if item.reReviewUnconfirmed { reason(.Menu.menuAttentionReReviewUnconfirmed) }
    }

    private func reason(_ text: LocalizedStringResource) -> some View {
        Label { Text(text) } icon: { Image(systemName: "info.circle") }.font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func attentionSourceEvidence(for action: MRHumanAction, citationContext: MRCommentCitation.Context?) -> some View {
        if let reply = action.preparedReply,
           let draft = item.drafts.first(where: { $0.id == reply.draftID }) {
            let root = item.rejectedDrafts.first { $0.draftID == reply.draftID }?.discussionRootNoteID
            if let source = citationContext?.reply(to: draft, rootNoteID: root) {
                // A source quotation never waives a rejected reply's factual checks.
                MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceReply)
            } else { sourceUnavailable }
        } else if let noteID = action.sourceNoteID, let status = item.authorFeedbackStatus,
                  let finding = status.findings.first(where: { $0.sourceNoteID == noteID }) {
            if let source = citationContext?.finding(finding, status: status) {
                if !feedbackExpanded {
                    MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceAssessment)
                    if let reason = finding.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ignoreSuggestionButton(source, summary: AgentExplanation.summary(finding.summary) ?? reason, reason: reason)
                    }
                }
            } else { sourceUnavailable }
        } else if [.blockedRun, .interruptedRun].contains(action.kind), let job = jobs.first,
                  job.workflow == .followUp, !(job.feedbackNoteIDs ?? []).isEmpty {
            let sources = citationContext?.followUp(job) ?? []
            if sources.isEmpty { sourceUnavailable }
            ForEach(sources) { source in
                MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceRun)
            }
        } else if [.feedback, .reviewDecision].contains(action.kind), let status = item.authorFeedbackStatus,
                  let finding = status.findings.first(where: {
                      [.needsChanges, .needsVerification].contains($0.state) || status.replyNoteIDs.contains($0.id)
                  }) {
            if let source = citationContext?.finding(finding, status: status) {
                if !feedbackExpanded {
                    MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceAssessment)
                    if let reason = finding.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ignoreSuggestionButton(source, summary: AgentExplanation.summary(finding.summary) ?? reason, reason: reason)
                    }
                }
            } else { sourceUnavailable }
        }
    }

    private var sourceUnavailable: some View {
        Text(.FeedbackSuggestions.feedbackSuggestionsSourceUnavailable).font(.caption).foregroundStyle(.secondary)
    }

    private func ignoreSuggestionButton(_ source: MRCommentCitation, summary: String, reason: String) -> some View {
        Button { presentIgnoreSuggestion(source, summary, reason) } label: {
            Text(.FeedbackSuggestions.feedbackSuggestionsIgnore)
        }
        .buttonStyle(.plain).foregroundStyle(.orange).disabled(isUpdatingFeedbackDecision)
    }

    private func presentIgnoreSuggestion(_ source: MRCommentCitation, _ summary: String, _ reason: String) {
        guard let target, !isUpdatingFeedbackDecision else { return }
        feedbackDecisionError = nil
        feedbackDecisionConfirmation = .init(target: target, note: source.note, summary: summary, reason: reason)
    }

    private func confirmFeedbackDecision(_ choice: FeedbackDecisionConfirmation) {
        feedbackDecisionConfirmation = nil
        updateFeedbackDecision {
            if let note = choice.note {
                try await monitor.ignoreFeedbackSuggestion(note, concernSummary: choice.summary,
                    concernReason: choice.reason, for: choice.target)
            } else {
                try await monitor.resetFeedbackSuggestionDecisions(for: choice.target)
            }
        }
    }

    private func restoreSuggestion(_ decision: IgnoredFeedbackSuggestion) {
        updateFeedbackDecision { try await monitor.restoreFeedbackSuggestion(decision.id, for: decision.target) }
    }

    private func updateFeedbackDecision(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isUpdatingFeedbackDecision else { return }
        isUpdatingFeedbackDecision = true
        feedbackDecisionError = nil
        Task {
            defer { isUpdatingFeedbackDecision = false }
            do { try await operation() }
            catch {
                let message: LocalizedStringResource
                switch error as? FeedbackSuggestionDecisionError {
                case .sourceChanged?: message = .FeedbackSuggestions.feedbackSuggestionsSourceChanged
                case .accountChanged?, .invalidTarget?: message = .FeedbackSuggestions.feedbackSuggestionsAccountChanged
                case .invalidConcern?: message = .FeedbackSuggestions.feedbackSuggestionsInvalidConcern
                default: message = .FeedbackSuggestions.feedbackSuggestionsUpdateFailed
                }
                feedbackDecisionError = String(localized: message)
            }
            refreshDiscussions()
        }
    }

    private var discussionThreads: some View {
        let current = discussionTarget != nil && discussionStore.target == discussionTarget
        let snapshot = MRDiscussionSnapshot(discussions: current ? discussionStore.discussions : [], drafts: item.drafts,
                                            origins: current ? discussionStore.origins : [:])
        return MRDiscussionThreadsView(snapshot: snapshot, mergeRequestURL: item.url,
            currentUsername: monitor.glab.currentUsername, isLoading: current && discussionStore.isLoading,
            hasError: current && discussionStore.hasError, hasLoaded: current && discussionStore.hasLoaded,
            expandPendingDrafts: initialSection == .drafts,
            selection: finishedState == nil && item.needsConfirmation && current ? $draftSelection : nil,
            selectionDisabled: monitor.attention.confirmationStates[item.id] == .publishing
                || monitor.attention.confirmationStates[item.id] == .approving,
            onRefresh: refreshDiscussions)
    }

    private func refreshDiscussions() {
        guard let target = discussionTarget else { discussionStore.clear(); return }
        Task { await discussionStore.refresh(target: target, glab: monitor.glab) }
    }


}
