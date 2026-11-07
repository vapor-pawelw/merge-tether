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
    @State private var discussionStore = MRDiscussionStore()
    @State private var draftSelection = DraftPublicationSelection()
    @State private var detailsExpanded = false
    @State private var feedbackExpanded = false
    @State private var historyExpanded = false
    @State private var focusedJobID: UUID?
    @State private var historyNavigationID = UUID()
    @State private var pendingInitialAnchor: Anchor?
    @State private var initialDiscussionAttemptFinished = false

    private enum Anchor: Hashable { case overview, drafts, comments, details, actions, feedbackStatus, assistantRuns }

    private var target: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }
    private var work: AssistantAutomationRunner.MergeRequestWork? {
        target.map { .init(host: $0.host, projectID: item.id.projectID, iid: item.id.iid) }
    }
    private var presentationItem: MergeRequestAttentionMonitor.Item {
        var value = item
        value.humanActionRequired = needsHumanAttention
        return value
    }
    private var jobs: [AssistantAutomationRunner.Handoff] {
        guard let work, let target else { return [] }
        return monitor.assistantHandoffs.filter { $0.key.work == work && $0.key.username == target.username && !$0.isObsoleteReminder }.sorted { $0.createdAt > $1.createdAt }
    }
    private var humanAction: MRHumanAction? {
        let ready = monitor.availableAssistants.contains(monitor.settings.automation.assistant)
        let automatic = target.map {
            item.draftIDsHandledAutomatically(automation: monitor.settings.automation, target: $0,
                assistantPreparing: ready || monitor.assistantDependencies.isChecking)
        } ?? []
        return MRHumanAction(row: .init(item: presentationItem, latestJob: jobs.first,
            intents: monitor.mrTodoIntents(for: item)), assistantReady: ready,
            confirmationState: monitor.attention.confirmationStates[item.id], automaticallyPublishedDraftIDs: automatic)
    }
    private var showsDecisions: Bool { needsHumanAttention || initialSection == .drafts }
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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id(Anchor.overview)
                    if showsDecisions { nextStep(proxy: proxy).id(Anchor.drafts) }
                    supplementaryActions.id(Anchor.actions)
                    discussionThreads.id(Anchor.comments)
                    details.id(Anchor.details)
                    MRAutomationEventLogView(target: target, monitor: monitor,
                        initiallyExpanded: historyExpanded, initiallyExpandedJobID: focusedJobID)
                        .id(historyNavigationID).id(Anchor.assistantRuns)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { selectedPublicationActions }
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
            }
            .onChange(of: needsHumanAttention) { _, required in
                if required && item.authorFeedbackStatus?.needsAttention == true { feedbackExpanded = true }
            }
            .onDisappear { discussionStore.cancel() }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "!\(item.id.iid)").monospacedDigit()
                RepositoryPathText(item.url.gitLabProjectPath).lineLimit(1)
                if let author = item.mergeRequest?.author {
                    AvatarView(url: author.avatarURL, size: 18).accessibilityHidden(true)
                    Text(verbatim: author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? author.username : author.name).lineLimit(1)
                        .help(Text(verbatim: "@\(author.username)"))
                }
                Spacer()
                headerMenu
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Text(verbatim: item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack {
                Label {
                    Text(needsHumanAttention ? .CommandCenter.commandCenterStatusAttention
                         : item.section == .draftMergeRequests ? .CommandCenter.commandCenterStatusDraft
                         : .CommandCenter.commandCenterStatusMonitoring)
                } icon: { Image(systemName: needsHumanAttention ? "exclamationmark.circle" : "arrow.triangle.pull") }
                .font(.subheadline).foregroundStyle(needsHumanAttention ? .orange : .secondary)
                Spacer()
                Link(destination: item.url) {
                    Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var headerMenu: some View {
        Menu {
            AssistantContextMenu(mergeRequestURL: item.url, title: item.title,
                                 workspace: monitor.settings.automation.assistantWorkspace)
            if let target {
                Divider()
                MRAutomationScopeMenu(settings: monitor.settings, target: target, projectPath: item.url.gitLabProjectPath)
                if !item.isAuthored, monitor.settings.automation.autoApproveEnabled {
                    Toggle(isOn: approvalBinding(target)) { Text(.CommandCenter.commandCenterAutoApprove) }
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
    }

    private func nextStep(proxy: ScrollViewProxy) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let action = humanAction {
                    if let detail = action.detail { Text(verbatim: detail).textSelection(.enabled) }
                    else if !item.needsConfirmation || (action.kind != .publication && action.kind != .approval) {
                        Text(action.message)
                    }
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
                if let retryError {
                    Text(verbatim: retryError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if item.needsConfirmation { confirmationControls }
                decisionActions
                if item.authorFeedbackStatus != nil { feedbackCheck.id(Anchor.feedbackStatus) }
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
            BoardMRIntentActions(row: .init(item: presentationItem, latestJob: jobs.first,
                intents: monitor.mrTodoIntents(for: item)), monitor: monitor)
            ReReviewControls(item: presentationItem, monitor: monitor.attention)
            InboxAttentionActions(item: presentationItem, feedbackAction: monitor.attentionFeedbackAction(for: item),
                onFeedback: { Task { await monitor.runAttentionFeedback(for: item) } },
                onPipeline: { monitor.confirmPipelineHandoff(for: item.id) },
                onMerge: { NSWorkspace.shared.open(item.url) })
        }
    }

    private var feedbackCheck: some View {
        DisclosureGroup(isExpanded: $feedbackExpanded) {
            if feedbackExpanded {
                AuthorFeedbackView(item: presentationItem, monitor: monitor).padding(.top, 8)
            }
        } label: { Text(.CommandCenter.commandCenterFeedbackCheck).font(.subheadline.weight(.medium)) }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            if detailsExpanded {
                VStack(alignment: .leading, spacing: 10) {
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
                    statusReasons
                }
                .padding(.top, 12)
            }
        } label: { Text(.CommandCenter.commandCenterDetails).font(.headline) }
    }

    @ViewBuilder
    private var supplementaryActions: some View {
        if !showsDecisions {
            if item.needsConfirmation { confirmationControls }
            decisionActions
            if item.authorFeedbackStatus != nil { feedbackCheck.id(Anchor.feedbackStatus) }
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

    private var discussionThreads: some View {
        let current = discussionTarget != nil && discussionStore.target == discussionTarget
        let snapshot = MRDiscussionSnapshot(discussions: current ? discussionStore.discussions : [], drafts: item.drafts,
                                            origins: current ? discussionStore.origins : [:])
        return MRDiscussionThreadsView(snapshot: snapshot, mergeRequestURL: item.url,
            currentUsername: monitor.glab.currentUsername, isLoading: current && discussionStore.isLoading,
            hasError: current && discussionStore.hasError, hasLoaded: current && discussionStore.hasLoaded,
            expandPendingDrafts: initialSection == .drafts,
            selection: item.needsConfirmation && current ? $draftSelection : nil,
            selectionDisabled: monitor.attention.confirmationStates[item.id] == .publishing
                || monitor.attention.confirmationStates[item.id] == .approving,
            onRefresh: refreshDiscussions)
    }

    private func refreshDiscussions() {
        guard let target = discussionTarget else { discussionStore.clear(); return }
        Task { await discussionStore.refresh(target: target, glab: monitor.glab) }
    }

    private func approvalBinding(_ target: MRAutomationScope.Target) -> Binding<Bool> {
        Binding(get: { !monitor.settings.autoApproveOptOuts.contains(target) }, set: { enabled in
            if enabled { monitor.settings.autoApproveOptOuts.remove(target) }
            else { monitor.settings.autoApproveOptOuts.insert(target) }
            monitor.settings.save()
        })
    }
}
