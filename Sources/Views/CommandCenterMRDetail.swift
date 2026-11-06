import AppKit
import SwiftUI

enum CommandCenterMRDetailSection: Hashable {
    case overview, drafts, assistantRuns, feedback

    var title: LocalizedStringResource {
        switch self {
        case .overview: .CommandCenter.commandCenterOverview
        case .drafts: .CommandCenter.commandCenterConfirmations
        case .assistantRuns: .AssistantJobs.assistantJobsTitle
        case .feedback: .CommandCenter.commandCenterFeedback
        }
    }
}

struct CommandCenterMRDetail: View {
    let item: MergeRequestAttentionMonitor.Item
    let monitor: TodoMonitorService
    var initialSection: CommandCenterMRDetailSection = .overview
    @Environment(\.openSettings) private var openSettings
    @State private var isStartingReview = false
    @State private var discussionStore = MRDiscussionStore()
    @State private var detailsExpanded = false
    @State private var automationExpanded = false
    @State private var feedbackExpanded = false
    @State private var runsExpanded = false
    @State private var activityExpanded = false
    @State private var showAllRuns = false
    @State private var showAllActivity = false
    @State private var pendingInitialAnchor: Anchor?
    @State private var initialDiscussionAttemptFinished = false

    private enum Anchor: Hashable { case overview, drafts, comments, details, automation, feedbackStatus, assistantRuns }

