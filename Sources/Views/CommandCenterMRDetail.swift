import AppKit
import MergeTetherRemote
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
        let selected = CommandCenterDisplayFrame.Detail(item: item, board: monitor.boardSnapshot,
            host: monitor.glab.resolvedHost, username: monitor.glab.currentUsername)
        let row = selected.row
        let required = row?.item.humanActionRequired ?? item.humanActionRequired ?? needsHumanAttention
        CommandCenterMRDetailContent(item: selected.item, catalogRow: row, isReviewed: selected.isReviewed,
            monitor: monitor, initialSection: initialSection, needsHumanAttention: required)
            .overlay(alignment: .bottomTrailing) {
                if let notice = monitor.automationToggleNotices.current,
                   case .approvalChanged(let target, _) = notice.kind,
                   target == monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
                    AutomationToggleNoticeView(notice: notice) { monitor.automationToggleNotices.dismiss(notice.id) }
                        .padding(18)
                }
            }
    }

    private var needsHumanAttention: Bool {
        guard let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
        let key = "\(target.host)/\(target.username)/mr/\(item.id.projectID)/\(item.id.iid)"
        return monitor.userAttention.items.contains { $0.id == key }
    }
}

private struct CommandCenterMRDetailContent: View {
    let item: MergeRequestAttentionMonitor.Item
    let catalogRow: MergeRequestBoardSnapshot.Row?
    let isReviewed: Bool
    let monitor: TodoMonitorService
    let initialSection: CommandCenterMRDetailSection
    let needsHumanAttention: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var isStartingReview = false
    @State private var reviewStartError: String?
    @State private var isRetrying = false
    @State private var retryError: String?
    @State private var confirmRemoval = false
    @State private var isResettingReview = false
    @State private var discussionStore = MRDiscussionStore()
    @State private var publicationSession = DraftPublicationSession()
    @State private var footerPublication: [GitLabDraftNote]? = nil
    @State private var detailsExpanded = false
    @State private var usageExpanded = false
    @State private var feedbackExpanded = false
    @State private var commentsExpanded = true
    @State private var historyExpanded = false
    @State private var focusedJobID: UUID?
    @State private var historyNavigationID = UUID()
    @State private var pendingInitialAnchor: Anchor?
    @State private var initialDiscussionAttemptFinished = false
    @State private var isManuallyRefreshingDiscussions = false
    @State private var feedbackDecisionConfirmation: FeedbackDecisionConfirmation?
    @State private var isUpdatingFeedbackDecision = false
    @State private var feedbackDecisionError: String?
    @State private var originChangeFailed = false
    @State private var regenerationPresentation: DraftRegenerationPresentation?
    @State private var discussionNavigation: MRDiscussionNavigation?

    private enum Anchor: Hashable { case overview, drafts, comments, details, actions, feedbackStatus, assistantRuns }

