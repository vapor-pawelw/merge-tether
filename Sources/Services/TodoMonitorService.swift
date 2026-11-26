import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class TodoMonitorService {
    let settings: SettingsManager
    let cliHealth = AssistantCLIHealthStore.shared
    let glab: GlabService
    @ObservationIgnored var reviewerEdits: Set<MergeRequestAttentionMonitor.Item.ID> = []
    let notifications: NotificationService
    let attention: MergeRequestAttentionMonitor
    var draftRegeneration: DraftRegenerationCoordinator { attention.draftRegeneration }
    let authoredMergeRequests: AuthoredMergeRequestMonitor
    @ObservationIgnored var mergeRequestIssues: MRIssueCoordinator?
    @ObservationIgnored var forcedIssueBoardRevision: UInt64?
    @ObservationIgnored var issueDetailsRefreshes = 0
    private var boardDisplayMetadata = MRDisplayMetadataCache()
    @ObservationIgnored private let boardProjectorCache: ObservedPresentationCache<MRBoardProjector?>
    @ObservationIgnored let boardSnapshotCache: ObservedPresentationCache<MergeRequestBoardSnapshot>
    @ObservationIgnored let commandCenterDisplayFrameCache: ObservedPresentationCache<CommandCenterDisplayFrame>
    @ObservationIgnored private var liveBoardPresentationRead: Bool?
    let autoHandledEventBanners = AutoHandledEventBannerCenter()

    var autoHandledEventBanner: AutoHandledEventBannerCenter.Event? {
        autoHandledEventBanners.current(host: glab.resolvedHost, username: glab.currentUsername,
                                       enabled: settings.autoHandledEventBannersEnabled)
    }

    func dismissAutoHandledEventBanner(_ id: UUID) { autoHandledEventBanners.dismiss(id) }

    let automationToggleNotices = AutomationToggleNoticeCenter()

    enum GlobalAutomationConfirmation: Equatable {
        case cancel
        case confirm
        case confirmAndSkipFuturePrompts
    }

    func requestGlobalAutomationToggle(confirm: (_ enabling: Bool) -> GlobalAutomationConfirmation) {
        guard settings.configuredAutomationAvailable else { return }
        let enabling = !settings.automationGloballyEnabled
        let response = settings.confirmGlobalAutomationChanges ? confirm(enabling) : .confirm
        guard response != .cancel else { return }
        setAutomationGloballyEnabled(enabling, skipFutureConfirmations: response == .confirmAndSkipFuturePrompts)
    }

    /// The global killswitch overrides presets and per-MR choices without changing them.
    func setAutomationGloballyEnabled(_ enabled: Bool, skipFutureConfirmations: Bool = false) {
        guard settings.configuredAutomationAvailable, enabled != settings.automationGloballyEnabled else { return }
        if skipFutureConfirmations { settings.confirmGlobalAutomationChanges = false }
        settings.setAutomationGloballyEnabled(enabled)
        automationToggleNotices.post(.global(active: enabled))
    }

    private let boardAttentionPresenter = BoardAttentionPresenter()
    private var attentionPresentationAccount: GitLabAccountSession? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return .init(host: host, username: username, revision: glab.accountRevision)
    }
    var userAttention: UserAttentionSnapshot {
        boardAttentionPresenter.userAttention(account: attentionPresentationAccount)
    }

    var menuBarGitLabStatus: GitLabMenuBarStatus {
        .init(setupComplete: settings.onboardingCompleted, username: glab.currentUsername,
              authStatus: glab.authStatus, refresh: boardRefreshState, error: lastError,
              catalogFailed: attention.hasError || authoredMergeRequests.hasError)
    }

    private func attentionKey(_ item: MergeRequestAttentionMonitor.Item) -> String? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return "\(host)/\(username)/mr/\(item.id.projectID)/\(item.id.iid)"
    }

    func confirmedHumanAction(for row: MergeRequestBoardSnapshot.Row) -> MRHumanAction? {
        boardAttentionPresenter.confirmedHumanAction(key: attentionKey(row.item), account: attentionPresentationAccount)
    }

    func attentionRefreshFailed(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        MRBoardProjector.attentionRefreshFailed(for: row, input: boardRowInput(for: row))
    }

    func isRecheckingAttention(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        MRBoardProjector.isRecheckingAttention(for: row, input: boardRowInput(for: row))
    }

    /// Point queries capture only this row's existing read facts, never the account-wide board input.
    func boardRowInput(for row: MergeRequestBoardSnapshot.Row) -> MRBoardProjector.RowInput {
        let account: MRBoardProjector.Account? = glab.resolvedHost.flatMap { host in
            glab.currentUsername.map { .init(host: host, username: $0, revision: glab.accountRevision) }
        }
        let request = row.item.mergeRequest
        let workflowEntries = authoredMergeRequests.workflow.entries
        let publication = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
            .map { settings.publicationPolicy(for: $0) }
        let aiFailure = account.map {
            attention.aiOriginCoordinator.failure(work: .init(host: $0.host, projectID: row.id.projectID, iid: row.id.iid)) != nil
        } == true
        return .init(account: account, automation: settings.configuredAutomation, workflowEntries: workflowEntries,
            assistantReady: settings.automation.selectedAssistant.map(assistantDependencies.available.contains) == true,
            assistantChecking: checkingSelectedAssistant,
            confirmationBusy: attention.confirmationStates[row.id]?.isBusy == true,
            conflictProcessing: request.map { automaticConflictIsProcessing(for: $0) } == true,
            pipelineProcessing: request.map { authoredMergeRequests.workflow.isAutomaticallyProcessingPipeline($0, entries: workflowEntries) } == true,
            catalogLoading: isLoading || attention.isLoading || authoredMergeRequests.isLoading,
            catalogReadFailed: lastError != nil || attention.hasError || authoredMergeRequests.hasError,
            workflowReadFailed: request.map { authoredMergeRequests.workflow.hasReadOnlyFailure(for: $0) } == true,
            aiOriginReadFailed: aiFailure, publicationRequiresAI: publication?.requiresAI)
    }

    private let todoStore: InboxTodoStore
    let incomingReviewFilter: IncomingReviewFilterCoordinator
    var allTodos: [Todo] { todoStore.allTodos }
    private(set) var lastError: GlabError? {
        get { todoStore.lastError }
        set { todoStore.lastError = newValue }
    }
    var lastInboxActionError: GlabError? { todoStore.lastActionError }

    func dismissInboxActionFailure() { todoStore.dismissActionFailure() }

    private(set) var failedAutomationTodoID: Int?
    var lastRefresh: Date? { todoStore.lastRefresh }
    var isLoading: Bool { todoStore.isLoading }
    private let refreshProgress = RefreshProgressState()
    var showsGlobalRefreshProgress: Bool {
        boardRefreshState == .syncing || refreshProgress.showsGlobal(accountRevision: glab.accountRevision)
    }
    func showsRefreshProgress(for id: MergeRequestAttentionMonitor.Item.ID) -> Bool {
        boardRefreshState == .syncing || refreshProgress.showsRefresh(for: id, accountRevision: glab.accountRevision)
    }
    var assistantJobActionError: String?
    var markMergeRequestReadyError: String?
    @ObservationIgnored var boardPolicyOrder = BoardPolicyOrder()
    private(set) var assistantJobActionNotices: [UUID: String] = [:]
    let assistantDependencies: AssistantDependencyMonitor
    let reviewJobCoordinator: AssistantJobCoordinator?
    var availableAssistants: Set<AutomationAssistant> {
        assistantDependencies.available.filter { cliHealth.hold(for: $0) == nil }
    }
    var selectedAssistantReady: Bool {
        settings.automation.selectedAssistant.map(availableAssistants.contains) == true
    }
    var checkingSelectedAssistant: Bool {
        settings.automation.selectedAssistant != nil && assistantDependencies.isChecking
    }

    private var optimisticallyDone: Set<Int> { todoStore.optimisticallyDone }
    var undoableTodo: Todo? { todoStore.undoableTodo }
    static let undoWindow = InboxTodoStore.undoWindow
    private var inboxHost: String? { todoStore.host }
    private var inboxUsername: String? { todoStore.username }
    private var inboxAccountRevision: UInt64? { todoStore.accountRevision }
    @ObservationIgnored private let attentionNotificationScheduler: AttentionNotificationScheduler
    @ObservationIgnored private var manualAdoptions: [MRAutomationScope.Target: Int] = [:]
    private(set) var assessingMentionNoteIDs: Set<Int> = []

    func isAssessingNotice(_ todo: Todo) -> Bool {
        todo.linkedNoteID.map { assessingMentionNoteIDs.contains($0) } == true
    }
    private let automation: TodoAutomationService
    @ObservationIgnored var automaticRetryCoordinator: AssistantAutomaticRetryCoordinator?
    @ObservationIgnored var automaticRetryStartupTask: Task<Void, Never>?
    @ObservationIgnored var automaticRetryStartupID: UUID?
    @ObservationIgnored var automaticRetryRuntimeStarted = false
    @ObservationIgnored private lazy var environmentRecovery = makeEnvironmentRecovery()
    /// The user's comment-origin verdicts and their undo windows.
    @ObservationIgnored private(set) lazy var commentOrigins = makeCommentOriginCenter()

    private func makeEnvironmentRecovery() -> AutomaticEnvironmentRecovery {
        let recovery = AutomaticEnvironmentRecovery(settings: settings, fetch: { [weak self] original in
            guard let self, self.settings.automaticWritesAllowed, !Task.isCancelled,
                  self.glab.resolvedHost == original.key.work.host,
                  self.glab.currentUsername == original.key.username else { throw CancellationError() }
            let revision = self.glab.accountRevision
            let configuration = self.settings.automation
            async let user = self.glab.fetchAuthenticatedUser(host: original.key.work.host, expectedUsername: original.key.username)
            async let request = self.glab.fetchMergeRequest(projectID: original.key.work.projectID,
                iid: original.key.work.iid, host: original.key.work.host)
            async let discussions = self.glab.fetchMergeRequestDiscussions(projectID: original.key.work.projectID,
                iid: original.key.work.iid, host: original.key.work.host)
            let snapshot = try await AutomaticEnvironmentRecovery.Snapshot(request: request, user: user, discussions: discussions)
            guard self.settings.automaticWritesAllowed, self.settings.automation == configuration,
                  !Task.isCancelled, self.glab.resolvedHost == original.key.work.host,
                  self.glab.currentUsername == original.key.username, self.glab.accountRevision == revision else {
                throw CancellationError()
            }
            return snapshot
        }, launch: { [weak self] original, snapshot, prompt in
            guard let self, self.settings.automaticWritesAllowed, !Task.isCancelled,
                  self.glab.resolvedHost == original.key.work.host,
                  self.glab.currentUsername == original.key.username else { throw CancellationError() }
            return try await AssistantAutomationRunner.launch(original.key.assistant, title: original.title,
                mergeRequestURL: snapshot.request.webURL, prompt: prompt,
                workspace: self.settings.automation.assistantWorkspace, access: original.key.access,
                work: original.key.work, username: original.key.username, settings: self.settings,
                feedbackNoteIDs: original.feedbackNoteIDs ?? [], verifiedFeedbackNotes: original.verifiedFeedbackNotes,
                feedbackTodos: original.feedbackTodos ?? [],
                mrWorkflow: .followUp, manual: false, expectedHeadSHA: snapshot.request.sha, glab: self.glab, retryOf: original.id,
                taskIntent: original.taskIntent,
                workflowEventKind: original.workflowEventKind
                    ?? AssistantAutomationRunner.originatingWorkflowEvent(for: original, settings: self.settings))
        })
        recovery.onScheduled = { [weak self] oldID, replacement in
            self?.mrTodoRouter.rebindJob(oldID: oldID, replacement: replacement)
        }
        return recovery
    }
    @ObservationIgnored lazy var mrTodoRouter: MergeRequestTodoRouter = {
        let router = MergeRequestTodoRouter(settings: settings, glab: glab, canAutomate: { [weak self] in
            guard let self else { return false }
            let configuration = self.settings.automation
            guard let assistant = configuration.selectedAssistant else { return false }
            let revision = self.glab.accountRevision
            let ready = await AssistantCLI.detect(assistant).isReady
            // This probe also serves manual work; persistence is checked at each action boundary.
            return ready && !Task.isCancelled && self.settings.automation == configuration
                && self.glab.accountRevision == revision
        })
        router.onAcceptedIntent = { [weak self] intent in
            guard let self, self.manualAdoptions[intent.target, default: 0] == 0 else { return }
            autoHandledEventBanners.receive(intent, enabled: settings.autoHandledEventBannersEnabled)
        }
        router.followUpAssessment = { [weak self] request, discussions in
            guard let fingerprint = ReviewVerdict.fingerprint(discussions) else { return nil }
            return self?.attention.authorFeedbackCoordinator?.assessment(for: request, fingerprint: fingerprint)
        }
        router.blockedFollowUpCompletionProof = { [weak self] job, request, discussions in
            guard let self, self.glab.resolvedHost == job.key.work.host,
                  self.glab.currentUsername == job.key.username,
                  let fingerprint = ReviewVerdict.fingerprint(discussions),
                  let status = self.attention.authorFeedbackCoordinator?.status(projectID: request.projectID, iid: request.iid)
            else { return false }
            return status.reconciles(job, request: request, discussionFingerprint: fingerprint)
        }
        router.followUpVerificationPending = { [weak self] request, discussions in
            guard let fingerprint = ReviewVerdict.fingerprint(discussions) else { return false }
            return self?.attention.authorFeedbackCoordinator?.isChecking(for: request, fingerprint: fingerprint) == true
        }
        router.mentionDisposition = { [weak self] request, discussions, user, noteID in
            guard let self, let host = self.glab.resolvedHost,
                  self.glab.currentUsername == user.username else { return .uncertain }
            let configuration = self.settings.automation
            let revision = self.glab.accountRevision
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username,
                projectID: request.projectID, iid: request.iid)
            guard configuration.canClassifyIncomingNotices, configuration.scope.permits(request, host: host, username: user.username),
                  !self.settings.ignoredMergeRequests.contains(target) else { return .uncertain }
            let model = configuration.assistant == .codex
                ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
            self.assessingMentionNoteIDs.insert(noteID)
            defer { self.assessingMentionNoteIDs.remove(noteID) }
            let disposition = await MRNoticeClassifier.classify(request: request, discussions: discussions,
                user: user, noteID: noteID, assistant: configuration.assistant, model: model, expectedHost: host)
            guard self.glab.resolvedHost == host, self.glab.currentUsername == user.username,
                  self.glab.accountRevision == revision, self.settings.automation == configuration,
                  !self.settings.ignoredMergeRequests.contains(target) else { return .uncertain }
            return disposition
        }
        return router
    }()
    private let cancelPolicyJob: @MainActor (UUID, SettingsManager) -> Void
    @ObservationIgnored private lazy var feedbackLaunches: MRFeedbackLaunchCoordinator = {
        let residualLookup: @MainActor (GitLabMergeRequest, String) -> AuthorFeedbackResidual? = { [weak attention = attention] request, fingerprint in
            attention?.authorFeedbackCoordinator?.reviewContext(for: request, fingerprint: fingerprint)
        }
        return MRFeedbackLaunchCoordinator(settings: settings, glab: glab, automation: automation,
            inbox: todoStore, providers: assistantDependencies, health: cliHealth, residualLookup: residualLookup)
    }()
    private var timer: Timer?
    @ObservationIgnored private(set) lazy var assistantLimitRecovery = AssistantCLILimitRecovery(health: cliHealth) { [weak self] assistant in
        self?.assistantCLIHealthDidRecover(assistant)
    }
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeRefreshPending = false
    private var hasCompletedFirstFetch: Bool { todoStore.hasCompletedFirstFetch }

    init(
        settings: SettingsManager = SettingsManager(),
        glab: GlabService = GlabService(),
        notifications: NotificationService = NotificationService(),
        automation: TodoAutomationService = TodoAutomationService(),
        cancelPolicyJob: @escaping @MainActor (UUID, SettingsManager) -> Void = {
            AssistantAutomationRunner.cancel($0, settings: $1, origin: .policy)
        },
        schedulePresentationNotification: @escaping PresentationNotificationScheduler = PresentationNotificationDelivery.schedule,
        assistantDependencies: AssistantDependencyMonitor = AssistantDependencyMonitor(),
        reviewJobCoordinator: AssistantJobCoordinator? = nil
    ) {
        boardProjectorCache = .init(scheduleNotification: schedulePresentationNotification)
        boardSnapshotCache = .init(scheduleNotification: schedulePresentationNotification)
        commandCenterDisplayFrameCache = .init(scheduleNotification: schedulePresentationNotification)
        self.settings = settings
        self.glab = glab
        self.todoStore = InboxTodoStore(settings: settings, glab: glab)
        self.notifications = notifications
        self.assistantDependencies = assistantDependencies
        self.incomingReviewFilter = IncomingReviewFilterCoordinator(settings: settings, glab: glab,
            dependencies: assistantDependencies, health: .shared)
        self.reviewJobCoordinator = reviewJobCoordinator
        self.attentionNotificationScheduler = AttentionNotificationScheduler(notifications: notifications)
        self.automation = automation
        self.cancelPolicyJob = cancelPolicyJob
        // Test hosts keep verifier results in memory so suites never share persisted assessments.
        let isApplication = ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application
        let feedbackAssessments = isApplication ? AuthorFeedbackAssessmentStore.directory : nil
        self.attention = MergeRequestAttentionMonitor(glab: glab, settings: settings,
                                                       authorFeedbackAssessmentDirectory: feedbackAssessments)
        self.authoredMergeRequests = AuthoredMergeRequestMonitor(settings: settings, glab: glab)
        AssistantPowerActivity.configure(enabled: settings.keepMacAwakeDuringAgentTasks)
        if isApplication { self.mergeRequestIssues = makeIssueCoordinator() }
        todoStore.onAcknowledged = { [weak self] id in
            if self?.failedAutomationTodoID == id { self?.failedAutomationTodoID = nil }
        }
        incomingReviewFilter.onReleased = { [weak self] in self?.resumeIncomingReviews() }
        incomingReviewFilter.onHidden = { [weak self] reviews in self?.announceHiddenReviews(reviews, automatic: true) }
        attention.onReviewAssignmentsObserved = { [weak self] ledger, host, username in
            guard let self else { return }
            incomingReviewFilter.observeAssignments(ledger, host: host, username: username,
                excluding: existingReviewTargets(host: host, username: username))
        }
        attention.onRefreshed = { [weak self] in
            guard let self else { return }
            self.deliverLifecycleTransitions()
            self.cancelIneligibleDraftAutomation()
            // Publish the confirmed projection before consumers observe a completed fetch.
            // Observation's asynchronous invalidation remains responsible for other changes.
            self.boardAttentionPresenter.updateAttention(self.pendingUserAttention)
        }
        attention.onCommentReviewFinished = { [weak self] id in
            Task { await self?.refreshFromGitLab(for: id) }
        }
        attention.onDisplayMetadataObserved = { [weak self] request, target, revision, readStartedAt in
            self?.recordBoardDisplayRequest(request, for: target, url: request.webURL,
                accountRevision: revision, readStartedAt: readStartedAt)
        }
        attention.onIssueCatalogRefreshed = { [weak self] requests in
            self?.assessCatalogIssues(requests)
        }
        authoredMergeRequests.onObservedMergeRequests = { [weak self] requests, observedAt in
            self?.recordOwnedLifecycleObservations(requests, observedAt: observedAt)
        }
        authoredMergeRequests.onExactTerminalObservation = { [weak self] request, user, revision, observedAt in
            guard let self, let host = glab.resolvedHost else { return }
            _ = await attention.retireConfirmedLifecycle(request, host: host, user: user, revision: revision, readStartedAt: observedAt)
        }
        attention.onAutomationEligibilityObserved = { [weak self] in
            self?.cancelIneligibleDraftAutomation()
        }
        authoredMergeRequests.workflow.onRemoteChange = { [weak self] in
            Task { await self?.refreshNow() }
        }
        authoredMergeRequests.workflow.canStartAssistant = { [weak self] in
            self?.selectedAssistantReady == true
        }
        authoredMergeRequests.authorFeedbackAllowsMerge = { [weak self] request, discussions, authorID in
            guard let self, let host = self.glab.resolvedHost, let username = self.glab.currentUsername,
                  let fingerprint = ReviewVerdict.fingerprint(discussions),
                  let assessment = self.attention.authorFeedbackCoordinator?.assessment(for: request, fingerprint: fingerprint) else { return false }
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
            return assessment.hasNoRemainingAuthorWork(in: discussions, authorID: authorID,
                ignoredSuggestions: self.settings.feedbackSuggestionDecisions.applicable(in: discussions, for: target),
                excludedReplyAuthorIDs: self.settings.reviewParticipationPreferences.excludedIDs(host: host, username: username))
        }
        authoredMergeRequests.authorFeedbackStatus = { [weak self] request in
            self?.attention.authorFeedbackCoordinator?.status(projectID: request.projectID, iid: request.iid)
        }
        attention.onAuthorFeedbackNeedsWork = { [weak self] request, notes, fingerprint, residual in
            await self?.runVerifiedAuthorFeedback(request: request, noteIDs: notes, fingerprint: fingerprint,
                residual: residual, manual: false)
        }
        attention.onAuthorFeedbackChecked = { [weak self] in
            guard let self, let host = self.glab.resolvedHost, let username = self.glab.currentUsername else { return }
            Task { await self.mrTodoRouter.refreshCompletionEvidence(host: host, username: username) }
        }
        attention.onScopedAuthorFeedbackChecked = { [weak self] target, revision in
            Task { await self?.mrTodoRouter.refreshCompletionEvidence(for: target, accountRevision: revision) }
        }
        assistantDependencies.onReady = { [weak self] assistant in
            guard let self, self.settings.automation.selectedAssistant == assistant else { return }
            self.authoredMergeRequests.workflow.startNext()
            self.wakeAutomaticRetries()
        }
        assistantDependencies.onRecovered = { [weak self] assistant in
            self?.retryReadOnlyAssistantFailures(assistant)
        }

        // Hydrate the service from any previously persisted state so the
        // glab wrapper survives a cold launch without needing onboarding.
        self.glab.glabPath = settings.glabPath
        self.glab.resolvedHost = settings.resolvedHost
        AssistantAutomationRunner.synchronizeInterruptedRuns(settings: settings)
        AssistantAutomationRunner.onJobFinished = { [weak self] handoff in
            if let reservation = handoff.pipelineReservation, reservation.reservationID != nil {
                try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
            }
            guard let self else { return }
            FollowUpVerificationStore.synchronizeRuns(settings: self.settings)
            self.authoredMergeRequests.workflow.synchronizeAssistantJobs()
            self.wakeAutomaticRetries()
            Task {
                await self.refreshNow()
                if handoff.operationalExecution?.state == .succeeded {
                    let work = handoff.key.work
                    self.enqueueIssueMetadataRefresh(projectID: work.projectID, iid: work.iid,
                        host: work.host, username: handoff.key.username)
                }
            }
        }

        settings.onAutomationChanged = { [weak self] previous in
            self?.automationConfigurationChanged(previous: previous)
        }
        observeUserAttentionChanges()
        observeMRActivityChanges()
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    private func observeUserAttentionChanges() {
        let (input, fresh) = withObservationTracking {
            let input = pendingUserAttention
            _ = settings.notificationsEnabled
            _ = glab.resolvedHost
            _ = glab.currentUsername
            _ = glab.accountRevision
            _ = settings.reviewParticipationPreferences
            _ = settings.boardOrderingMethod
            _ = settings.promoteBoardAttention
            return (input, freshUserAttention)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeUserAttentionChanges()
                self?.scheduleUserAttentionNotifications()
            }
        }
        synchronizeLocalAutomationAuthors()
        boardAttentionPresenter.updateAttention(input)
        if settings.boardOrderingMethod == .automatic {
            boardPolicyOrder.observe(boardOrderingEntries(boardSnapshot))
            boardSnapshotCache.invalidate()
        } else if fresh {
            var order = settings.boardManualOrder
            order.observe(boardSnapshot.manualOrderEntries, promotesAttention: settings.promoteBoardAttention)
            settings.saveBoardManualOrder(order)
        }
    }

    private func observeMRActivityChanges() {
        let activities = withObservationTracking {
            let board = boardSnapshot
            var activities: [MRAutomationScope.Target: MRActivity] = [:]
            for row in board.own + board.reviewed + board.otherMergeRequests {
                guard let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url),
                      let activity = MRCardPresentation(row: row, monitor: self,
                          allowsRemoval: board.reviewed.contains { $0.id == row.id }).activity else { continue }
                activities[target] = activity
            }
            return activities
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMRActivityChanges() }
        }
        boardAttentionPresenter.updateActivities(activities)
    }

    func activityStartedAt(for item: MergeRequestAttentionMonitor.Item, activity: MRActivity?) -> Date? {
        guard let activity else { return nil }
        return boardAttentionPresenter.activityStartedAt(
            target: scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url), activity: activity)
    }

    private var userAttentionAccount: String? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return host + "/" + username
    }

    private var freshUserAttention: Bool {
        hasCompletedFirstFetch && inboxHost == glab.resolvedHost && inboxUsername == glab.currentUsername
            && lastError == nil && !isLoading && !assistantDependencies.isChecking && !attention.isLoading && !attention.hasError
            && attention.hasCurrentOwnListing && !authoredMergeRequests.isLoading && !authoredMergeRequests.hasError
    }

    private func scheduleUserAttentionNotifications() {
        attentionNotificationScheduler.schedule { [weak self] in
            guard let self else { return nil }
            return .init(account: userAttentionAccount, snapshot: userAttention,
                fresh: freshUserAttention, enabled: settings.notificationsEnabled)
        }
    }

    /// Refreshes CLI availability and sign-in without depending on desktop chats.
    func refreshAvailableAssistants() {
        assistantDependencies.refresh(force: true)
    }

    func assistantCLIHealthDidRecover(_ assistant: AutomationAssistant) {
        AssistantAutomationRunner.resumePendingJobs()
        guard settings.automation.selectedAssistant == assistant else { return }
        retryReadOnlyAssistantFailures(assistant)
        wakeAutomaticRetries()
        Task { await refreshNow() }
    }

    private func retryReadOnlyAssistantFailures(_ assistant: AutomationAssistant) {
        guard settings.automation.selectedAssistant == assistant else { return }
        attention.authorFeedbackCoordinator?.retryReadOnlyFailures()
        attention.aiOriginCoordinator.retryReadOnlyFailures()
        authoredMergeRequests.workflow.retryReadOnlyFailures()
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            attention.draftProofRecoveryCoordinator?.retryReadOnlyFailures(host: host, username: username)
        }
        if settings.automation.autoVerifyReReview {
            Task { await attention.retryFailedReReviews() }
        }
    }

    func refreshRuntimeAssistantAvailability(force: Bool = false) {
        // Explicit retries still use the historical job's provider after the selection changes.
        var assistants = Set(settings.assistantHandoffs.lazy
            .filter { $0.operationalExecution.map { $0.state != .succeeded } == true }
            .map(\.key.assistant))
        if let assistant = settings.automation.selectedAssistant { assistants.insert(assistant) }
        assistantDependencies.refresh(assistants, force: force)
    }

    var boardRefreshState: BoardRefreshState {
        settings.onboardingCompleted ? inboxRefreshState : .current
    }

    var inboxRefreshState: BoardRefreshState {
        let catalogsEnabled = settings.onboardingCompleted
        let todosReady = hasCompletedFirstFetch && glab.currentUsername != nil
            && inboxHost == glab.resolvedHost && inboxUsername == glab.currentUsername
            && inboxAccountRevision == glab.accountRevision
        let accountUnavailable = glab.currentUsername == nil && glab.authStatus != .unknown
        return .init(todosReady: todosReady, catalogReady: !catalogsEnabled || attention.hasSyncedCurrentCatalog,
                     authoredReady: !catalogsEnabled || authoredMergeRequests.hasSyncedCurrentCatalog,
                     isRefreshing: isLoading || (catalogsEnabled && (attention.isLoading || authoredMergeRequests.isLoading)),
                     hasError: lastError != nil || accountUnavailable
                         || (catalogsEnabled && (attention.hasError || authoredMergeRequests.hasError)))
    }

    func bootstrap() async {
        refreshRuntimeAssistantAvailability()
        if glab.glabPath == nil {
            glab.glabPath = await OnboardingDetector.findGlabExecutable()
            settings.glabPath = glab.glabPath
        }
        await glab.recheck()
        guard !Task.isCancelled else { return }
        settings.glabPath = glab.glabPath
        settings.resolvedHost = glab.resolvedHost
        settings.save()

        if settings.onboardingCompleted, timer == nil {
            if lastRefresh == nil {
                start()
            } else {
                restartTimer()
                authoredMergeRequests.refreshIfNeeded()
            }
        }
    }

    // MARK: - Derived state

    var visibleTodos: [Todo] {
        guard let host = todoStore.host, let username = todoStore.username else {
            return todoStore.hasCompletedFirstFetch ? todoStore.visibleTodos : currentAccountTodos
        }
        return todoStore.visibleTodos.filter { !isSuppressedByIncomingReviewFilter($0, host: host, username: username) }
    }

    /// The last live inbox remains authoritative. On a cold launch, recover only
    /// the undecided review requests durably held before the interruption.
    var currentAccountTodos: [Todo] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        let todos = if todoStore.host == host, todoStore.username == username, todoStore.accountRevision == glab.accountRevision {
            todoStore.currentAccountTodos
        } else {
            settings.reviewAssignments.incomingReviewFilter.recoveredTodos(host: host, username: username)
        }
        return todos.filter { !isSuppressedByIncomingReviewFilter($0, host: host, username: username) }
    }

    var pipelineHandoffs: [MergeWorkflowActivityEntry] {
        authoredMergeRequests.workflow.pendingPipelineHandoffs
    }

    /// Capture existing owners and policy decisions as values; the projector cannot call back into them.
    var boardProjector: MRBoardProjector? {
        withBoardPresentationRead { live in
            live ? makeBoardProjector() : boardProjectorCache.value { makeBoardProjector() }
        }
    }

    func withBoardPresentationRead<Result>(_ read: (Bool) -> Result) -> Result {
        if let liveBoardPresentationRead { return read(liveBoardPresentationRead) }
        let live = authoredMergeRequests.workflow.needsLivePipelinePresentation
        liveBoardPresentationRead = live
        defer { liveBoardPresentationRead = nil }
        return read(live)
    }

    private func makeBoardProjector() -> MRBoardProjector? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        let snapshot = attention.presentationSnapshot
        var input = MRBoardProjector.Input(account: .init(host: host, username: username, revision: glab.accountRevision))
        input.attention = snapshot
        input.reviewAssignments = settings.reviewAssignments.entries(host: host, username: username)?.filter { entry in
            settings.addNewReviewsToReviewed
                || trackedReviewTarget(.mergeRequest(host: host, username: username, projectID: entry.request.projectID, iid: entry.request.iid))
        }
        input.authored = authoredMergeRequests.requests
        input.retainedRequests = settings.mrLifecycleLedger.retainedRequests(host: host, username: username)
        input.ownCatalogIsAuthoritative = attention.hasCurrentOwnListing
        let targets = settings.mrLifecycleLedger.targets(host: host, username: username)
        for target in targets {
            if let iid = target.iid, let id = settings.mrLifecycleLedger.completionID(for: target) {
                input.completionIDs[.init(projectID: target.projectID, iid: iid)] = id
            }
        }
        let items = (snapshot?.evidence ?? []) + (snapshot?.catalog ?? [])
        let requests = items.compactMap(\.mergeRequest) + input.authored.map(\.request) + input.retainedRequests
        let workflowEntries = authoredMergeRequests.workflow.entries
        var requestFacts = MRBoardProjector.RequestFacts.Index()
        for request in requests {
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
            if trackedReviewTarget(target) { input.trackedReviewedTargets.insert(target) }
            let publication = settings.publicationPolicy(for: target)
            if publication.mode != .manual { input.publicationPolicies[target] = publication }
            requestFacts.insert(request) {
                let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
                input.feedbackDecisionRevisions[.init(projectID: request.projectID, iid: request.iid)] =
                    AssistantAutomationRunner.feedbackDecisionRevision(work: work, username: username, settings: settings)
                return .init(request: request,
                    mergeAutomatic: settings.permitsAutomaticAction(.merge, for: request, target: target, ignoringGlobalSuspension: true),
                    conflictFailed: authoredMergeRequests.conflictTaskFailed(for: request)
                        || (request.hasMergeConflict && authoredMergeRequests.conflictAutomationState(for: request) == nil),
                    conflictProcessing: automaticConflictIsProcessing(for: request),
                    pipelineProcessing: authoredMergeRequests.workflow.isAutomaticallyProcessingPipeline(request, entries: workflowEntries),
                    workflowReadFailed: authoredMergeRequests.workflow.hasReadOnlyFailure(for: request),
                    aiOriginReadFailed: attention.aiOriginCoordinator.failure(work: work) != nil)
            }
        }
        input.requestFacts = requestFacts.values
        for item in snapshot?.attention ?? [] {
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
            input.remainingFeedbackIDs[item.id] = Set(AssistantAutomationRunner.unhandledFeedback(
                item.feedback.compactMap(\.id), work: work, username: username, settings: settings))
        }
        input.feedbackLaunchFailures = feedbackLaunches.failures
        input.workflowEntries = workflowEntries
        input.pipelineHandoffs = pipelineHandoffs
        input.handoffs = assistantHandoffs
        input.confirmationStates = attention.confirmationStates
        input.automation = settings.configuredAutomation
        input.assistantReady = selectedAssistantReady
        input.reviewAssistantReady = settings.automation.selectedAssistant.map(assistantDependencies.available.contains) == true
        input.assistantChecking = checkingSelectedAssistant
        input.ignoredTargets = settings.ignoredMergeRequests
        input.hiddenTargets = hiddenBoardTargets
        input.mrCatalogReadFailed = attention.hasError || authoredMergeRequests.hasError
        input.catalogReadFailed = lastError != nil || input.mrCatalogReadFailed
        input.catalogLoading = isLoading || attention.isLoading || authoredMergeRequests.isLoading
        input.inboxLoading = isLoading
        input.assessingMentionNoteIDs = assessingMentionNoteIDs
        input.todos = currentAccountTodos
        input.intents = currentMRTodoIntents
        input.routedTodoIDs = routedMRTodoIDs
        input.pipelineEvidence = currentPipelineEvidence
        input.pipelineEvidenceCheckedAt = currentPipelineEvidenceDate
        input.displayRequests = boardDisplayRequests
        input.pins = settings.boardPins
        input.grouping = settings.boardGrouping
        input.draftsLast = settings.effectiveBoardGrouping == .drafts
        input.completions = lifecycleCompletions
        input.hiddenReviewNotifications = hiddenReviewNotifications
        return .init(input: input)
    }

    var currentMRTodoIntents: [MRTodoIntent] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.mrActionIntents.filter { $0.target.host == host && $0.target.username == username }
    }

    var routedMRTodoIDs: Set<Int> {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return Set(allTodos.filter { todo in
            guard let iid = todo.target.iid, todo.targetType == .mergeRequest,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { return false }
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: todo.project.id, iid: iid)
            return settings.routedMRTodoReceipts.contains { $0.target == target && $0.event == todo.feedbackIdentity }
                || currentMRTodoIntents.contains { $0.target == target && $0.sourceEvents.contains(todo.feedbackIdentity) }
        }.map(\.id))
    }

    var otherTodos: [Todo] { visibleTodos.filter { !routedMRTodoIDs.contains($0.id) } }

    func mrTodoIntents(for item: MergeRequestAttentionMonitor.Item) -> [MRTodoIntent] {
        currentMRTodoIntents.filter { $0.target.projectID == item.id.projectID && $0.target.iid == item.id.iid && $0.state != .completed }
    }

    func runMRTodoIntent(id: UUID, confirmedReview: ManualReviewConsent? = nil) async {
        guard let intent = currentMRTodoIntents.first(where: { $0.id == id }),
              intent.kind != .review || confirmedReview == manualReviewConsent(for: reviewRequest(for: intent)) else { return }
        await mrTodoRouter.run(id, manual: true) { request in
            confirmedReview == self.manualReviewConsent(for: request)
        }
    }

    func adoptMRTodoProposal(_ todo: Todo, confirmReview: (MRTodoIntent) -> ManualReviewConsent? = { _ in nil }) async {
        guard let iid = todo.target.iid, let host = glab.resolvedHost,
              let canonical = todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid),
              let target = scopeTarget(projectID: todo.project.id, iid: iid, url: canonical) else { return }
        // Register before exposing the active scope to an already-running background pass.
        manualAdoptions[target, default: 0] += 1
        defer {
            let remaining = manualAdoptions[target, default: 1] - 1
            if remaining == 0 { manualAdoptions.removeValue(forKey: target) }
            else { manualAdoptions[target] = remaining }
        }
        incomingReviewFilter.releaseForManualAdd(target)
        settings.ignoredMergeRequests.remove(target)
        settings.mrLifecycleLedger.restore(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(todo.project.pathWithNamespace, for: target)
        settings.save()
        await routeMRTodos(host: target.host, username: target.username, manuallyAdopting: target)
        guard !Task.isCancelled else { return }
        for intent in currentMRTodoIntents where intent.target == target && intent.state != .completed {
            if intent.kind == .review {
                guard let consent = confirmReview(intent) else { continue }
                await runMRTodoIntent(id: intent.id, confirmedReview: consent)
            } else {
                await runMRTodoIntent(id: intent.id)
            }
        }
        await refreshNow()
    }

    // MARK: New review candidates

    /// Whether a review candidate that has just arrived in Reviewing starts its own review.
    var startsNewReviewsAutomatically: Bool {
        settings.automation.packageDecision == .enabled && settings.automation.startNewReviewsAutomatically
    }

    /// Tracks a review candidate in Reviewing without starting any work. Unless the profile starts
    /// new reviews itself, the MR's automation stays paused until the user starts it.
    /// `receipts` are the candidate's review to-dos; they stop appearing in the inbox once held.
    func trackReviewCandidate(_ target: MRAutomationScope.Target, projectPath: String, markNew: Bool,
                              receipts: [Todo] = []) {
        settings.automation.scope.adoptAutomatically(target)
        settings.automation.scope.rememberRepository(projectPath, for: target)
        if markNew { settings.newReviewTargets.insert(target) }
        if !startsNewReviewsAutomatically, settings.automation.scope[target] == .inherit {
            settings.automation.scope[target] = .paused
            settings.heldNewReviewTargets.insert(target)
            for todo in receipts {
                settings.routedMRTodoReceipts.insert(.init(target: target, event: todo.feedbackIdentity, intentID: nil))
            }
        }
        settings.save()
    }

    /// Whether the review request for `projectPath` would be taken over by automation as soon as it is added.
    func automationHandlesNewReview(projectPath: String) -> Bool {
        let rule = settings.automation.reviewRequested
        return startsNewReviewsAutomatically && rule.isEnabled && rule.runner == .assistant
            && rule.isConfigured && rule.includes(project: projectPath)
    }

    /// The user acted on the card: the NEW mark ends and a held review may run automation again.
    func acknowledgeNewReview(_ target: MRAutomationScope.Target) {
        guard settings.newReviewTargets.contains(target) || settings.heldNewReviewTargets.contains(target) else { return }
        settings.newReviewTargets.remove(target)
        settings.save()
    }

    /// Starting the review is the user's explicit go-ahead for a held MR.
    func releaseNewReview(_ target: MRAutomationScope.Target) {
        acknowledgeNewReview(target)
        guard settings.heldNewReviewTargets.remove(target) != nil else { return }
        if settings.automation.scope[target] == .paused { settings.automation.scope[target] = .inherit }
        settings.save()
    }

    /// Moves an inbox review candidate to Reviewing ("Add"). It never starts work by itself.
    func addReviewCandidate(_ proposal: MergeRequestBoardSnapshot.Proposal) async {
        let target = proposal.target
        guard target.iid != nil else { return }
        incomingReviewFilter.releaseForManualAdd(target)
        settings.ignoredMergeRequests.remove(target)
        settings.mrLifecycleLedger.restore(target)
        trackReviewCandidate(target, projectPath: proposal.url.gitLabProjectPath, markNew: false,
                             receipts: proposal.todos)
        await refreshNow()
    }

    /// Review requests go straight to Reviewing when the user chose so. This is independent of
    /// automation consent; whether work starts is decided by `startsNewReviewsAutomatically`.
    private func addNewReviewCandidates(host: String, username: String) async {
        guard settings.addNewReviewsToReviewed, settings.automaticActionsAllowed,
              settings.automation.reviewRequested.runner == .assistant else { return }
        let revision = glab.accountRevision
        var requests: [MRAutomationScope.Target: GitLabMergeRequest] = [:]
        var added = false
        for todo in currentAccountTodos where MRTodoIntent.kind(for: todo, username: username) == .review {
            guard let iid = todo.target.iid, todo.targetType == .mergeRequest,
                  todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { continue }
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: todo.project.id, iid: iid)
            let paused = settings.automation.scope[target] == .paused
                || (settings.automation.scope[target] == .inherit && settings.automation.scope[target.repository] == .paused)
            guard !settings.ignoredMergeRequests.contains(target), !paused, !trackedReviewTarget(target),
                  !settings.routedMRTodoReceipts.contains(where: { $0.target == target && $0.event == todo.feedbackIdentity })
            else { continue }
            let request: GitLabMergeRequest
            if let cached = requests[target] { request = cached }
            else {
                guard let fetched = try? await glab.fetchMergeRequest(projectID: target.projectID, iid: iid, host: host) else { continue }
                requests[target] = fetched
                request = fetched
            }
            guard !Task.isCancelled, glab.resolvedHost == host, glab.currentUsername == username,
                  glab.accountRevision == revision, settings.addNewReviewsToReviewed,
                  settings.automation.reviewRequested.runner == .assistant,
                  request.projectID == target.projectID, request.iid == iid, request.isOpen,
                  request.author.username != username, request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  !settings.ignoredMergeRequests.contains(target), !settings.intakeFilterHolds(target) else { continue }
            let siblings = currentAccountTodos.filter {
                MRTodoIntent.kind(for: $0, username: username) == .review && $0.project.id == target.projectID && $0.target.iid == iid
            }
            trackReviewCandidate(target, projectPath: request.webURL.gitLabProjectPath, markNew: true, receipts: siblings)
            added = true
        }
        if added { attention.refresh(host: host, username: username, todos: visibleTodos) }
    }

    private func trackedReviewTarget(_ target: MRAutomationScope.Target) -> Bool {
        settings.automation.scope.isManaged(target) || settings.mrLifecycleLedger.request(for: target) != nil
            || settings.mrActionIntents.contains { $0.target == target && $0.grantsManagement }
            || settings.assistantHandoffs.contains {
                $0.key.work.host == target.host && $0.key.username == target.username
                    && $0.key.work.projectID == target.projectID && $0.key.work.iid == target.iid
            }
    }

    private func existingReviewTargets(host: String, username: String) -> Set<MRAutomationScope.Target> {
        guard incomingReviewFilter.isEnabled else { return [] }
        let scope = settings.automation.scope
        var targets = settings.mrLifecycleLedger.targets(host: host, username: username)
        targets.formUnion(scope.individualTargets(host: host, username: username).filter(scope.isManaged))
        targets.formUnion(settings.mrActionIntents.lazy.filter(\.grantsManagement).map(\.target))
        targets.formUnion(settings.pendingCommentReviews)
        targets.formUnion(settings.ignoredMergeRequests)
        targets.formUnion(settings.assistantHandoffs.map { job in
            job.key.automationTarget
        })
        return targets
    }

    private func isSuppressedByIncomingReviewFilter(_ todo: Todo, host: String, username: String) -> Bool {
        guard let target = IncomingReviewFilterLedger.target(for: todo, host: host, username: username) else { return false }
        return settings.intakeFilterHolds(target)
    }

    private func resumeIncomingReviews() {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        if settings.onboardingCompleted {
            attention.refresh(host: host, username: username, todos: currentAccountTodos)
        }
        authoredMergeRequests.workflow.startNext()
        let revision = glab.accountRevision
        Task {
            guard glab.accountRevision == revision else { return }
            await routeMRTodos(host: host, username: username)
        }
    }

    private func routeMRTodos(host: String, username: String, manuallyAdopting target: MRAutomationScope.Target? = nil) async {
        let automatically = target == nil
        if automatically { await addNewReviewCandidates(host: host, username: username) }
        guard !automatically || settings.automaticWritesAllowed else { return }
        let revision = glab.accountRevision
        let todos: [Todo]
        if let target {
            guard let iid = target.iid, target.host == host, target.username == username else { return }
            todos = currentAccountTodos.filter { todo in
                todo.targetType == .mergeRequest && todo.project.id == target.projectID && todo.target.iid == iid
                    && todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil
            }
        } else {
            todos = allTodos.filter { !isSuppressedByIncomingReviewFilter($0, host: host, username: username) }
        }
        let catalog = boardProjector?.browser.reviewed ?? []
        let managed = Set(catalog.compactMap { item -> MRAutomationScope.Target? in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
                  trackedReviewTarget(target), !settings.ignoredMergeRequests.contains(target) else { return nil }
            return target
        })
        let acknowledged = await mrTodoRouter.process(todos, host: host, username: username, managed: managed, automatically: automatically)
        guard glab.resolvedHost == host, glab.currentUsername == username,
              glab.accountRevision == revision else { return }
        // Apply confirmed GitLab acknowledgements even if a later step degraded persistence.
        todoStore.acknowledge(acknowledged)
        if let error = mrTodoRouter.acknowledgementError { assistantJobActionError = error.localizedDescription }
        if automatically, settings.automaticWritesAllowed {
            await environmentRecovery.recover(host: host, username: username)
        }
    }

    func reviewingContext(for row: MergeRequestBoardSnapshot.Row) -> ReviewingContext {
        MRBoardProjector.reviewingContext(for: row, input: boardRowInput(for: row))
    }

    var ownMergeRequestItems: [MergeRequestAttentionMonitor.Item] { boardProjector?.ownItems ?? [] }
    var reviewedMergeRequestItems: [MergeRequestAttentionMonitor.Item] { boardProjector?.reviewedItems ?? [] }

    var inbox: InboxSnapshot {
        InboxSnapshot(todos: currentAccountTodos, attention: attentionItems, host: glab.resolvedHost, username: glab.currentUsername)
    }

    func confirmPipelineHandoff(for id: MergeRequestAttentionMonitor.Item.ID) {
        guard let entry = pipelineHandoffs.first(where: { $0.event.mergeRequest.projectID == id.projectID
            && $0.event.mergeRequest.iid == id.iid }) else { return }
        authoredMergeRequests.workflow.confirmPipelineHandoff(entry.id)
    }

    func recordBoardDisplayRequest(_ request: GitLabMergeRequest, for target: MRAutomationScope.Target,
                                   url: URL, accountRevision: UInt64, readStartedAt: Date) {
        guard let current = boardDisplayAccount else { return }
        let original = MRDisplayMetadataCache.Account(host: target.host, username: target.username, revision: accountRevision)
        var metadata = boardDisplayMetadata
        guard metadata.record(request, for: target, url: url, readStartedAt: readStartedAt,
                              account: original, currentAccount: current) else { return }
        boardDisplayMetadata = metadata
        mergeRequestIssues?.observe(request, target: target, revision: accountRevision, at: readStartedAt)
    }

    private var boardDisplayAccount: MRDisplayMetadataCache.Account? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return .init(host: host, username: username, revision: glab.accountRevision)
    }

    func boardDisplayRequest(for target: MRAutomationScope.Target, url: URL) -> GitLabMergeRequest? {
        guard let account = boardDisplayAccount, target.host == account.host, target.username == account.username,
              let iid = target.iid, iid > 0, target.projectID > 0,
              url.isGitLabMergeRequest(host: account.host, iid: iid) else { return nil }
        if let managed = settings.mrLifecycleLedger.request(for: target), managed.webURL == url { return managed }
        return boardDisplayMetadata.request(for: target, url: url, account: account)
    }

    var boardDisplayRequests: [GitLabMergeRequest] {
        guard let account = boardDisplayAccount else { return [] }
        let managed = settings.mrLifecycleLedger.targets(host: account.host, username: account.username)
        let records = managed.compactMap { settings.mrLifecycleLedger.request(for: $0) }
        return records + boardDisplayMetadata.requests(account: account).filter { request in
            !managed.contains(.mergeRequest(host: account.host, username: account.username, projectID: request.projectID, iid: request.iid))
        }
    }

    func boardActivity(projectID: Int, iid: Int, url: URL, isDraft: Bool, isFinished: Bool = false) -> MRBoardActivity {
        .init(automation: settings.configuredAutomation, target: scopeTarget(projectID: projectID, iid: iid, url: url),
              isDraft: isDraft, isFinished: isFinished, grouping: settings.boardGrouping)
    }

    func boardActivityGroup(for row: MergeRequestBoardSnapshot.Row) -> MRBoardActivity.Group {
        if let entry = row.manualOrderEntry { return entry.group.automationEnabled || entry.isNew ? .regular : .inactive }
        return boardActivity(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url,
            isDraft: row.item.section == .draftMergeRequests,
            isFinished: MergeRequestFinishedState(row.item.mergeRequest) != nil).group
    }

    func isNewReviewAssignment(_ row: MergeRequestBoardSnapshot.Row) -> Bool {
        row.newReviewAssignedAt != nil
            || scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: row.item.url)
                .map(settings.newReviewTargets.contains) == true
    }

    func scopeTarget(projectID: Int, iid: Int, url: URL) -> MRAutomationScope.Target? {
        guard projectID > 0, iid > 0, let host = glab.resolvedHost, let username = glab.currentUsername,
              url.isGitLabMergeRequest(host: host, iid: iid) else { return nil }
        return .mergeRequest(host: host, username: username, projectID: projectID, iid: iid)
    }

    func addAutomationTarget(from address: String) async throws {
        let result = try await resolveAutomationTarget(from: address)
        enableAutomationTarget(result.target, projectPath: result.projectPath)
        await refreshNow()
    }

    struct ReviewRemoval: Identifiable {
        let id = UUID()
        var reviews: [HiddenReview]
        let automatic: Bool
        let accountRevision: UInt64
    }

    private var reviewRemoval: ReviewRemoval?
    private var automaticReviewRemoval: ReviewRemoval?
    var undoableReviewRemovals: [ReviewRemoval] {
        let now = hiddenReviewDisplayTime
        return [reviewRemoval, automaticReviewRemoval].compactMap { removal in
            guard var removal, removal.accountRevision == glab.accountRevision else { return nil }
            removal.reviews = removal.reviews.filter { isCurrentRestorableHide($0, now: now) }
            return removal.reviews.isEmpty ? nil : removal
        }
    }

    func dismissReviewRemoval(_ id: UUID) {
        if reviewRemoval?.id == id { reviewRemoval = nil }
        if automaticReviewRemoval?.id == id { automaticReviewRemoval = nil }
    }

    private func announceHiddenReviews(_ reviews: [HiddenReview], automatic: Bool) {
        let revision = glab.accountRevision
        let currentHides = reviews.compactMap { settings.hiddenReviewDetails[$0.target] }
        guard !currentHides.isEmpty else { return }
        if automatic {
            let previous = automaticReviewRemoval.flatMap { $0.accountRevision == revision ? $0.reviews : nil } ?? []
            let newTargets = Set(currentHides.map(\.target))
            automaticReviewRemoval = .init(reviews: previous.filter { !newTargets.contains($0.target) } + currentHides,
                automatic: true, accountRevision: revision)
        } else {
            reviewRemoval = .init(reviews: currentHides, automatic: false, accountRevision: revision)
        }
    }

    func undoReviewRemoval(_ removal: ReviewRemoval) {
        guard let current = undoableReviewRemovals.first(where: { $0.id == removal.id }) else { return }
        if restoreReviewedMergeRequests(current.reviews) { dismissReviewRemoval(removal.id) }
    }

    @discardableResult
    func markReviewAssignmentSeen(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
        return !clearNewReviewAssignment(target) || settings.save()
    }

    @discardableResult
    private func clearNewReviewAssignment(_ target: MRAutomationScope.Target) -> Bool {
        let assignmentSeen = settings.reviewAssignments.markSeen(target)
        let candidateSeen = settings.newReviewTargets.remove(target) != nil
        return assignmentSeen || candidateSeen
    }

    private var hiddenReviewDisplayTime: Date {
        // A refresh invalidates time-based projections even if GitLab has no new data.
        _ = isLoading
        return .now
    }

    private func isCurrentRestorableHide(_ review: HiddenReview, now: Date) -> Bool {
        settings.canRestoreHiddenReview(review.target, now: now)
            && settings.hiddenReviewDetails[review.target]?.hideID == review.hideID
    }

    var hiddenReviewNotifications: [HiddenReview] {
        guard let account = boardDisplayAccount else { return [] }
        let now = hiddenReviewDisplayTime
        return settings.filteredHiddenReviewDetails.values.filter {
            $0.target.host == account.host && $0.target.username == account.username && $0.inboxNotification != nil
                && settings.canRestoreHiddenReview($0.target, now: now)
        }.sorted { ($0.target.projectID, $0.target.iid ?? 0) < ($1.target.projectID, $1.target.iid ?? 0) }
    }

    @discardableResult
    func acknowledgeHiddenReviewNotifications(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, let host = glab.resolvedHost, let username = glab.currentUsername else { return false }
        return settings.acknowledgeHiddenReviewNotifications(ids, host: host, username: username)
    }

    @discardableResult
    func restoreHiddenReviewNotification(id: UUID) -> Bool {
        guard let review = hiddenReviewNotifications.first(where: { $0.inboxNotification?.id == id }) else { return false }
        return restoreReviewedMergeRequests([review])
    }

    var hiddenReviewAssignments: [HiddenReview] {
        guard let account = boardDisplayAccount else { return [] }
        let now = hiddenReviewDisplayTime
        var hidden = settings.hiddenReviewDetails.filter {
            $0.key.host == account.host && $0.key.username == account.username
                && settings.canRestoreHiddenReview($0.key, now: now)
        }
        let assigned = settings.reviewAssignments.entries(host: account.host, username: account.username)?.map(\.request) ?? []
        let retained = settings.ignoredMergeRequests.compactMap { target -> GitLabMergeRequest? in
            guard target.host == account.host, target.username == account.username, hidden[target] == nil else { return nil }
            return settings.mrLifecycleLedger.request(for: target)
        }
        for request in assigned + retained where request.isOpen && request.author.username != account.username {
            guard let target = scopeTarget(projectID: request.projectID, iid: request.iid, url: request.webURL),
                  hidden[target] == nil, settings.canRestoreHiddenReview(target, now: now) else { continue }
            hidden[target] = .init(target: target, title: request.title, url: request.webURL)
        }
        return hidden.values.sorted {
            ($0.url.gitLabProjectPath, $0.target.iid ?? 0) < ($1.url.gitLabProjectPath, $1.target.iid ?? 0)
        }
    }

    @discardableResult
    func restoreReviewedMergeRequests(_ reviews: [HiddenReview]) -> Bool {
        let now = Date()
        let targets = Set(reviews.compactMap { review -> MRAutomationScope.Target? in
            guard let iid = review.target.iid,
                  scopeTarget(projectID: review.target.projectID, iid: iid, url: review.url) == review.target,
                  isCurrentRestorableHide(review, now: now) else { return nil }
            return review.target
        })
        guard settings.restoreHiddenReviews(targets, now: now) else { return false }
        for target in targets { clearNewReviewAssignment(target) }
        settings.save()
        resumeIncomingReviews()
        return true
    }

    /// Both board removal and the inline Hide action use the same account-specific exclusion.
    @discardableResult
    func removeReviewedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              let request = item.mergeRequest, request.author.username != target.username,
              request.projectID == target.projectID, request.iid == target.iid, request.webURL == item.url else { return false }
        guard !settings.ignoredMergeRequests.contains(target) else { return true }
        let review = HiddenReview(target: target, title: request.title, url: request.webURL)
        guard settings.hideReviewedMergeRequest(review) else { return false }
        if clearNewReviewAssignment(target) { settings.save() }
        announceHiddenReviews([review], automatic: false)
        return true
    }

    func ignoreMergeRequestProposal(projectID: Int, iid: Int, url: URL) async {
        guard projectID > 0, iid > 0, let target = scopeTarget(projectID: projectID, iid: iid, url: url) else { return }
        let accountRevision = glab.accountRevision
        let review: HiddenReview
        do {
            async let user = glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
            async let request = glab.fetchMergeRequest(projectID: projectID, iid: iid, host: target.host)
            let (currentUser, currentRequest) = try await (user, request)
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username,
                  currentRequest.projectID == projectID, currentRequest.iid == iid,
                  currentRequest.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
                  currentRequest.author.id != currentUser.id, glab.accountRevision == accountRevision else { return }
            review = .init(target: target, title: currentRequest.title, url: currentRequest.webURL)
        } catch {
            guard !(error is CancellationError), glab.accountRevision == accountRevision else { return }
            todoStore.reportActionFailure(error as? GlabError ?? .unknown(String(describing: error)))
            return
        }
        guard settings.hideReviewedMergeRequest(review) else { return }
        settings.automation.scope[target] = .paused
        settings.save()
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: projectID, iid: iid)
        for job in assistantHandoffs where job.key.work == work && job.execution?.state.isActive == true {
            AssistantAutomationRunner.cancel(job.id, settings: settings)
        }
        for todo in visibleTodos where todo.targetType == .mergeRequest && todo.project.id == projectID
            && todo.target.iid == iid && todo.targetURL.gitLabTodoMergeRequestURL(host: target.host, iid: iid) != nil {
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username,
                  glab.accountRevision == accountRevision else { return }
            await markDone(todo)
        }
    }

    func addManagedMergeRequest(from address: String, projectID: Int? = nil) async throws -> GitLabMergeRequest {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = raw.hasPrefix("!") ? String(raw.dropFirst()) : raw
        let target: MRAutomationScope.Target
        let request: GitLabMergeRequest
        if let iid = Int(number), iid > 0, let projectID,
           let host = glab.resolvedHost, let username = glab.currentUsername {
            let revision = glab.accountRevision
            request = try await glab.fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            guard request.projectID == projectID, request.iid == iid,
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  glab.resolvedHost == host, glab.currentUsername == username,
                  glab.accountRevision == revision else { throw CancellationError() }
            try Self.requireOpenMergeRequest(request)
            target = .mergeRequest(host: host, username: username, projectID: projectID, iid: iid)
        } else {
            let result = try await resolveAutomationTarget(from: raw)
            guard let resolved = result.request else { throw GlabError.decoding("Enter a merge request URL, or a number and repository") }
            request = resolved
            target = result.target
        }
        enableAutomationTarget(target, projectPath: request.webURL.gitLabProjectPath)
        await refreshNow()
        return request
    }

    private func enableAutomationTarget(_ target: MRAutomationScope.Target, projectPath: String) {
        incomingReviewFilter.releaseForManualAdd(target)
        settings.ignoredMergeRequests.remove(target)
        settings.mrLifecycleLedger.restore(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(projectPath, for: target)
        settings.save()
    }

    private func resolveAutomationTarget(from address: String) async throws -> (target: MRAutomationScope.Target, projectPath: String, request: GitLabMergeRequest?) {
        let wrongHost = GlabError.decoding("Use a URL on the current GitLab host")
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let expected = URLComponents(string: "https://\(host)"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, ["https", "http"].contains(scheme),
              parts.host?.lowercased() == expected.host?.lowercased(), parts.user == nil, parts.password == nil
        else { throw wrongHost }
        let defaultPort = scheme == "https" ? 443 : 80
        let expectedPort = expected.port ?? defaultPort
        let port = parts.port ?? defaultPort
        guard port == expectedPort else { throw wrongHost }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.components(separatedBy: "/-/merge_requests/")
        let projectPath = components[0]
        guard (components.count == 1 || components.count == 2), projectPath.contains("/"),
              !projectPath.contains("/-/"), !projectPath.hasSuffix(".git") else {
            throw GlabError.decoding("Enter a GitLab repository or merge request URL")
        }
        let revision = glab.accountRevision
        let projectID = try await glab.resolveAutomationProject(path: projectPath, host: host)
        var iid: Int? = nil
        var verified: GitLabMergeRequest?
        if components.count == 2 {
            guard let number = Int(components[1]), number > 0 else {
                throw GlabError.decoding("Invalid merge request URL")
            }
            let request = try await glab.fetchMergeRequest(projectID: projectID, iid: number, host: host)
            guard request.projectID == projectID, request.iid == number,
                  request.webURL.isGitLabMergeRequest(host: host, iid: number) else {
                throw GlabError.decoding("GitLab returned a different merge request")
            }
            iid = number
            verified = request
        }
        guard glab.resolvedHost == host, glab.currentUsername == username,
              glab.accountRevision == revision else { throw CancellationError() }
        if let verified { try Self.requireOpenMergeRequest(verified) }
        let target = iid.map { MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: projectID, iid: $0) }
            ?? .repository(host: host, username: username, projectID: projectID)
        return (target, projectPath, verified)
    }

    private static func requireOpenMergeRequest(_ request: GitLabMergeRequest) throws {
        if let finished = MergeRequestFinishedState(request) { throw finished }
        guard request.isOpen else { throw GlabError.decoding("The merge request is no longer open") }
    }

    var attentionItems: [MergeRequestAttentionMonitor.ItemPresentation] { boardProjector?.attentionItems ?? [] }

    var assistantHandoffs: [AssistantAutomationRunner.Handoff] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.assistantHandoffs.filter { $0.key.work.host == host && $0.key.username == username }
    }

    func automaticConflictIsProcessing(for request: GitLabMergeRequest) -> Bool {
        guard selectedAssistantReady || checkingSelectedAssistant,
              let state = authoredMergeRequests.conflictAutomationState(for: request) else { return false }
        return state == .available || state == .processing
    }

    /// Shared semantic projection for the menu indicator and native notifications.
    private var pendingUserAttention: ConfirmedAttentionSnapshot.Input {
        boardProjector?.pendingUserAttention ?? .init(account: nil)
    }

    var hasUnseenTodos: Bool {
        guard !currentAccountTodos.isEmpty else { return false }
        guard let lastOpened = settings.lastMenuOpenedAt else { return false }
        return currentAccountTodos.contains { $0.createdAt > lastOpened }
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refreshNow() }
        restartTimer()
    }

    func restartTimer() {
        automaticRetryRuntimeStarted = true
        wakeAutomaticRetries()
        timer?.invalidate()
        let interval = settings.refreshInterval.seconds
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }
        if wakeObserver == nil, ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .application {
            assistantLimitRecovery.start()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                object: NSWorkspace.shared, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshAfterSystemWake() }
            }
        }
    }

    func stopTimer() {
        stopAutomaticRetries()
        assistantLimitRecovery.stop()
        timer?.invalidate()
        timer = nil
        wakeRefreshPending = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func refreshAfterSystemWake() async {
        guard timer != nil else { return }
        wakeRefreshPending = true
        await refreshNow()
    }

    func setKeepMacAwakeDuringAgentTasks(_ enabled: Bool) {
        guard settings.keepMacAwakeDuringAgentTasks != enabled else { return }
        settings.keepMacAwakeDuringAgentTasks = enabled
        settings.save()
        AssistantPowerActivity.configure(enabled: enabled)
    }

    func markMenuOpened() {
        settings.lastMenuOpenedAt = Date()
        settings.save()
    }

    // MARK: - Commands

    /// A visible user request may join a background read. Its intent remains until the
    /// existing catalog children settle; it never changes their fetch or action policy.
    func refreshManually() async {
        markBoardIssueRefresh()
        await refreshProgress.perform(scope: .global, accountRevision: glab.accountRevision,
            currentAccountRevision: { self.glab.accountRevision },
            isRefreshing: { self.isLoading || self.attention.isLoading || self.authoredMergeRequests.isLoading },
            refresh: { await self.refreshNow() })
    }

    func refreshFromGitLab(for id: MergeRequestAttentionMonitor.Item.ID) async {
        issueDetailsRefreshes += 1
        defer { issueDetailsRefreshes -= 1 }
        let host = glab.resolvedHost, username = glab.currentUsername, revision = glab.accountRevision
        await refreshProgress.perform(scope: .mergeRequest(id), accountRevision: glab.accountRevision,
            currentAccountRevision: { self.glab.accountRevision },
            isRefreshing: { self.isLoading || self.attention.isLoading || self.authoredMergeRequests.isLoading },
            refresh: { await self.forceRefreshFromGitLab() })
        if let host, let username, revision == glab.accountRevision {
            enqueueIssueMetadataRefresh(projectID: id.projectID, iid: id.iid, host: host, username: username)
        }
    }

    func refreshFeedbackDecisions(for target: MRAutomationScope.Target, revision: UInt64) async {
        guard let iid = target.iid else { return }
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: target.projectID, iid: iid)
        await refreshProgress.perform(scope: .mergeRequest(id), accountRevision: revision,
            currentAccountRevision: { self.glab.accountRevision }, isRefreshing: { false },
            refresh: { await self.attention.refreshFeedbackDecision(id, target: target, revision: revision) })
    }

    func refreshNow() async {
        repeat {
            guard !Task.isCancelled, todoStore.beginRefresh() else { return }
            wakeRefreshPending = false
            await refreshInbox()
        } while wakeRefreshPending && timer != nil
    }

    private func refreshInbox() async {
        refreshAssistantRelay()
        defer {
            todoStore.finishRefresh()
            wakeAutomaticRetries()
            boardAttentionPresenter.updateAttention(pendingUserAttention)
            scheduleUserAttentionNotifications()
        }

        // A launch-time probe can fail while offline. Fetching to-dos alone
        // cannot restore the account required by the MR monitors.
        if glab.currentUsername == nil || lastError == .notAuthenticated {
            if await recheckIntegration() != nil { return }
        }
        guard !Task.isCancelled else { return }
        authoredMergeRequests.refreshIfNeeded()
        guard let fetched = await todoStore.fetch() else { return }
        let host = fetched.host
        let username = fetched.username
        switch fetched.result {
        case .success(let fetchedFiltered):
            let fetchedIDs = Set(fetchedFiltered.map(\.id))
            glab.resolveHostFromTodos(fetchedFiltered)
            settings.resolvedHost = glab.resolvedHost
            todoStore.bindAccount(host: host, username: username, revision: fetched.revision)

            if let failedAutomationTodoID, !fetchedIDs.contains(failedAutomationTodoID) {
                self.failedAutomationTodoID = nil
            }

            if let host, let username {
                automation.prune(fetchedIDs: fetchedIDs, host: host, username: username, settings: settings)
            }

            settings.lastSeenTodoIDs = fetchedIDs
            settings.save()

            if let host, let username {
                incomingReviewFilter.observeInbox(fetchedFiltered, host: host, username: username,
                    excluding: existingReviewTargets(host: host, username: username))
            }
            todoStore.accept(fetchedFiltered)
            if let host, let username {
                if settings.onboardingCompleted {
                    attention.refresh(host: host, username: username, todos: currentAccountTodos)
                }
                await routeMRTodos(host: host, username: username)
                await acknowledgeHandledTodos(host: host, username: username)
            }

        case .failure(let err):
            Log.monitor.error("Refresh failed: \(String(describing: err), privacy: .private)")
            lastError = err
            if settings.onboardingCompleted, let host, let username {
                attention.refresh(host: host, username: username, todos: currentAccountTodos)
            }
            // A transient read failure retains the last account-bound inbox.
        }
    }

    /// Reuse normal polling and its action fences. A forced read never resets proofs or retry receipts.
    func forceRefreshFromGitLab() async {
        let alreadyFetching = isLoading
        await refreshNow()
        if alreadyFetching || lastError != nil {
            authoredMergeRequests.refreshIfNeeded()
            if let host = glab.resolvedHost, let username = glab.currentUsername, settings.onboardingCompleted {
                attention.refresh(host: host, username: username, todos: currentAccountTodos)
            }
        }
    }

    var currentPipelineEvidence: [GitLabMergeRequest] {
        guard authoredMergeRequests.hasSyncedCurrentCatalog,
              let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return authoredMergeRequests.requests.map(\.request).filter {
            $0.author.username == username && $0.webURL.isGitLabMergeRequest(host: host, iid: $0.iid)
        }
    }

    var currentPipelineEvidenceDate: Date? {
        authoredMergeRequests.hasSyncedCurrentCatalog ? authoredMergeRequests.catalogReadStartedAt : nil
    }

    func currentRequest(for job: AssistantAutomationRunner.Handoff) -> GitLabMergeRequest? {
        guard glab.resolvedHost == job.key.work.host, glab.currentUsername == job.key.username else { return nil }
        let catalog = (attention.currentOpenItems + attention.currentItems).first {
            $0.id.projectID == job.key.work.projectID && $0.id.iid == job.key.work.iid
        }?.mergeRequest
        let details = currentPipelineEvidence.first { $0.projectID == job.key.work.projectID && $0.iid == job.key.work.iid }
        return PipelineJobReconciliation.matchingDetails(catalog ?? details, details: details,
            checkedAt: currentPipelineEvidenceDate, job: job) ?? catalog
    }

    func automationAction(for todo: Todo) -> TodoAutomationService.ActionState? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, inboxHost == host else { return nil }
        return automation.actionState(
            for: todo, host: host, username: username, settings: settings, available: availableAssistants
        )
    }

    func attentionFeedbackAction(for item: MergeRequestAttentionMonitor.Item) -> TodoAutomationService.ActionState? {
        feedbackLaunches.action(for: item)
    }

    func runAttentionFeedback(for item: MergeRequestAttentionMonitor.Item, manual: Bool = true) async {
        await feedbackLaunches.runAttentionFeedback(for: item, manual: manual)
    }

    func handleFeedbackManually(for item: MergeRequestAttentionMonitor.Item) async {
        if let status = item.verifiedFeedback.assessment, !status.followUpNoteIDs.isEmpty, let request = item.authoredRequest {
            await runVerifiedAuthorFeedback(request: request, noteIDs: status.followUpNoteIDs, fingerprint: status.fingerprint)
        } else {
            await runAttentionFeedback(for: item)
        }
    }

    func runVerifiedAuthorFeedback(request: GitLabMergeRequest, noteIDs: Set<Int>, fingerprint: String,
                                  residual: AuthorFeedbackResidual? = nil, manual: Bool = true) async {
        await feedbackLaunches.runVerifiedAuthorFeedback(request: request, noteIDs: noteIDs,
            fingerprint: fingerprint, residual: residual, manual: manual)
    }

    private func acknowledgeHandledTodos(host: String, username: String) async {
        guard settings.automaticWritesAllowed else { return }
        let revision = glab.accountRevision
        var handled = Set(assistantHandoffs.flatMap(\.deliveredFeedbackTodos))
        handled.formUnion(settings.pendingTodoAcknowledgements.lazy
            .filter { $0.host == host && $0.username == username }.map(\.todo))
        for todo in visibleTodos where handled.contains(todo.feedbackIdentity) {
            if todo.targetType == .mergeRequest,
               !settings.routedMRTodoReceipts.contains(where: { $0.target.host == host && $0.target.username == username && $0.event == todo.feedbackIdentity }),
               !settings.pendingTodoAcknowledgements.contains(where: { $0.host == host && $0.username == username && $0.todo == todo.feedbackIdentity }) { continue }
            guard settings.automaticWritesAllowed, glab.resolvedHost == host,
                  glab.currentUsername == username, glab.accountRevision == revision,
                  inboxHost == host else { return }
            await todoStore.markDone(todo, automatically: true)
        }
    }

    func runAutomationManually(for todo: Todo) async {
        guard case .ready = automationAction(for: todo),
              let host = glab.resolvedHost, let username = glab.currentUsername,
              let event = TodoAutomationEvent(todo: todo, username: username) else { return }
        await runAutomation(todo, event: event, host: host, username: username, manual: true)
    }

    private func runAutomation(
        _ todo: Todo, event: TodoAutomationEvent, host: String, username: String, manual: Bool
    ) async {
        let revision = glab.accountRevision
        @MainActor func isPending() -> Bool {
            glab.resolvedHost == host && glab.currentUsername == username && inboxHost == host
                && glab.accountRevision == revision && (manual || settings.automaticWritesAllowed)
                && !optimisticallyDone.contains(todo.id) && allTodos.contains { $0.id == todo.id }
        }

        guard isPending() else { return }
        do {
            let shouldAcknowledge = try await automation.prepareToAcknowledge(
                todo, event: event, host: host, username: username,
                settings: settings, glab: glab, manual: manual, isPending: isPending
            )
            if failedAutomationTodoID == todo.id,
               settings.automationReceipts.contains(.init(host: host, username: username, todoID: todo.id)) {
                failedAutomationTodoID = nil
            }
            if shouldAcknowledge, isPending() { await todoStore.markDone(todo, automatically: !manual) }
        } catch {
            if isPending() { failedAutomationTodoID = todo.id }
            Log.monitor.error("Automation failed for todo \(todo.id, privacy: .public): \(String(describing: error), privacy: .private)")
        }
    }

    var hasActiveWorkForUpdate: Bool {
        AssistantAutomationRunner.hasActiveJobs || automation.hasActiveActions || draftRegeneration.hasActiveWork
            || authoredMergeRequests.workflow.hasActiveWork || attention.confirmationStates.values.contains(where: \.isBusy)
    }

    func prepareForTermination() {
        incomingReviewFilter.stop()
        stopTimer()
        attention.automationConfigurationChanged()
        automation.cancelRunningScripts()
        AssistantAutomationRunner.prepareForTermination(settings: settings)
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
    }

    func automationConfigurationChanged(previous: AutomationSettings) {
        let current = settings.automation
        guard previous != current else { return }
        if previous.selectedAssistant != current.selectedAssistant
            || previous.isGloballySuspended != current.isGloballySuspended
            || previous.codexVerificationModel != current.codexVerificationModel
            || previous.claudeVerificationModel != current.claudeVerificationModel
            || previous.verificationThinking != current.verificationThinking {
            incomingReviewFilter.configurationChanged()
        }
        if settings.boardOrderingMethod == .automatic {
            boardPolicyOrder.policyChanged(from: previous.ignoringGlobalSuspension, to: current.ignoringGlobalSuspension,
                grouping: settings.boardGrouping)
        }
        boardSnapshotCache.invalidate()
        var previousWithCurrentReviewStart = previous
        previousWithCurrentReviewStart.requireReviewStartConfirmation = current.requireReviewStartConfirmation
        if previousWithCurrentReviewStart == current {
            // This setting controls admission of new work, so an already launched job keeps its policy.
            if !current.requireReviewStartConfirmation, current.hasEnabledAutomation,
               let host = glab.resolvedHost, let username = glab.currentUsername {
                Task { await self.routeMRTodos(host: host, username: username) }
            }
            return
        }
        let scopeOnly = previous.preservingScope(from: current) == current
        let host = glab.resolvedHost ?? "", username = glab.currentUsername ?? ""
        let targets = Set(previous.scope.individualTargets(host: host, username: username)
            + current.scope.individualTargets(host: host, username: username)
            + previous.scope.repositoryOverrides(host: host, username: username)
            + current.scope.repositoryOverrides(host: host, username: username))
        let executionChanged = previous.scope.mode != current.scope.mode
            || previous.isGloballySuspended != current.isGloballySuspended
            || previous.scope.pauseDraftsByDefault != current.scope.pauseDraftsByDefault
            || targets.contains { target in
                previous.scope.resolve(target).active != current.scope.resolve(target).active
                    || previous.scope.resolve(target, isDraft: true).active != current.scope.resolve(target, isDraft: true).active
            }
        let cancellationScope = currentAutomationCancellationScope
        authoredMergeRequests.cancelRuntimePreparation(outsideScope: cancellationScope)
        attention.cancelRuntimePreparation(outsideScope: cancellationScope)
        // Revoke the helper's persisted permission before stopping an in-flight worker.
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        automation.cancelRunningScripts(outsideScope: scopeOnly ? cancellationScope : nil)
        for handoff in settings.assistantHandoffs where handoff.execution?.state.isActive == true {
            if scopeOnly {
                let target = handoff.key.automationTarget
                guard handoff.manual != true, !cancellationScope.resolve(target).active else { continue }
            }
            cancelPolicyJob(handoff.id, settings)
        }
        attention.automationConfigurationChanged(outsideScope: scopeOnly ? cancellationScope : nil)
        mergeRequestIssues?.cancelAssessments()
        refreshRuntimeAssistantAvailability(force: previous.selectedAssistant != current.selectedAssistant)
        authoredMergeRequests.automationConfigurationChanged(outsideScope: scopeOnly ? cancellationScope : nil)
        authoredMergeRequests.workflow.synchronizeAssistantJobs()
        wakeAutomaticRetries()
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            attention.refresh(host: host, username: username, todos: visibleTodos)
            if current.hasEnabledAutomation && (!scopeOnly || executionChanged) {
                Task { await self.routeMRTodos(host: host, username: username) }
            }
        }
    }

    private var currentAutomationCancellationScope: MRAutomationScope {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return settings.automation.scope }
        let targets = settings.mrLifecycleLedger.targets(host: host, username: username)
        let latest = targets.compactMap { settings.mrLifecycleLedger.request(for: $0) }
        let fallback = attention.currentOpenItems.compactMap(\.mergeRequest).filter { request in
            !targets.contains(.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid))
        }
        return settings.automation.scope.cancellationScope(for: latest + fallback,
            host: host, username: username)
    }

    var hiddenBoardTargets: Set<MRAutomationScope.Target> {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return settings.ignoredMergeRequests }
        let filter = settings.reviewAssignments.incomingReviewFilter
        let suppressed = filter.entries.keys.filter { $0.host == host && $0.username == username && filter.suppresses($0) }
        return settings.ignoredMergeRequests.union(suppressed).union(settings.mrLifecycleLedger.targets(host: host, username: username)
            .filter { target in
                let state = settings.mrLifecycleLedger.request(for: target)?.state
                return state == .merged || state == .closed
            })
    }

    private func recordOwnedLifecycleObservations(_ requests: [GitLabMergeRequest], observedAt: Date) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        for request in requests where request.author.username == username {
            let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
            guard !settings.ignoredMergeRequests.contains(target) else { continue }
            settings.mrLifecycleLedger.record(request, for: target, now: observedAt,
                autoRemoveFinished: true)
            mergeRequestIssues?.observe(request, target: target, revision: glab.accountRevision, at: observedAt)
        }
        settings.save()
        deliverLifecycleTransitions()
        cancelIneligibleDraftAutomation()
    }

    private func deliverLifecycleTransitions() {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let events = settings.mrLifecycleLedger.takeTransitions(host: host, username: username)
        for event in events {
            guard let kind = AutoHandledEventBannerCenter.Kind(rawValue: event.kind.rawValue) else { continue }
            autoHandledEventBanners.receiveLifecycle(id: event.id, target: event.target, kind: kind,
                projectPath: event.url.gitLabProjectPath, enabled: settings.autoHandledEventBannersEnabled)
        }
        if !events.isEmpty { settings.save() }
    }

    func canAcknowledgeFinishedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              let current = settings.mrLifecycleLedger.request(for: target), current.webURL == item.url,
              current.state == item.mergeRequest?.state,
              settings.mrLifecycleLedger.completionID(for: target) == item.lifecycleCompletionID,
              current.state == .merged || current.state == .closed else { return false }
        return !settings.mrLifecycleLedger.isSuppressed(target)
    }

    @discardableResult
    func acknowledgeFinishedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard canAcknowledgeFinishedMergeRequest(item),
              let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
        settings.mrLifecycleLedger.acknowledgeFinished(target)
        let saved = settings.save()
        boardAttentionPresenter.updateAttention(pendingUserAttention)
        return saved
    }

    @discardableResult
    func applySettings() -> Bool {
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            settings.mrLifecycleLedger.prepareFinishedRemoval(host: host, username: username)
        }
        let saved = settings.save()
        boardAttentionPresenter.updateAttention(pendingUserAttention)
        return saved
    }

    var lifecycleCompletions: [MergeRequestLifecycleLedger.CompletionReceipt] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.mrLifecycleLedger.unreadCompletions(host: host, username: username,
            showMerged: true, showClosed: true)
    }

    @discardableResult
    func acknowledgeLifecycleCompletion(id: UUID) -> Bool {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              lifecycleCompletions.contains(where: { $0.id == id }),
              settings.acknowledgeLifecycleCompletion(id: id, host: host, username: username) else { return false }
        boardAttentionPresenter.updateAttention(pendingUserAttention)
        return true
    }

    func boardOrderingEntries(_ board: MergeRequestBoardSnapshot) -> [BoardPolicyOrder.Entry] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return [board.own, board.reviewed].flatMap { rows in
            rows.filter { $0.item.mergeRequest?.state == .opened }.enumerated().compactMap { rank, row in
                guard let request = row.item.mergeRequest else { return nil }
                let target = MRAutomationScope.Target.mergeRequest(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid)
                let pin = BoardCardPin.mergeRequest(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid)
                return .init(target: target, rank: rank, request: request,
                    discussionFingerprint: row.item.observedDiscussionFingerprint, jobID: row.latestJob?.id,
                    pinned: pin.map { settings.boardPins.contains($0) } == true)
            }
        }
    }

    private func cancelIneligibleDraftAutomation() {
        let scope = currentAutomationCancellationScope
        authoredMergeRequests.cancelRuntimePreparation(outsideScope: scope)
        attention.cancelRuntimePreparation(outsideScope: scope)
        guard scope != settings.automation.scope else { return }
        automation.cancelRunningScripts(outsideScope: scope)
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        for handoff in settings.assistantHandoffs where handoff.execution?.state.isActive == true && handoff.manual != true {
            let target = handoff.key.automationTarget
            if !scope.resolve(target).active { cancelPolicyJob(handoff.id, settings) }
        }
        attention.authorFeedbackCoordinator?.cancel(outsideScope: scope)
        attention.draftProofRecoveryCoordinator?.cancel(outsideScope: scope)
        attention.aiOriginCoordinator.cancel(outsideScope: scope)
    }

    func refreshAssistantRelay() {
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        refreshRuntimeAssistantAvailability()
        AssistantAutomationRunner.resumePendingJobs()
    }

    /// The result of one retry request. Callers that report the outcome elsewhere (such as to a paired phone)
    /// must use this value: `assistantJobActionError` is shared UI state that concurrent actions overwrite.
    enum AssistantJobRetryOutcome: Equatable {
        case queued(UUID)
        /// The retry was not needed any more; a notice explains why.
        case obsolete
        case unavailable
        case failed
    }

    @discardableResult
    func retryAssistantJob(_ id: UUID) async -> AssistantJobRetryOutcome {
        guard let job = assistantHandoffs.first(where: { $0.id == id }), !job.isObsoleteReminder else { return .unavailable }
        let target = job.key.automationTarget
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .requested, jobID: id)
        assistantJobActionError = nil
        assistantJobActionNotices.removeValue(forKey: id)
        do {
            let replacement = try await AssistantAutomationRunner.retry(id, settings: settings)
            mrTodoRouter.rebindJob(oldID: id, replacement: replacement)
            authoredMergeRequests.workflow.synchronizeAssistantJobs()
            settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .queued,
                jobID: replacement.id, relatedJobID: id)
            return .queued(replacement.id)
        } catch {
            if let pipelineError = error as? AssistantAutomationRunner.HandoffError, pipelineError.isObsoletePipelineRetry {
                assistantJobActionNotices[id] = pipelineError.localizedDescription
                settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .completed,
                    message: pipelineError.localizedDescription, jobID: id)
                await forceRefreshFromGitLab()
                return .obsolete
            } else if let known = error as? AssistantAutomationRunner.HandoffError {
                assistantJobActionError = known.localizedDescription
            } else if error as? AssistantJobExecutor.ExecutionError == .cliUnavailable {
                assistantJobActionError = String(localized: .AssistantJobs.assistantJobsActionFailed)
            } else if error as? AssistantJobExecutor.ExecutionError == .wrongAccount {
                assistantJobActionError = String(localized: .MRFreshness.mrFreshnessAccountChanged)
            } else if error as? AssistantJobExecutor.ExecutionError == .inactiveMergeRequest {
                assistantJobActionError = String(localized: .MRFreshness.mrFreshnessInactive)
            } else if error as? AssistantJobExecutor.ExecutionError == .headChanged {
                assistantJobActionError = String(localized: .MRFreshness.mrFreshnessStaleHead)
            } else {
                assistantJobActionError = String(localized: .MRFreshness.mrFreshnessStartFailed(
                    GlabService.redactWorkflowEvidence(String(describing: error))))
            }
            settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .failed,
                message: String(describing: error), jobID: id)
            Log.monitor.error("Could not retry assistant job: \(String(describing: error), privacy: .private)")
            return .failed
        }
    }

    func cancelAssistantJob(_ id: UUID) {
        guard assistantHandoffs.contains(where: { $0.id == id }) else { return }
        AssistantAutomationRunner.cancel(id, settings: settings)
    }

    func markDone(_ todo: Todo) async { await todoStore.markDone(todo, automatically: false) }

    func acknowledgeVisibleTodo(_ todo: Todo,
                                shouldProceed: @escaping @MainActor @Sendable () -> Bool) async -> InboxTodoStore.AcknowledgementResult {
        await todoStore.acknowledgeVisibleTodo(todo, shouldProceed: shouldProceed)
    }

    func markInboxNotificationsRead(_ notifications: [BoardCardPin], accountRevision: UInt64) async {
        var hiddenReviews: Set<UUID> = []
        for notification in notifications {
            guard !Task.isCancelled, glab.accountRevision == accountRevision else { return }
            guard notification.host == glab.resolvedHost, notification.username == glab.currentUsername else { continue }
            switch notification.item {
            case .todo(let id):
                if let todo = currentAccountTodos.first(where: { $0.id == id }) { await markDone(todo) }
            case .completion(let id):
                acknowledgeLifecycleCompletion(id: id)
            case .hiddenReviewNotification(let id):
                hiddenReviews.insert(id)
            case .mergeRequest:
                continue
            }
        }
        guard !Task.isCancelled, glab.accountRevision == accountRevision else { return }
        acknowledgeHiddenReviewNotifications(hiddenReviews)
    }

    /// Hides the to-do immediately but waits `undoWindow` before calling GitLab.
    func markDoneWithUndo(_ todo: Todo) { todoStore.markDoneWithUndo(todo) }

    func undoMarkDone() { todoStore.undoMarkDone() }

    /// Refreshes glab authentication and shares the current host with settings.
    @discardableResult
    func recheckIntegration() async -> GlabError? {
        let probeError = await glab.recheck()
        guard !Task.isCancelled else { return probeError }
        let error = probeError ?? (glab.currentUsername == nil ? .notAuthenticated : nil)
        lastError = error
        settings.resolvedHost = glab.resolvedHost
        settings.save()
        if error == nil { authoredMergeRequests.refreshIfNeeded() }
        return error
    }
}