    private var target: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }
    private var work: AssistantAutomationRunner.MergeRequestWork? {
        target.map { .init(host: $0.host, projectID: item.id.projectID, iid: item.id.iid) }
    }
    private var needsHumanAttention: Bool {
        guard let target else { return false }
        let key = "\(target.host)/\(target.username)/mr/\(item.id.projectID)/\(item.id.iid)"
        return monitor.userAttention.items.contains { $0.id == key }
    }
    private var presentationItem: MergeRequestAttentionMonitor.Item {
        var value = item
        value.humanActionRequired = needsHumanAttention
        return value
    }
    private var jobs: [AssistantAutomationRunner.Handoff] {
        guard let work else { return [] }
        return monitor.assistantHandoffs.filter { $0.key.work == work }.sorted { $0.createdAt > $1.createdAt }
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
    private var workflowEntries: [MergeWorkflowActivityEntry] {
        monitor.authoredMergeRequests.workflow.entries.filter {
            $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                && $0.event.mergeRequest.webURL == item.url
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id(Anchor.overview)
                    if showsDecisions { nextStep(proxy: proxy).id(Anchor.drafts) }
                    discussionThreads.id(Anchor.comments)
                    details.id(Anchor.details)
                    automation.id(Anchor.automation)
                    agentRuns.id(Anchor.assistantRuns)
                    recentActivity
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
            .task(id: initialSection) {
                pendingInitialAnchor = nil
                if needsHumanAttention && item.authorFeedbackStatus?.needsAttention == true { feedbackExpanded = true }
                switch initialSection {
                case .overview: return
                case .drafts:
                    pendingInitialAnchor = .drafts
                case .assistantRuns:
                    runsExpanded = true
                    pendingInitialAnchor = .assistantRuns
                case .feedback:
                    if item.canConfirmReReview {
                        if !showsDecisions { automationExpanded = true }
                        pendingInitialAnchor = showsDecisions ? .drafts : .automation
                    } else if item.authorFeedbackStatus != nil {
                        feedbackExpanded = true
                        if !showsDecisions { automationExpanded = true }
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
        proxy.scrollTo(anchor, anchor: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "!\(item.id.iid)").monospacedDigit()
                RepositoryPathText(item.url.gitLabProjectPath).lineLimit(1)
                if let author = item.mergeRequest?.author {
                    AvatarView(url: author.avatarURL, size: 18).accessibilityHidden(true)
                    Text(verbatim: "@\(author.username)").lineLimit(1)
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
                    if action.action == .reviewRun {
                        Button { runsExpanded = true; Task { await scroll(to: .assistantRuns, proxy: proxy) } } label: {
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
                if item.needsConfirmation { confirmationControls }
                decisionActions
                if item.authorFeedbackStatus != nil { feedbackCheck.id(Anchor.feedbackStatus) }
            }
            .font(.subheadline).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text(.CommandCenter.commandCenterNextStep).font(.headline) }
    }

    private var confirmationControls: some View {
        ConfirmationQueueRow(item: item, state: monitor.attention.confirmationStates[item.id],
            onPublish: { Task { await monitor.attention.publishDrafts(of: item.id) } },
            onApprove: { Task { await monitor.attention.approve(item.id) } },
            onOpen: { NSWorkspace.shared.open(item.url) }, initiallyExpanded: initialSection == .drafts,
            showDraftPreview: false, showHeader: false, additionalActions: EmptyView())
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
            AuthorFeedbackView(item: presentationItem, monitor: monitor).padding(.top, 8)
        } label: { Text(.CommandCenter.commandCenterFeedbackCheck).font(.subheadline.weight(.medium)) }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let request = item.mergeRequest {
                    metadata(.CommandCenter.commandCenterAuthor, value: "@\(request.author.username)")
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
        } label: { Text(.CommandCenter.commandCenterDetails).font(.headline) }
    }

    private var automation: some View {
        DisclosureGroup(isExpanded: $automationExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !showsDecisions {
                    if item.needsConfirmation { confirmationControls }
                    decisionActions
                    if item.authorFeedbackStatus != nil { feedbackCheck.id(Anchor.feedbackStatus) }
                }
                if !item.isAuthored && !monitor.mrTodoIntents(for: item).contains(where: { $0.kind == .review }) {
                    Button {
                        isStartingReview = true
                        Task { defer { isStartingReview = false }; await monitor.runReview(for: item) }
                    } label: {
                        Label { Text(isStartingReview ? .CommandCenter.commandCenterReviewStarting : .CommandCenter.commandCenterReviewRun) }
                            icon: { Image(systemName: "text.magnifyingglass") }
                    }
                    .disabled(isStartingReview || !monitor.canRunReview(for: item))
                    .help(Text(.CommandCenter.commandCenterReviewHelp))
                }
                if let error = monitor.assistantJobActionError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                }
            }
            .controlSize(.small).padding(.top, 12)
        } label: { Text(.CommandCenter.commandCenterAutomation).font(.headline) }
    }

    private var agentRuns: some View {
        DisclosureGroup(isExpanded: $runsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if jobs.isEmpty { Text(.AssistantJobs.assistantJobsEmpty).foregroundStyle(.secondary) }
                ForEach(showAllRuns ? jobs : Array(jobs.prefix(1))) { job in AssistantJobRow(handoff: job, monitor: monitor) }
                if jobs.count > 1 {
                    Button { showAllRuns.toggle() } label: {
                        Text(showAllRuns ? .CommandCenter.commandCenterShowLess : .CommandCenter.commandCenterShowAll)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.top, 12)
        } label: {
            Text(.CommandCenter.commandCenterAgentRunsCount(jobs.count)).font(.headline)
                .help(Text(.AssistantJobs.assistantJobsExplanation))
        }
    }

    private var recentActivity: some View {
        DisclosureGroup(isExpanded: $activityExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if workflowEntries.isEmpty { Text(.CommandCenter.commandCenterActivityEmpty).foregroundStyle(.secondary) }
                ForEach(showAllActivity ? workflowEntries : Array(workflowEntries.prefix(3))) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.event.kind.displayLabel).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(entry.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: entry.summary ?? entry.event.context)
                            .font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                }
                if workflowEntries.count > 3 {
                    Button { showAllActivity.toggle() } label: {
                        Text(showAllActivity ? .CommandCenter.commandCenterShowLess : .CommandCenter.commandCenterShowAll)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.top, 12)
        } label: { Text(.CommandCenter.commandCenterActivity).font(.headline) }
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
            expandPendingDrafts: initialSection == .drafts, onRefresh: refreshDiscussions)
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