    private var finishedState: MergeRequestFinishedState? { .init(presentationRow.displayRequest) }
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
    private var presentationItem: MergeRequestAttentionMonitor.Item { presentationRow.item }
    private var jobs: [AssistantAutomationRunner.Handoff] {
        guard let work, let target else { return [] }
        return monitor.assistantHandoffs.filter { $0.key.work == work && $0.key.username == target.username && !$0.isObsoleteReminder }.sorted { $0.createdAt > $1.createdAt }
    }
    private var presentationRow: MergeRequestBoardSnapshot.Row {
        catalogRow ?? .init(item: item, latestJob: jobs.first, intents: monitor.mrTodoIntents(for: item),
                pipelineEvidence: jobs.first.flatMap { monitor.currentRequest(for: $0) },
                pipelineEvidenceCheckedAt: monitor.currentPipelineEvidenceDate)
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
            let author = note.author?.person.displayName ?? ""
            let concern = summary == reason ? summary : summary + "\n" + reason
            return String(localized: .FeedbackSuggestions.feedbackSuggestionsConcern) + "\n" + concern
                + "\n\n" + String(localized: .FeedbackSuggestions.feedbackSuggestionsComment)
                + " · " + author + " · #" + String(note.id ?? 0) + "\n" + preview
                + "\n\n" + String(localized: .FeedbackSuggestions.feedbackSuggestionsIgnoreExplanation)
        }
    }

    private var citationContext: MRCommentCitation.Context? {
        guard let target = discussionTarget else { return nil }
        return discussionStore.citationContext(target: target, request: item.mergeRequest,
            accountRevision: monitor.glab.accountRevision)
    }
    private var ignoredSuggestions: [IgnoredFeedbackSuggestion] {
        target.map { monitor.settings.feedbackSuggestionDecisions.entries(for: $0) } ?? []
    }

    private var showsPublication: Bool { finishedState == nil && !item.drafts.isEmpty }
    private var showsDecisions: Bool { finishedState == nil && (needsHumanAttention || initialSection == .drafts || showsPublication) }
    private var showsFeedbackDetails: Bool {
        finishedState == nil && presentationItem.authorFeedbackStatus?.hasVisibleDetails == true
    }
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

    private var discussionCodeContext: MRDiscussionCodeContext? {
        guard let discussionTarget else { return nil }
        let request = presentationRow.displayRequest
        return .init(target: discussionTarget, accountRevision: monitor.glab.accountRevision,
            sourceProjectID: request?.sourceProjectID, targetProjectID: request?.targetProjectID, glab: monitor.glab)
    }

    var body: some View {
        let citationContext = self.citationContext
        let discussions = discussionSnapshot
        let presentation = MRCardPresentation(row: presentationRow, monitor: monitor, allowsRemoval: isReviewed)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(presentation).id(Anchor.overview)
                    // The decision the user has to make leads; merge state and automation rules support it.
                    if showsDecisions {
                        nextStep(proxy: proxy, citationContext: citationContext, discussions: discussions,
                            humanAction: presentation.humanAction).id(Anchor.drafts)
                    }
                    if finishedState == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            MergeActionsView(item: item, monitor: monitor,
                                evidenceMatchesCatalogContext: presentationRow.evidenceMatchesCatalogContext,
                                actionsBlocked: isStartingReview || isRetrying, onReviewFeedback: {
                                    feedbackExpanded = showsFeedbackDetails
                                    commentsExpanded = true
                                    Task { await scroll(to: .feedbackStatus, proxy: proxy) }
                                }, showsExplanations: false,
                                showsReplySources: !(showsDecisions && showsFeedbackDetails),
                                showsFeedbackVerification: presentationItem.authorFeedbackStatus == nil,
                                showsStatusCard: true,
                                textFont: .callout,
                                coveredBlockers: shownRequirements(presentation)?.coveredBlockers ?? [],
                                hidesBlockedActions: presentation.working, highlightedSubmission: presentation.mergeStage?.submission, statusTrailer: {
                                    MREffectivePolicySummary(row: presentationRow, monitor: monitor,
                                        excluding: [presentation.humanAction?.explanation ?? "",
                                            presentation.mergeStage.map { String(localized: $0.title) } ?? ""], holdsOnly: true)
                                }, additionalActions: { _ in EmptyView() })
                            supplementaryActions(citationContext: citationContext)
                        }
                        .id(Anchor.actions)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        discussionThreads(discussions).id(Anchor.comments)
                        Divider()
                        MREventLogView(target: target, discussionTarget: discussionTarget, discussions: eventDiscussions,
                            monitor: monitor, initiallyExpanded: historyExpanded, initiallyExpandedJobID: focusedJobID,
                            readOnly: finishedState != nil,
                            openDiscussion: { openDiscussion(noteID: $0, discussionID: $1, in: discussions) })
                            .id(historyNavigationID).id(Anchor.assistantRuns)
                        Divider()
                        details.id(Anchor.details)
                        if let usageMergeRequest {
                            Divider()
                            DisclosureGroup(isExpanded: $usageExpanded) {
                                AssistantUsageMRDetailCost(mergeRequest: usageMergeRequest).padding(.top, 12)
                            } label: { Text(.AssistantUsage.assistantUsageDashboardTitle).font(.headline) }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disclosureGroupStyle(MRDetailDisclosureStyle())
            .background(.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if finishedState == nil { selectedPublicationActions }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if discussionTarget != nil, !initialDiscussionAttemptFinished || isManuallyRefreshingDiscussions {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(.MRDiscussions.mrDiscussionsLoading)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
                if let target = originTarget, let change = monitor.commentOrigins.pending(for: target) {
                    CommentOriginResumeBanner(change: change, onUndo: {
                        do { try monitor.commentOrigins.undo(change.id) } catch { originChangeFailed = true }
                    }, onContinue: { Task { await monitor.commentOrigins.continueNow(change.id) } })
                }
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
                    if item.canConfirmReReview || item.reReviewReadiness?.hasConcreteConcerns == true {
                        pendingInitialAnchor = showsDecisions ? .drafts : .actions
                    } else if showsFeedbackDetails {
                        feedbackExpanded = true
                        pendingInitialAnchor = .feedbackStatus
                    } else {
                        commentsExpanded = true
                        pendingInitialAnchor = showsDecisions ? .drafts : .comments
                    }
                }
            }
            .task(id: initialDestinationIsReady) {
                guard initialDestinationIsReady, let anchor = pendingInitialAnchor else { return }
                await scroll(to: anchor, proxy: proxy)
                guard !Task.isCancelled else { return }
                pendingInitialAnchor = nil
            }
            .task(id: discussionNavigation) {
                guard let discussionNavigation, commentsExpanded else { return }
                await Task.yield()
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(discussionNavigation.anchor, anchor: .top)
            }
            .task(id: discussionTarget) {
                initialDiscussionAttemptFinished = false
                monitor.requestIssueAssessment(for: presentationRow.displayRequest)
                guard let target = discussionTarget else {
                    discussionStore.clear()
                    initialDiscussionAttemptFinished = true
                    return
                }
                while !Task.isCancelled {
                    await loadDiscussions(target)
                    guard !Task.isCancelled else { return }
                    initialDiscussionAttemptFinished = true
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .onChange(of: monitor.attention.confirmationStates[item.id]) { old, current in
                if old?.isBusy == true && current?.isBusy != true { refreshDiscussions() }
            }
            .onChange(of: monitor.attention.displayAIOriginCoordinator?.revision) { _, _ in
                Task { await discussionStore.reloadOrigins(glab: monitor.glab) }
            }
            .onChange(of: monitor.commentOrigins.revision) { _, _ in
                Task { await discussionStore.reloadOrigins(glab: monitor.glab) }
            }
            .onChange(of: jobs.first?.id) { _, _ in retryError = nil }
            .onAppear {
                publicationSession.open(with: item.drafts, accountAvailable: discussionTarget != nil,
                    duplicateIDs: item.duplicateDraftIDs)
            }
            .onChange(of: item.drafts) { _, drafts in
                publicationSession.draftsChanged(drafts)
                Task { await discussionStore.reloadOrigins(glab: monitor.glab) }
            }
            .onChange(of: discussionTarget) { _, _ in
                publicationSession.clearSelection()
                discussionNavigation = nil
                regenerationPresentation = nil
                reviewStartError = nil
                feedbackDecisionConfirmation = nil
                feedbackDecisionError = nil
            }
            .onChange(of: needsHumanAttention) { _, required in
                if required && item.authorFeedbackStatus?.needsAttention == true { feedbackExpanded = true }
            }
            .onDisappear {
                discussionStore.cancel()
                publicationSession.close()
            }
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
            .alert(Text(.MRDiscussions.mrDiscussionsOriginChangeFailed), isPresented: $originChangeFailed) {
                Button(role: .cancel) {} label: { Text(.MRDiscussions.mrDiscussionsOriginCancel) }
            } message: { Text(.MRDiscussions.mrDiscussionsOriginChangeFailedMessage) }
            .confirmationDialog(Text(.Board.boardRemove), isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button(role: .destructive) { monitor.removeReviewedMergeRequest(item) } label: { Text(.Board.boardRemove) }
            } message: { Text(.Board.boardRemoveExplanation) }
            .sheet(item: $regenerationPresentation) { monitor.draftRegenerationSheet($0) }
            .environment(\.gitLabPersonSourceURL, item.url)
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
            let destination = anchor == .feedbackStatus && !showsFeedbackDetails ? Anchor.comments : anchor
            proxy.scrollTo(destination, anchor: .top)
        }
    }

    private func header(_ progress: MRCardPresentation) -> some View {
        let mergeActivity = progress.mergeActivity
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    BoardMRReferenceLine(iid: item.id.iid, projectID: item.id.projectID,
                        repositoryPath: presentationRow.displayURL.gitLabProjectPath)
                    let issues = monitor.issueTags(for: presentationRow.displayRequest)
                    if !issues.isEmpty { MRIssueTag(issues: issues) }
                    if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
                    else if presentationRow.isDraft { BoardDraftBadge() }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    if finishedState == nil, let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
                        BoardAutomationToggle(monitor: monitor, target: target, projectPath: item.url.gitLabProjectPath,
                            isDraft: presentationRow.isDraft, policy: automationPolicy)
                    }
                    BoardPinButton(pin: .mergeRequest(host: monitor.glab.resolvedHost,
                        username: monitor.glab.currentUsername, projectID: item.id.projectID, iid: item.id.iid),
                        settings: monitor.settings)
                    GitLabRefreshButton(monitor: monitor, itemID: item.id, placement: .header) {
                        if let target = discussionTarget { await discussionStore.refresh(target: target, glab: monitor.glab) }
                    }
                    .buttonStyle(.plain)
                    .boardHeaderControlHover()
                    .accessibilityLabel(Text(.MRFreshness.mrFreshnessRefresh))
                    CopyMergeRequestLinkButton(url: item.url, placement: .header)
                    Link(destination: item.url) { BoardCardActionIcon(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .boardHeaderControlHover()
                        .help(Text(.CommandCenter.commandCenterOpenGitLab))
                        .accessibilityLabel(Text(.CommandCenter.commandCenterOpenGitLab))
                    headerMenu
                }
                .fixedSize()
            }
            .font(.callout).foregroundStyle(.secondary)
            .zIndex(1)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: presentationRow.displayTitle).font(.title2.weight(.semibold))
                    .lineLimit(3).textSelection(.enabled)
                HStack(spacing: 0) {
                    if let author = ReviewingContext(row: presentationRow).author {
                        BoardCardAuthor(author: author)
                    }
                    Spacer(minLength: 16)
                    if finishedState == nil {
                        BoardMRApprovalBadge(row: presentationRow, monitor: monitor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if let request = presentationRow.displayRequest {
                    Label { Text(verbatim: request.sourceBranch + " → " + request.targetBranch) } icon: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsBranches(request.sourceBranch, request.targetBranch)))
                }
            }
            .padding(.top, 2)
            MergeRequestDescription(source: presentationRow.displayRequest?.description,
                title: .CommandCenter.commandCenterDescription, expandHint: .CommandCenter.commandCenterExpandDescription,
                collapseHint: .CommandCenter.commandCenterCollapseDescription)
            if let stage = progress.mergeStage {
                MRMergeStageBanner(stage: stage, startedAt: monitor.activityStartedAt(for: item, activity: mergeActivity))
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let finishedState {
                        Text(finishedState.status).font(.callout).foregroundStyle(.secondary)
                    } else {
                        // The Next step box below already states what needs attention.
                        let genericAttention = needsHumanAttention && (progress.working || progress.status == nil)
                        if let waiting = shownRequirements(progress) {
                            VStack(alignment: .leading, spacing: 5) { BoardWaitingRequirements(waiting: waiting) }
                                .font(.callout)
                                .modifier(MRDetailStatusCard())
                        } else if (needsHumanAttention || !progress.working && progress.mergeStage == nil)
                                    && !(genericAttention && showsDecisions) {
                            Label {
                                if let message = progress.statusPeopleMessage {
                                    PeopleMessageLabel(message: message)
                                } else if let status = progress.status, !progress.working {
                                    Text(verbatim: status)
                                } else { Text(.CommandCenter.commandCenterStatusAttention) }
                            } icon: { Image(systemName: needsHumanAttention ? "exclamationmark.circle" : "arrow.triangle.pull") }
                            .font(.callout.weight(needsHumanAttention ? .medium : .regular))
                            .foregroundStyle(needsHumanAttention ? .orange : .secondary)
                        }
                        if progress.working, mergeActivity == nil, let status = progress.status {
                            MRActivityStatus(status: status,
                                startedAt: monitor.activityStartedAt(for: item, activity: progress.activity), effect: progress.activityEffect)
                            .font(.callout).foregroundStyle(.secondary)
                        } else if progress.refreshFailed {
                            Label { Text(verbatim: progress.refreshFailureLabel ?? String(localized: .AutomationProgress.progressRefreshFailed)) }
                                icon: { Image(systemName: "arrow.clockwise") }
                                .help(progress.refreshFailureHelp ?? "")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            if let dependencies = item.dependencies, dependencies.hasPresentation {
                MRDependencyRow(summary: dependencies, projectID: item.id.projectID)
            }
            if let request = item.mergeRequest,
               let status = monitor.authoredMergeRequests.requests.first(where: {
                   MergeRequestDependencySummary.Context($0.request) == MergeRequestDependencySummary.Context(request)
               }), status.blockers.contains(where: { [.dependencies, .stackTarget, .dependencyEvidence].contains($0) }),
               let reason = status.dependencyReadiness.holdReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if finishedState != nil {
                Button { monitor.acknowledgeFinishedMergeRequest(item) } label: { Text(.MRLifecycle.seen) }
                    .buttonStyle(.bordered).help(Text(.MRLifecycle.seenHelp))
            } else if monitor.canMarkMergeRequestReady(item) || presentationItem.authorFeedbackStatus != nil {
                HStack(spacing: 10) {
                    MarkMergeRequestReadyButton(item: item, monitor: monitor).buttonStyle(.bordered)
                    if let feedback = presentationItem.authorFeedbackStatus {
                        Button {
                            guard confirmMRAction(.verifyFeedback, title: .AuthorFeedback.authorFeedbackRecheck) else { return }
                            monitor.attention.retryAuthorFeedback(item.id)
                        } label: {
                            MRActionLabel(title: .AuthorFeedback.authorFeedbackRecheck, cta: .verifyFeedback)
                        }
                        .buttonStyle(.bordered)
                        .disabled(feedback.phase == .checking)
                        .mrActionHelp(.verifyFeedback)
                    }
                }
            }
        }
    }

    /// The card's requirement list, shown where the single waiting sentence used to be.
    private func shownRequirements(_ progress: MRCardPresentation) -> MRWaitingStatus? {
        guard !needsHumanAttention, !progress.working, let waiting = progress.waitingStatus,
              !waiting.requirements.isEmpty else { return nil }
        return waiting
    }

    /// Saved rules for this MR: in the automation toggle's help and under Details, not beside blockers.
    private var automationPolicy: MREffectivePolicyPresentation {
        MREffectivePolicySummary.presentation(row: presentationRow, monitor: monitor).0
    }

    private var routinePolicy: [LocalizedStringResource] { automationPolicy.routineClauses.map(\.message) }

    private var headerMenu: some View {
        BoardActionsMenu {
            MRCommonMenuItems(item: item, monitor: monitor,
                onRemove: isReviewed ? { confirmRemoval = true } : nil)
        }
    }

    private func nextStep(proxy: ScrollViewProxy, citationContext: MRCommentCitation.Context?,
                          discussions: MRDiscussionSnapshot, humanAction: MRHumanAction?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.CommandCenter.commandCenterNextStep).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                if let action = humanAction {
                    if !item.needsConfirmation || (action.kind != .publication && action.kind != .approval) {
                        Text(verbatim: action.explanation).font(.body.weight(.medium)).foregroundStyle(.primary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = action.detail, detail != action.explanation,
                       AgentExplanation.summary(detail) != action.explanation, action.preparedReply == nil {
                        AgentDiagnosticDetails(reason: detail)
                    }
                    attentionSourceEvidence(for: action, citationContext: citationContext)
                    if action.action == .retryRun, let job = jobs.first {
                        HStack {
                            Button {
                                guard !isRetrying,
                                      confirmAssistantRetry(job, for: item, monitor: monitor, title: action.actionLabel) else { return }
                                isRetrying = true
                                retryError = nil
                                Task {
                                    defer { isRetrying = false }
                                    guard monitor.assistantHandoffs.contains(where: { $0.id == job.id }) else { return }
                                    await monitor.retryAssistantJob(job.id)
                                    retryError = monitor.assistantJobActionError
                                }
                            } label: {
                                MRActionLabel(title: action.actionLabel, cta: .retryRun, working: isRetrying)
                            }
                            .buttonStyle(.borderedProminent)
                            .mrActionHelp(.retryRun)
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
                        Button {
                            guard confirmMRAction(.retryDraftVerification, title: action.actionLabel) else { return }
                            monitor.attention.retryDraftProofRecovery(item.id)
                        } label: {
                            MRActionLabel(title: action.actionLabel, cta: .retryDraftVerification)
                        }
                            .buttonStyle(.borderedProminent)
                            .mrActionHelp(.retryDraftVerification)
                    } else if action.action == .setupAssistant {
                        Button { openSettings() } label: { Text(action.actionLabel) }
                    } else if action.action == .reviewIssue {
                        Button { detailsExpanded = true; Task { await scroll(to: .details, proxy: proxy) } } label: {
                            Text(action.actionLabel)
                        }
                    }
                } else if !needsHumanAttention && !item.needsConfirmation && !showsPublication {
                    Text(.CommandCenter.commandCenterNoPendingDecision).foregroundStyle(.secondary)
                }
                if let job = jobs.first { AssistantJobPreflightNotice(jobID: job.id, monitor: monitor) }
                if let retryError {
                    Text(verbatim: retryError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let feedbackDecisionError {
                    Text(verbatim: feedbackDecisionError).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if item.needsConfirmation || showsPublication { confirmationControls }
                if showsPublication {
                    if discussionTarget == nil {
                        Text(.DraftPublication.draftPublicationUnavailable).font(.callout).foregroundStyle(.secondary)
                    }
                    draftRegenerationButton
                    publicationThreads(discussions)
                }
                decisionActions
                FollowUpAutomationHoldView(row: presentationRow, monitor: monitor)
                if showsFeedbackDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        feedbackCheck(citationContext: citationContext).id(Anchor.feedbackStatus)
                    }
                }
            }
            .font(.body).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background((needsHumanAttention ? Color.orange.opacity(0.06) : Color.secondary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder((needsHumanAttention ? Color.orange : Color.secondary).opacity(0.2), lineWidth: 0.5)
            }
            .overlay(alignment: .leading) {
                if needsHumanAttention {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.7))
                        .frame(width: 3).padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var draftRegenerationButton: some View {
        let coordinator = monitor.draftRegeneration
        let scope = DraftRegenerationScope.mergeRequest(projectID: item.id.projectID, iid: item.id.iid)
        if let phase = coordinator.batch?.phase {
            Button { regenerationPresentation = .init(scope: nil) } label: {
                Label(phase.regenerationTitle, systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
        } else if coordinator.count(for: scope) > 0 {
            Button { regenerationPresentation = .init(scope: scope) } label: {
                Label(.DraftRegeneration.draftRegenerationMrAction, systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .disabled(!coordinator.isAvailable)
            .accessibilityIdentifier("draft-regeneration.merge-request")
        }
    }

    private var regenerateDraft: ((GitLabDraftNote) -> Void)? {
        guard monitor.draftRegeneration.isAvailable, monitor.draftRegeneration.batch == nil,
              discussionTarget != nil else { return nil }
        return { draft in
            guard let id = draft.id else { return }
            let scope = DraftRegenerationScope.draft(projectID: item.id.projectID, iid: item.id.iid, draftID: id)
            guard monitor.draftRegeneration.count(for: scope) > 0 else { return }
            regenerationPresentation = .init(scope: scope)
        }
    }

    private var confirmationControls: some View {
        let publishSelected: (([GitLabDraftNote]) async -> Void)? = discussionTarget.map { target in
            { selected in await monitor.attention.publishDrafts(selected, for: target) }
        }
        return ConfirmationQueueRow(item: item, state: monitor.attention.confirmationStates[item.id],
            onPublish: { await monitor.attention.publishDrafts(of: item.id) },
            onApprove: { await monitor.attention.approve(item.id) },
            onOpen: { NSWorkspace.shared.open(item.url) }, initiallyExpanded: initialSection == .drafts,
            showDraftPreview: false, showHeader: false, selection: $publicationSession.selection,
            onPublishSelected: publishSelected, requiresSelection: true,
            onDelete: { draft in Task { await monitor.attention.deleteDraft(draft, from: item.id) } },
            onFinishCommentReview: { _ = await monitor.attention.finishCommentReview(item) },
            additionalActions: EmptyView())
    }

    @ViewBuilder
    private var selectedPublicationActions: some View {
        let selected = footerPublication ?? publicationSession.selection.selectedDrafts(from: item.drafts)
        if !selected.isEmpty, let target = discussionTarget {
            let state = monitor.attention.confirmationStates[item.id]
            let busy = footerPublication != nil || state?.isBusy == true
            VStack(alignment: .leading, spacing: 8) {
                DraftPublicationWarnings(drafts: selected)
                HStack(spacing: 12) {
                    Button { publicationSession.clearSelection() } label: {
                        Text(.DraftPublication.draftPublicationClearSelection)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        guard !busy else { return }
                        let title = selected.count == item.drafts.count
                            ? LocalizedStringResource.CommentReview.commentReviewPublishSelected(selected.count)
                            : .DraftPublication.draftPublicationPublishSelected(selected.count)
                        guard confirmSelectedDraftPublication(title: title, publishesAll: selected.count == item.drafts.count) else { return }
                        footerPublication = selected
                        Task {
                            defer { footerPublication = nil }
                            await monitor.attention.publishDrafts(selected, for: target)
                        }
                    } label: {
                        MRActionProgressLabel(working: footerPublication != nil) {
                            // Only publishing every draft lets the paused workflow continue.
                            if selected.count == item.drafts.count {
                                MRActionLabel(title: .CommentReview.commentReviewPublishSelected(selected.count), cta: .publishComments)
                            } else {
                                Text(.DraftPublication.draftPublicationPublishSelected(selected.count))
                            }
                        }
                    }
                    .mrActionHelp(.publishComments, detail: .CommentReview.commentReviewPublishSelectedHelp)
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .disabled(busy)
        }
    }

    /// Flattened into the caller's stack so absent controls leave no empty gap.
    @ViewBuilder
    private var decisionActions: some View {
            CommentReviewImpactView(item: item, reReviewEnabled: monitor.settings.automation.autoReReviewEnabled)
            BoardMRIntentActions(row: presentationRow, monitor: monitor)
            ReReviewControls(item: presentationItem, monitor: monitor.attention, assistant: monitor.settings.automation.assistant,
                hidesStaleResult: MRCardPresentation(row: presentationRow, monitor: monitor, allowsRemoval: isReviewed).working)
            InboxAttentionActions(item: presentationItem, feedbackAction: monitor.attentionFeedbackAction(for: item),
                assistant: presentationRow.latestJob?.key.assistant ?? monitor.settings.automation.assistant,
                onFeedback: { Task { await monitor.runAttentionFeedback(for: item) } },
                onPipeline: { monitor.confirmPipelineHandoff(for: item.id) },
                onMerge: { NSWorkspace.shared.open(item.url) })
    }

    private func feedbackCheck(citationContext: MRCommentCitation.Context?) -> some View {
        DisclosureGroup(isExpanded: $feedbackExpanded) {
            AuthorFeedbackView(item: presentationItem, monitor: monitor, embedded: true,
                citationContext: citationContext, sourceLoading: feedbackSourceLoading,
                decisionUpdating: isUpdatingFeedbackDecision, onIgnoreSuggestion: presentIgnoreSuggestion).padding(.top, 6)
        } label: { Text(.CommandCenter.commandCenterFeedbackCheck).font(.callout.weight(.medium)) }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            if detailsExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    if let request = item.mergeRequest {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            GridRow(alignment: .firstTextBaseline) {
                                Text(.CommandCenter.commandCenterAuthor).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                PersonLabel(person: request.author.person).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.callout)
                            metadata(.CommandCenter.commandCenterSource, value: request.sourceBranch)
                            metadata(.CommandCenter.commandCenterTarget, value: request.targetBranch)
                            if let sha = request.sha { metadata(.CommandCenter.commandCenterCommit, value: sha, monospaced: true) }
                            metadata(.CommandCenter.commandCenterMergeState,
                                value: request.detailedMergeStatus.map(Self.readableStatus)
                                    ?? String(localized: .CommandCenter.commandCenterStatusUnavailable))
                            metadata(.CommandCenter.commandCenterPipeline,
                                value: request.headPipeline.map { Self.readableStatus($0.status) }
                                    ?? String(localized: .CommandCenter.commandCenterNoPipeline))
                        }
                    }
                    if finishedState == nil { statusReasons }
                    if finishedState == nil, !routinePolicy.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(.EffectivePolicy.policyAutomationRules).font(.callout).foregroundStyle(.secondary)
                            ForEach(Array(routinePolicy.enumerated()), id: \.offset) { _, rule in
                                Text(rule).font(.callout)
                            }
                        }
                    }
                    IgnoredFeedbackSuggestionsView(entries: ignoredSuggestions, mergeRequestURL: item.url,
                        isUpdating: isUpdatingFeedbackDecision, onRestore: restoreSuggestion, onReset: {
                            guard let target else { return }
                            feedbackDecisionConfirmation = .init(target: target)
                        })
                    if let feedbackDecisionError {
                        Text(verbatim: feedbackDecisionError).font(.caption).foregroundStyle(.orange)
                    }
                    reviewResetButton
                }
                .padding(.top, 12)
            }
        } label: { Text(.CommandCenter.commandCenterDetails).font(.headline) }
    }

    /// Emergency action kept at the bottom of Details: discards incremental review state for a full fresh pass.
    @ViewBuilder private var reviewResetButton: some View {
        if item.mergeRequest?.state == "opened" {
            Button { confirmReviewReset() } label: {
                Label { Text(isResettingReview ? .ReviewReset.reviewResetRunning : .ReviewReset.reviewResetButton) }
                    icon: { Image(systemName: "arrow.counterclockwise") }
            }
            .buttonStyle(.link)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(isResettingReview || isStartingReview || !monitor.canResetReviewState(for: item))
            .help(Text(item.isAuthored ? .ReviewReset.reviewResetHelpAuthored : .ReviewReset.reviewResetHelpReviewed))
        }
    }

    private func confirmReviewReset() {
        let mode = monitor.manualReviewConsent(for: item).publicationMode
        let kind = item.isAuthored ? "authored" : mode.rawValue
        let message = item.isAuthored
            ? String(localized: .ReviewReset.reviewResetHelpAuthored)
            : String(localized: .ReviewReset.reviewResetHelpReviewed) + "\n\n" + String(localized: mode.reviewConfirmation)
        guard confirmMRAction(id: "resetReview.\(kind)", title: .ReviewReset.reviewResetConfirmTitle,
            button: .ReviewReset.reviewResetConfirm, message: message) else { return }
        resetReviewState()
    }

    private func resetReviewState() {
        isResettingReview = true
        reviewStartError = nil
        let expectedTarget = discussionTarget
        Task {
            defer { isResettingReview = false }
            await monitor.resetReviewState(for: item)
            if discussionTarget == expectedTarget { reviewStartError = monitor.assistantJobActionError }
        }
    }

    @ViewBuilder
    private func supplementaryActions(citationContext: MRCommentCitation.Context?) -> some View {
        if !showsDecisions {
            if item.needsConfirmation { confirmationControls }
            // Flattened: an empty wrapper would still take the parent's spacing.
            decisionActions
            FollowUpAutomationHoldView(row: presentationRow, monitor: monitor)
            if showsFeedbackDetails { feedbackCheck(citationContext: citationContext).id(Anchor.feedbackStatus) }
        }
        if !item.isAuthored && !monitor.mrTodoIntents(for: item).contains(where: { $0.kind == .review }) {
            Button {
                guard let consent = confirmManualReview(for: item, monitor: monitor) else { return }
                isStartingReview = true
                reviewStartError = nil
                let expectedTarget = discussionTarget
                Task {
                    defer { isStartingReview = false }
                    await monitor.runReview(for: item, confirmed: consent)
                    if discussionTarget == expectedTarget { reviewStartError = monitor.assistantJobActionError }
                }
            } label: {
                MRActionLabel(title: .CommandCenter.commandCenterReviewRun, cta: .runReview, working: isStartingReview)
            }
            .controlSize(.small)
            .disabled(isStartingReview || !monitor.canRunReview(for: item))
            .mrActionHelp(.runReview)
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

    /// GitLab reports raw identifiers such as `not_approved`; show them as plain words.
    private static func readableStatus(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func metadata(_ label: LocalizedStringResource, value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
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
        Label { Text(text).foregroundStyle(.primary) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            .labelStyle(BoardCardStatusLabelStyle()).font(.callout)
    }

    @ViewBuilder
    private func attentionSourceEvidence(for action: MRHumanAction, citationContext: MRCommentCitation.Context?) -> some View {
        if let reply = action.preparedReply,
           let draft = item.drafts.first(where: { $0.id == reply.draftID }) {
            let root = item.rejectedDrafts.first { $0.draftID == reply.draftID }?.discussionRootNoteID
            if let source = citationContext?.reply(to: draft, rootNoteID: root) {
                MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceReply)
            } else { unavailableSource(root) }
        } else {
            switch action.feedbackEvidence(for: item) {
            case .finding(let finding):
                if let status = item.authorFeedbackStatus, let source = citationContext?.finding(finding, status: status) {
                    if !showsFeedbackDetails || !feedbackExpanded {
                        MRCommentCitationView(citation: source, relation: .FeedbackSuggestions.feedbackSuggestionsSourceAssessment)
                        if let reason = finding.reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ignoreSuggestionButton(source, summary: AgentExplanation.summary(finding.summary) ?? reason, reason: reason)
                        }
                    }
                } else { unavailableSource(finding.sourceNoteID) }
            case .replyThreads(let roots):
                ForEach(roots, id: \.self) { root in
                    commentEvidence(root, fingerprint: item.authorFeedbackStatus?.fingerprint,
                        relation: .FeedbackSuggestions.feedbackSuggestionsSourceReplyThread, citationContext: citationContext)
                }
            case .reReview(let blockers):
                ForEach(blockers, id: \.noteID) { blocker in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(blocker.isUncertain || item.reReviewReadiness?.isUncertain == true ? .FeedbackSuggestions.feedbackSuggestionsUnverifiedConcern
                            : .FeedbackSuggestions.feedbackSuggestionsConfirmedConcern).font(.caption).foregroundStyle(.secondary)
                        if blocker.noteID != action.sourceNoteID {
                            let summary = AgentExplanation.summary(blocker.summary) ?? AgentExplanation.summary(blocker.reason)
                            if let summary { Text(verbatim: summary).textSelection(.enabled) }
                            if AgentExplanation.summary(blocker.reason) != summary { AgentDiagnosticDetails(reason: blocker.reason) }
                        }
                        commentEvidence(blocker.noteID, fingerprint: item.reReviewFingerprint,
                            relation: .FeedbackSuggestions.feedbackSuggestionsSourceAssessment, citationContext: citationContext)
                    }
                }
            case .rawNotes(let ids):
                ForEach(ids, id: \.self) { id in
                    commentEvidence(id, fingerprint: item.observedDiscussionFingerprint,
                        relation: action.kind == .intent ? .FeedbackSuggestions.feedbackSuggestionsSourceRequest
                            : .FeedbackSuggestions.feedbackSuggestionsSourceOpen, citationContext: citationContext)
                }
            case .gitLabStatus:
                Text(.FeedbackSuggestions.feedbackSuggestionsSourceStatus).font(.caption).foregroundStyle(.secondary)
            case .unavailable(let id): unavailableSource(id)
            case .none: EmptyView()
            }
        }
    }

    @ViewBuilder
    private func commentEvidence(_ id: Int, fingerprint: String?, relation: LocalizedStringResource,
                                 citationContext: MRCommentCitation.Context?) -> some View {
        if let source = citationContext?.comment(id, fingerprint: fingerprint) {
            MRCommentCitationView(citation: source, relation: relation)
        } else { unavailableSource(id) }
    }

    private func unavailableSource(_ noteID: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceUnavailable
            if let noteID, let url = noteURL(noteID) {
                Link(destination: url) { Text(.Menu.menuReReviewNote(noteID)) }.font(.caption)
            }
        }
    }

    private func noteURL(_ id: Int) -> URL? {
        guard id > 0, var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = "note_\(id)"
        return components.url
    }

    private var feedbackSourceLoading: Bool {
        discussionTarget != nil && (!initialDiscussionAttemptFinished || discussionStore.isLoading)
    }

    private var sourceUnavailable: some View {
        Text(feedbackSourceLoading ? .FeedbackSuggestions.feedbackSuggestionsSourceLoading : .FeedbackSuggestions.feedbackSuggestionsSourceUnavailable)
            .font(.caption).foregroundStyle(.secondary)
    }

    private func ignoreSuggestionButton(_ source: MRCommentCitation, summary: String, reason: String) -> some View {
        Button { presentIgnoreSuggestion(source, summary, reason) } label: {
            Text(.FeedbackSuggestions.feedbackSuggestionsIgnore)
        }
        .buttonStyle(.plain).foregroundStyle(.orange).disabled(isUpdatingFeedbackDecision)
        .mrActionHelp(.ignoreSuggestion)
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

    private var discussionSnapshot: MRDiscussionSnapshot {
        let current = discussionStore.hasCurrentTarget(discussionTarget, accountRevision: monitor.glab.accountRevision)
        let request = presentationRow.displayRequest
        let assessment = current && discussionStore.hasLoaded && !discussionStore.hasError
            ? request.flatMap { request in
                discussionStore.discussionFingerprint.flatMap {
                    monitor.attention.discussionAssessment(for: request, fingerprint: $0,
                        activeFingerprint: discussionStore.activeDiscussionFingerprint)
                }
            } : nil
        return discussionStore.presentationSnapshot(target: discussionTarget, accountRevision: monitor.glab.accountRevision,
            drafts: item.drafts, assessment: assessment, authorID: request?.author.id)
    }

    private func publicationThreads(_ snapshot: MRDiscussionSnapshot) -> some View {
        let current = discussionStore.hasCurrentTarget(discussionTarget, accountRevision: monitor.glab.accountRevision)
        return MRDiscussionThreadsView(snapshot: snapshot.pendingPublication, mergeRequestURL: item.url,
            currentUsername: monitor.glab.currentUsername, isLoading: current && discussionStore.isLoading,
            hasError: current && discussionStore.hasError, hasLoaded: current && discussionStore.hasLoaded,
            expandPendingDrafts: true, selection: $publicationSession.selection,
            selectionDisabled: discussionTarget == nil || monitor.attention.confirmationStates[item.id]?.isBusy == true,
            onDelete: { draft in Task { await monitor.attention.deleteDraft(draft, from: item.id) } },
            onRegenerate: regenerateDraft,
            title: .DraftPublication.draftPublicationThreads, codeContext: discussionCodeContext, onSetOrigin: originAction,
            extraContexts: current ? discussionStore.extraContexts : .empty,
            currentUserIdentity: current ? discussionStore.currentUser : nil, replyRecipients: item.replyRecipients,
            navigation: discussionNavigation,
            onRefresh: { refreshDiscussions(visible: true) })
    }

    private var eventDiscussions: MREventLogView.Discussions {
        let current = discussionStore.hasCurrentTarget(discussionTarget, accountRevision: monitor.glab.accountRevision)
        return .init(entries: current ? discussionStore.activity : [],
            isLoading: discussionTarget != nil && (!initialDiscussionAttemptFinished || discussionStore.isLoading),
            hasError: current && discussionStore.hasError)
    }

    private func openDiscussion(noteID: Int, discussionID: String?, in snapshot: MRDiscussionSnapshot) -> Bool {
        guard let thread = snapshot.threads.first(where: {
            (discussionID == nil || $0.discussionID == discussionID) && $0.notes.contains { $0.id == noteID }
        }) else { return false }
        commentsExpanded = true
        discussionNavigation = .init(anchor: .init(threadID: thread.id))
        return true
    }

    private var originTarget: MRAutomationScope.Target? {
        monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url)
    }

    /// Origins can be corrected only for the conversation currently loaded for this account.
    private var originAction: MRDiscussionOriginAction? {
        guard finishedState == nil, let target = originTarget, discussionTarget != nil,
              discussionStore.hasCurrentTarget(discussionTarget, accountRevision: monitor.glab.accountRevision),
              discussionStore.hasLoaded, !discussionStore.hasError else { return nil }
        let discussions = discussionStore.discussions
        return { classification, notes in
            Task {
                do {
                    try await monitor.setCommentOrigin(classification, notes: notes, in: discussions, for: target)
                } catch { originChangeFailed = true }
            }
        }
    }

    @ViewBuilder private func discussionThreads(_ discussions: MRDiscussionSnapshot) -> some View {
        let current = discussionStore.hasCurrentTarget(discussionTarget, accountRevision: monitor.glab.accountRevision)
        let snapshot = showsPublication ? discussions.remainingDiscussions : discussions
        if !showsPublication || !snapshot.threads.isEmpty {
            MRDiscussionThreadsView(snapshot: snapshot, mergeRequestURL: item.url,
            currentUsername: monitor.glab.currentUsername, isLoading: current && discussionStore.isLoading,
            hasError: current && discussionStore.hasError, hasLoaded: current && discussionStore.hasLoaded,
            codeContext: discussionCodeContext, onSetOrigin: originAction, extraContexts: current ? discussionStore.extraContexts : .empty,
                currentUserIdentity: current ? discussionStore.currentUser : nil, replyRecipients: item.replyRecipients,
                navigation: discussionNavigation, expansion: $commentsExpanded,
                onRefresh: { refreshDiscussions(visible: true) })
        }
    }

    private func refreshDiscussions(visible: Bool = false) {
        guard let target = discussionTarget else { discussionStore.clear(); return }
        if visible { isManuallyRefreshingDiscussions = true }
        Task {
            defer { if visible { isManuallyRefreshingDiscussions = false } }
            await loadDiscussions(target)
        }
    }

    private func loadDiscussions(_ target: MRDiscussionTarget) async {
        await discussionStore.refresh(target: target, glab: monitor.glab)
        guard !Task.isCancelled, discussionStore.target == target, discussionStore.hasLoaded, !discussionStore.hasError,
              let request = presentationRow.displayRequest, let coordinator = monitor.attention.displayAIOriginCoordinator else { return }
        let notes = discussionStore.discussions.flatMap(\.notes), known = Set(discussionStore.origins.keys)
        Task { await coordinator.schedule(request: request, notes: notes, knownNoteIDs: known) }
    }


}
