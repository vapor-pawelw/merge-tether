import Foundation
import Observation

@MainActor
@Observable
final class TodoMonitorService {
    let settings: SettingsManager
    let cliHealth = AssistantCLIHealthStore.shared
    let glab: GlabService
    let notifications: NotificationService
    let attention: MergeRequestAttentionMonitor
    let authoredMergeRequests: AuthoredMergeRequestMonitor
    private var boardDisplayMetadata = MRDisplayMetadataCache()
    let autoHandledEventBanners = AutoHandledEventBannerCenter()

    var autoHandledEventBanner: AutoHandledEventBannerCenter.Event? {
        autoHandledEventBanners.current(host: glab.resolvedHost, username: glab.currentUsername,
                                       enabled: settings.autoHandledEventBannersEnabled)
    }

    func dismissAutoHandledEventBanner(_ id: UUID) { autoHandledEventBanners.dismiss(id) }

    private let boardAttentionPresenter = BoardAttentionPresenter()
    private var attentionPresentationAccount: String? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return "\(host)/\(username)/\(glab.accountRevision)"
    }
    var userAttention: UserAttentionSnapshot {
        boardAttentionPresenter.userAttention(account: attentionPresentationAccount)
    }

    private func attentionKey(_ item: MergeRequestAttentionMonitor.Item) -> String? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return "\(host)/\(username)/mr/\(item.id.projectID)/\(item.id.iid)"
    }

    func confirmedHumanAction(for row: MergeRequestBoardSnapshot.Row) -> MRHumanAction? {
        boardAttentionPresenter.confirmedHumanAction(key: attentionKey(row.item), account: attentionPresentationAccount)
    }

    private func attentionRowState(_ row: MergeRequestBoardSnapshot.Row) -> BoardAttentionPresenter.RowState {
        .init(row: row, confirmationBusy: attention.confirmationStates[row.id]?.isBusy == true,
            conflictProcessing: row.item.mergeRequest.map { automaticConflictIsProcessing(for: $0) } == true,
            pipelineProcessing: row.item.mergeRequest.map { authoredMergeRequests.workflow.isAutomaticallyProcessingPipeline($0) } == true)
    }

    func attentionRefreshFailed(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        let workflowFailure = row.item.mergeRequest.map { authoredMergeRequests.workflow.hasReadOnlyFailure(for: $0) } == true
        let aiFailure = glab.resolvedHost.map {
            attention.aiOriginCoordinator.failure(work: .init(host: $0, projectID: row.id.projectID, iid: row.id.iid)) != nil
        } == true
        return BoardAttentionPresenter.attentionRefreshFailed(row: attentionRowState(row), refresh: .init(
            catalogReadFailed: lastError != nil || attention.hasError || authoredMergeRequests.hasError,
            workflowReadFailed: workflowFailure, needsAIAssessment: settings.automation.needsAIAssessment,
            aiOriginReadFailed: aiFailure))
    }

    func isRecheckingAttention(for row: MergeRequestBoardSnapshot.Row) -> Bool {
        BoardAttentionPresenter.isRecheckingAttention(row: attentionRowState(row), refresh: .init(
            catalogLoading: isLoading || attention.isLoading || authoredMergeRequests.isLoading,
            providerChecking: assistantDependencies.isChecking && settings.automation.packageDecision != .disabled,
            reviewingVerifying: !row.item.isAuthored && reviewingContext(for: row).nextStep == .verifying))
    }

    private let todoStore: InboxTodoStore
    var allTodos: [Todo] { todoStore.allTodos }
    private(set) var lastError: GlabError? {
        get { todoStore.lastError }
        set { todoStore.lastError = newValue }
    }
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
    private(set) var desktopHandoffError = false
    let assistantDependencies = AssistantDependencyMonitor()
    var availableAssistants: Set<AutomationAssistant> {
        assistantDependencies.available.filter { cliHealth.hold(for: $0) == nil }
    }
    private let codexIntegrationHealth = CodexIntegrationHealth()
    var codexListenerHealth: CodexDesktopRelay.ListenerHealth { codexIntegrationHealth.listenerHealth }
    var codexPluginInstallation: CodexPluginInstaller.Installation? { codexIntegrationHealth.pluginInstallation }

    private var optimisticallyDone: Set<Int> { todoStore.optimisticallyDone }
    var undoableTodo: Todo? { todoStore.undoableTodo }
    static let undoWindow = InboxTodoStore.undoWindow
    private var inboxHost: String? { todoStore.host }
    private var inboxUsername: String? { todoStore.username }
    private var inboxAccountRevision: UInt64? { todoStore.accountRevision }
    @ObservationIgnored private let attentionNotificationScheduler: AttentionNotificationScheduler
    @ObservationIgnored private var manualAdoptions: [MRAutomationScope.Target: Int] = [:]
    private var isAutomating = false
    private(set) var assessingMentionNoteIDs: Set<Int> = []

    func isAssessingNotice(_ todo: Todo) -> Bool {
        todo.linkedNoteID.map { assessingMentionNoteIDs.contains($0) } == true
    }
    private let automation: TodoAutomationService
    @ObservationIgnored private lazy var environmentRecovery = makeEnvironmentRecovery()

    private func makeEnvironmentRecovery() -> AutomaticEnvironmentRecovery {
        let recovery = AutomaticEnvironmentRecovery(settings: settings, fetch: { [weak self] original in
            guard let self, self.glab.resolvedHost == original.key.work.host,
                  self.glab.currentUsername == original.key.username else { throw CancellationError() }
            let revision = self.glab.accountRevision
            async let user = self.glab.fetchAuthenticatedUser(host: original.key.work.host, expectedUsername: original.key.username)
            async let request = self.glab.fetchMergeRequest(projectID: original.key.work.projectID,
                iid: original.key.work.iid, host: original.key.work.host)
            async let discussions = self.glab.fetchMergeRequestDiscussions(projectID: original.key.work.projectID,
                iid: original.key.work.iid, host: original.key.work.host)
            let snapshot = try await AutomaticEnvironmentRecovery.Snapshot(request: request, user: user, discussions: discussions)
            guard self.glab.resolvedHost == original.key.work.host,
                  self.glab.currentUsername == original.key.username, self.glab.accountRevision == revision else {
                throw CancellationError()
            }
            return snapshot
        }, launch: { [weak self] original, snapshot, prompt in
            guard let self else { throw CancellationError() }
            return try await AssistantAutomationRunner.launch(original.key.assistant, title: original.title,
                mergeRequestURL: snapshot.request.webURL, prompt: prompt,
                workspace: self.settings.automation.assistantWorkspace, access: original.key.access,
                work: original.key.work, username: original.key.username, settings: self.settings,
                feedbackNoteIDs: original.feedbackNoteIDs ?? [], feedbackTodos: original.feedbackTodos ?? [],
                mrWorkflow: .followUp, manual: false, expectedHeadSHA: snapshot.request.sha)
        })
        recovery.onScheduled = { [weak self] oldID, replacement in
            self?.mrTodoRouter.rebindJob(oldID: oldID, replacement: replacement)
        }
        return recovery
    }
    @ObservationIgnored private lazy var mrTodoRouter: MergeRequestTodoRouter = {
        let router = MergeRequestTodoRouter(settings: settings, glab: glab, canAutomate: { [weak self] in
            guard let self else { return false }
            return await AssistantCLI.detect(self.settings.automation.assistant, requireCLI: true).isReady
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
            let target = MRAutomationScope.Target(host: host, username: user.username,
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
    private var runningAttentionFeedback: Set<AssistantAutomationRunner.MergeRequestWork> = []
    private var failedAttentionFeedback: Set<AssistantAutomationRunner.MergeRequestWork> = []
    private var timer: Timer?
    private var hasCompletedFirstFetch: Bool { todoStore.hasCompletedFirstFetch }
    @ObservationIgnored private var legacyGUIQueueRetired = false

    init(
        settings: SettingsManager = SettingsManager(),
        glab: GlabService = GlabService(),
        notifications: NotificationService = NotificationService(),
        automation: TodoAutomationService = TodoAutomationService(),
        cancelPolicyJob: @escaping @MainActor (UUID, SettingsManager) -> Void = {
            AssistantAutomationRunner.cancel($0, settings: $1)
        }
    ) {
        self.settings = settings
        self.glab = glab
        self.todoStore = InboxTodoStore(settings: settings, glab: glab)
        self.notifications = notifications
        self.attentionNotificationScheduler = AttentionNotificationScheduler(notifications: notifications)
        self.automation = automation
        self.cancelPolicyJob = cancelPolicyJob
        self.attention = MergeRequestAttentionMonitor(glab: glab, settings: settings,
                                                       reportDirectory: CodexDesktopRelay.directory)
        self.authoredMergeRequests = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: notifications)
        todoStore.onAcknowledged = { [weak self] id in
            if self?.failedAutomationTodoID == id { self?.failedAutomationTodoID = nil }
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
        authoredMergeRequests.onObservedMergeRequests = { [weak self] requests, observedAt in
            self?.recordOwnedLifecycleObservations(requests, observedAt: observedAt)
        }
        attention.onAutomationEligibilityObserved = { [weak self] in
            self?.cancelIneligibleDraftAutomation()
        }
        authoredMergeRequests.workflow.onRemoteChange = { [weak self] in
            Task { await self?.refreshNow() }
        }
        authoredMergeRequests.authorFeedbackAllowsMerge = { [weak self] request, discussions, authorID in
            guard let self, let host = self.glab.resolvedHost, let username = self.glab.currentUsername,
                  let fingerprint = ReviewVerdict.fingerprint(discussions),
                  let assessment = self.attention.authorFeedbackCoordinator?.assessment(for: request, fingerprint: fingerprint) else { return false }
            let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
            return assessment.hasNoRemainingAuthorWork(in: discussions, authorID: authorID,
                ignoredSuggestions: self.settings.feedbackSuggestionDecisions.applicable(in: discussions, for: target))
        }
        authoredMergeRequests.authorFeedbackStatus = { [weak self] request in
            self?.attention.authorFeedbackCoordinator?.status(projectID: request.projectID, iid: request.iid)
        }
        attention.onAutoApproved = { [settings, notifications] request in
            if settings.notificationsEnabled { notifications.deliverAutoApproved(request) }
        }
        attention.onAuthorFeedbackNeedsWork = { [weak self] request, notes, fingerprint, residual in
            await self?.runVerifiedAuthorFeedback(request: request, noteIDs: notes, fingerprint: fingerprint,
                residual: residual, manual: false)
        }
        attention.onAuthorFeedbackChecked = { [weak self] in
            guard let self, let host = self.glab.resolvedHost, let username = self.glab.currentUsername else { return }
            Task { await self.mrTodoRouter.refreshCompletionEvidence(host: host, username: username) }
        }
        assistantDependencies.onRecovered = { [weak self] assistant in
            guard let self, self.settings.automation.assistant == assistant else { return }
            self.attention.authorFeedbackCoordinator?.retryReadOnlyFailures()
            self.attention.aiOriginCoordinator.retryReadOnlyFailures()
            self.authoredMergeRequests.workflow.retryReadOnlyFailures()
            if let host = self.glab.resolvedHost, let username = self.glab.currentUsername {
                self.attention.draftProofRecoveryCoordinator?.retryReadOnlyFailures(host: host, username: username)
            }
            if self.settings.automation.autoVerifyReReview {
                Task { await self.attention.retryFailedReReviews() }
            }
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
            Task { await self.refreshNow() }
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
        let input = withObservationTracking {
            let input = pendingUserAttention
            _ = settings.notificationsEnabled
            _ = freshUserAttention
            _ = glab.resolvedHost
            _ = glab.currentUsername
            return input
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeUserAttentionChanges()
                self?.scheduleUserAttentionNotifications()
            }
        }
        boardAttentionPresenter.updateAttention(input)
        boardPolicyOrder.observe(boardOrderingEntries(boardSnapshot))
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

    private func retireLegacyGUIQueueIfNeeded() {
        guard !legacyGUIQueueRetired else { return }
        do { legacyGUIQueueRetired = try CodexDesktopRelay.retirePendingGUIJobs(in: CodexDesktopRelay.directory) }
        catch { Log.monitor.error("Could not retire legacy GUI queue: \(String(describing: error), privacy: .private)") }
    }

    /// Refreshes CLI availability and sign-in without depending on desktop chats.
    func refreshAvailableAssistants() {
        assistantDependencies.refresh(requireCLI: requiresAssistantCLI, force: true)
    }

    var requiresAssistantCLI: Bool { true }

    var boardRefreshState: BoardRefreshState {
        guard settings.onboardingCompleted else { return .current }
        let todosReady = hasCompletedFirstFetch && glab.currentUsername != nil
            && inboxHost == glab.resolvedHost && inboxUsername == glab.currentUsername
            && inboxAccountRevision == glab.accountRevision
        let accountUnavailable = glab.currentUsername == nil && glab.authStatus != .unknown
        return .init(todosReady: todosReady, catalogReady: attention.hasSyncedCurrentCatalog,
                     authoredReady: authoredMergeRequests.hasSyncedCurrentCatalog,
                     isRefreshing: isLoading || attention.isLoading || authoredMergeRequests.isLoading,
                     hasError: lastError != nil || attention.hasError || authoredMergeRequests.hasError || accountUnavailable)
    }

    func bootstrap() async {
        retireLegacyGUIQueueIfNeeded()
        refreshAvailableAssistants()
        if glab.glabPath == nil {
            glab.glabPath = await OnboardingDetector.findGlabExecutable()
            settings.glabPath = glab.glabPath
        }
        await glab.recheck()
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

    var visibleTodos: [Todo] { todoStore.visibleTodos }

    /// Display only the inbox fetched for this exact authenticated account epoch.
    var currentAccountTodos: [Todo] { todoStore.currentAccountTodos }

    var pipelineHandoffs: [MergeWorkflowActivityEntry] {
        authoredMergeRequests.workflow.pendingPipelineHandoffs
    }

    var assistantGroups: [AssistantTaskGroup] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return AssistantTaskGroup.groups(from: settings.assistantHandoffs, host: host, username: username)
    }

    private var mergeRequestBrowser: MergeRequestBrowserSnapshot? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return MergeRequestBrowserSnapshot(openItems: lifecycleCatalogItems(host: host, username: username),
            authored: authoredMergeRequests.requests, host: host, username: username, scope: settings.automation.scope,
            ownCatalogIsAuthoritative: attention.hasCurrentOwnListing,
            draftsLast: settings.effectiveBoardGrouping == .drafts)
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
            let target = MRAutomationScope.Target(host: host, username: username, projectID: todo.project.id, iid: iid)
            return settings.routedMRTodoReceipts.contains { $0.target == target && $0.event == todo.feedbackIdentity }
                || currentMRTodoIntents.contains { $0.target == target && $0.sourceEvents.contains(todo.feedbackIdentity) }
        }.map(\.id))
    }

    var otherTodos: [Todo] { visibleTodos.filter { !routedMRTodoIDs.contains($0.id) } }

    func mrTodoIntents(for item: MergeRequestAttentionMonitor.Item) -> [MRTodoIntent] {
        currentMRTodoIntents.filter { $0.target.projectID == item.id.projectID && $0.target.iid == item.id.iid && $0.state != .completed }
    }

    func runMRTodoIntent(id: UUID) async {
        await mrTodoRouter.run(id, manual: true)
    }

    func dismissMRTodoIntent(id: UUID) { mrTodoRouter.dismiss(id) }

    func adoptMRTodoProposal(_ todo: Todo) async {
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
        settings.ignoredMergeRequests.remove(target)
        settings.mrLifecycleLedger.restore(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(todo.project.pathWithNamespace, for: target)
        settings.save()
        await routeMRTodos(host: target.host, username: target.username, automatically: false)
        guard !Task.isCancelled else { return }
        for intent in currentMRTodoIntents where intent.target == target && intent.state != .completed {
            await mrTodoRouter.run(intent.id, manual: true)
        }
        await refreshNow()
    }

    private func trackedReviewTarget(_ target: MRAutomationScope.Target) -> Bool {
        settings.automation.scope.isManaged(target) || settings.mrLifecycleLedger.request(for: target) != nil
            || settings.mrActionIntents.contains { $0.target == target && $0.grantsManagement }
            || settings.assistantChats.keys.contains {
                $0.work.host == target.host && $0.username == target.username && $0.work.projectID == target.projectID && $0.work.iid == target.iid
            }
            || settings.assistantHandoffs.contains {
                $0.key.work.host == target.host && $0.key.username == target.username
                    && $0.key.work.projectID == target.projectID && $0.key.work.iid == target.iid
            }
    }

    private func routeMRTodos(host: String, username: String, automatically: Bool = true) async {
        let managed = Set(reviewedMergeRequestItems.compactMap {
            scopeTarget(projectID: $0.id.projectID, iid: $0.id.iid, url: $0.url)
        })
        let acknowledged = await mrTodoRouter.process(allTodos, host: host, username: username, managed: managed, automatically: automatically)
        guard glab.resolvedHost == host, glab.currentUsername == username else { return }
        todoStore.acknowledge(acknowledged)
        if let error = mrTodoRouter.acknowledgementError { assistantJobActionError = error.localizedDescription }
        if automatically { await environmentRecovery.recover(host: host, username: username) }
    }

    func reviewingContext(for row: MergeRequestBoardSnapshot.Row) -> ReviewingContext {
        ReviewingContext(row: row,
            workflowState: ReviewingContext.workflowState(for: row, entries: authoredMergeRequests.workflow.entries),
            assistantReady: assistantDependencies.available.contains(settings.automation.assistant),
            assistantChecking: assistantDependencies.isChecking,
            draftAutomationAllowed: settings.automation.hasEnabledAutomation && row.item.mergeRequest.map {
                settings.automation.scope.permits($0, host: glab.resolvedHost ?? "", username: glab.currentUsername ?? "")
            } == true)
    }

    var ownMergeRequestItems: [MergeRequestAttentionMonitor.Item] { mergeRequestBrowser?.own ?? [] }
    var reviewedMergeRequestItems: [MergeRequestAttentionMonitor.Item] {
        (mergeRequestBrowser?.reviewed ?? []).filter { item in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return false }
            return !settings.ignoredMergeRequests.contains(target) && trackedReviewTarget(target)
        }
    }

    func assistantChatLinks(for item: MergeRequestAttentionMonitor.Item) -> [AssistantChatLink] {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return [] }
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: item.id.iid)
        let group = assistantGroups.first { $0.id == work }
        let preferred = settings.automation.assistant
        return ([preferred] + AutomationAssistant.allCases.filter { $0 != preferred }).compactMap { assistant in
            let key = AssistantAutomationRunner.ChatKey(assistant: assistant, work: work, username: target.username,
                                                        workspace: "", access: .gitLabRead)
            let recorded = key.reusableChat(in: settings.assistantChats) ?? settings.assistantChats.first {
                $0.key.assistant == assistant && $0.key.work == work && $0.key.username == target.username
            }?.value
            let candidates = [recorded] + (group?.handoffs.filter {
                $0.key.assistant == assistant && $0.relayComplete == true
            }.map(\.chatID) ?? [])
            let url = candidates.compactMap { chatID in
                chatID.flatMap(assistant == .codex
                    ? AssistantAutomationRunner.codexChatURL : AssistantAutomationRunner.claudeSessionURL)
            }.first
            return url.map { AssistantChatLink(assistant: assistant, url: $0) }
        }
    }

    var inbox: InboxSnapshot {
        InboxSnapshot(todos: currentAccountTodos, attention: attentionItems, host: glab.resolvedHost, username: glab.currentUsername)
    }

    var manualAssistantGroups: [AssistantTaskGroup] {
        assistantGroups.filter { group in
            manualHandoff(in: group) != nil
        }
    }

    func manualHandoff(in group: AssistantTaskGroup) -> AssistantAutomationRunner.Handoff? {
        group.manualHandoff(currentItem: attention.currentOpenItems.first {
            $0.id.projectID == group.id.projectID && $0.id.iid == group.id.iid
                && $0.url.isGitLabMergeRequest(host: group.id.host, iid: group.id.iid)
        })
    }

    private func matches(_ todo: Todo, work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        todo.targetType == .mergeRequest && todo.project.id == work.projectID && todo.target.iid == work.iid
            && todo.targetURL.gitLabTodoMergeRequestURL(host: work.host, iid: work.iid) != nil
    }

    func manualAssistantGroup(for todo: Todo) -> AssistantTaskGroup? {
        manualAssistantGroups.first { group in
            matches(todo, work: group.id) && visibleTodos.first(where: { matches($0, work: group.id) })?.id == todo.id
        }
    }

    func manualAssistantGroup(for item: MergeRequestAttentionMonitor.Item) -> AssistantTaskGroup? {
        manualAssistantGroups.first { group in
            group.id.projectID == item.id.projectID && group.id.iid == item.id.iid
                && !visibleTodos.contains(where: { matches($0, work: group.id) })
        }
    }

    var standaloneManualAssistantGroups: [AssistantTaskGroup] {
        let attention = inbox.attention
        return manualAssistantGroups.filter { group in
            !visibleTodos.contains(where: { matches($0, work: group.id) })
                && !attention.contains(where: { $0.id.projectID == group.id.projectID && $0.id.iid == group.id.iid })
        }
    }

    var hasAssistantAction: Bool {
        unavailableAssistant != nil
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
            !managed.contains(.init(host: account.host, username: account.username, projectID: request.projectID, iid: request.iid))
        }
    }

    func boardActivity(projectID: Int, iid: Int, url: URL, isDraft: Bool, isFinished: Bool = false) -> MRBoardActivity {
        .init(automation: settings.automation, target: scopeTarget(projectID: projectID, iid: iid, url: url),
              isDraft: isDraft, isFinished: isFinished, grouping: settings.boardGrouping)
    }

    func scopeTarget(projectID: Int, iid: Int, url: URL) -> MRAutomationScope.Target? {
        guard projectID > 0, iid > 0, let host = glab.resolvedHost, let username = glab.currentUsername,
              url.isGitLabMergeRequest(host: host, iid: iid) else { return nil }
        return .init(host: host, username: username, projectID: projectID, iid: iid)
    }

    /// The selected assistant's chat for this MR: a Codex thread or a Claude Code session.
    func existingCodexChat(for target: MRAutomationScope.Target) -> URL? {
        guard let iid = target.iid else { return nil }
        let assistant = settings.automation.assistant
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: iid)
        let key = AssistantAutomationRunner.ChatKey(assistant: assistant, work: work, username: target.username,
                                                     workspace: "", access: .gitLabRead)
        let chatID = key.reusableChat(in: settings.assistantChats) ?? settings.assistantChats.first {
            $0.key.assistant == assistant && $0.key.work == work && $0.key.username == target.username
        }?.value ?? assistantHandoffs.last {
            $0.key.work == work && $0.key.assistant == assistant && $0.chatID != nil
        }?.chatID
        return chatID.flatMap(assistant == .codex ? AssistantAutomationRunner.codexChatURL
                                                  : AssistantAutomationRunner.claudeSessionURL)
    }

    func addAutomationTarget(from address: String) async throws {
        let result = try await resolveAutomationTarget(from: address)
        enableAutomationTarget(result.target, projectPath: result.projectPath)
        await refreshNow()
    }

    /// Removes a foreign MR locally, retaining GitLab assignments, drafts and history.
    /// A persisted pause prevents global discovery from adding it back on the next poll.
    func removeReviewedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              let request = item.mergeRequest, request.author.username != target.username,
              request.projectID == target.projectID, request.iid == target.iid,
              request.webURL == item.url else { return }
        settings.ignoredMergeRequests.insert(target)
        settings.automation.scope[target] = .paused
        settings.save()
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: target.projectID, iid: item.id.iid)
        for job in assistantHandoffs where job.key.work == work && job.execution?.state.isActive == true {
            AssistantAutomationRunner.cancel(job.id, settings: settings)
        }
    }

    func ignoreMergeRequestProposal(projectID: Int, iid: Int, url: URL) async {
        guard projectID > 0, iid > 0, let target = scopeTarget(projectID: projectID, iid: iid, url: url) else { return }
        do {
            async let user = glab.fetchAuthenticatedUser(host: target.host, expectedUsername: target.username)
            async let request = glab.fetchMergeRequest(projectID: projectID, iid: iid, host: target.host)
            let (currentUser, currentRequest) = try await (user, request)
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username,
                  currentRequest.projectID == projectID, currentRequest.iid == iid,
                  currentRequest.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
                  currentRequest.author.id != currentUser.id else { return }
        } catch {
            lastError = error as? GlabError ?? .unknown(String(describing: error))
            return
        }
        settings.ignoredMergeRequests.insert(target)
        settings.automation.scope[target] = .paused
        settings.save()
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: projectID, iid: iid)
        for job in assistantHandoffs where job.key.work == work && job.execution?.state.isActive == true {
            AssistantAutomationRunner.cancel(job.id, settings: settings)
        }
        for todo in visibleTodos where todo.targetType == .mergeRequest && todo.project.id == projectID
            && todo.target.iid == iid && todo.targetURL.gitLabTodoMergeRequestURL(host: target.host, iid: iid) != nil {
            guard glab.resolvedHost == target.host, glab.currentUsername == target.username else { return }
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
            request = try await glab.fetchMergeRequest(projectID: projectID, iid: iid, host: host)
            guard request.projectID == projectID, request.iid == iid, request.state == "opened",
                  request.webURL.isGitLabMergeRequest(host: host, iid: iid),
                  glab.resolvedHost == host, glab.currentUsername == username else { throw CancellationError() }
            target = .init(host: host, username: username, projectID: projectID, iid: iid)
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
        settings.ignoredMergeRequests.remove(target)
        settings.mrLifecycleLedger.restore(target)
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(projectPath, for: target)
        settings.save()
    }

    private func resolveAutomationTarget(from address: String) async throws -> (target: MRAutomationScope.Target, projectPath: String, request: GitLabMergeRequest?) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let expected = URLComponents(string: "https://\(host)"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, ["https", "http"].contains(scheme),
              parts.host?.lowercased() == expected.host?.lowercased(), parts.user == nil, parts.password == nil,
              (parts.port ?? (scheme == "https" ? 443 : 80)) == (expected.port ?? (scheme == "https" ? 443 : 80))
        else { throw GlabError.decoding("Use a URL on the current GitLab host") }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.components(separatedBy: "/-/merge_requests/")
        let projectPath = components[0]
        guard (components.count == 1 || components.count == 2), projectPath.contains("/"),
              !projectPath.contains("/-/"), !projectPath.hasSuffix(".git") else {
            throw GlabError.decoding("Enter a GitLab repository or merge request URL")
        }
        let projectID = try await glab.resolveAutomationProject(path: projectPath, host: host)
        var iid: Int? = nil
        var verified: GitLabMergeRequest?
        if components.count == 2 {
            guard let number = Int(components[1]), number > 0 else {
                throw GlabError.decoding("Invalid merge request URL")
            }
            let request = try await glab.fetchMergeRequest(projectID: projectID, iid: number, host: host)
            guard request.projectID == projectID, request.iid == number, request.state == "opened", request.webURL.isGitLabMergeRequest(host: host, iid: number) else {
                throw GlabError.decoding("The merge request is no longer open")
            }
            iid = number
            verified = request
        }
        guard glab.resolvedHost == host, glab.currentUsername == username else { throw CancellationError() }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        return (target, projectPath, verified)
    }

    var attentionItems: [MergeRequestAttentionMonitor.Item] {
        var items = attention.currentItems.compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard let host = glab.resolvedHost, let username = glab.currentUsername, !item.feedback.isEmpty else { return item }
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
            let remaining = Set(AssistantAutomationRunner.unhandledFeedback(
                item.feedback.compactMap(\.id), work: work, username: username, settings: settings
            ))
            var item = item
            item.feedback.removeAll { $0.id.map { !remaining.contains($0) } ?? false }
            if item.feedback.isEmpty { item.needsDiscussion = item.hasOtherUnresolvedDiscussions }
            return item.needsAttention ? item : nil
        }
        let handoffs = pipelineHandoffs
        for handoff in handoffs {
            let mr = handoff.event.mergeRequest
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: mr.projectID, iid: mr.iid)
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].needsPipelineHandoff = true
                if items[index].mergeRequest == nil { items[index].mergeRequest = mr }
            } else {
                items.append(.init(id: id, title: mr.title, url: mr.webURL, needsPipelineHandoff: true, mergeRequest: mr))
            }
        }
        if !attention.hasError, !authoredMergeRequests.hasError, let host = glab.resolvedHost, let username = glab.currentUsername {
            for status in authoredMergeRequests.requests where status.mayMergeManually {
                let request = status.request
                guard request.author.username == username,
                      request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                      let current = attention.currentOpenItems.first(where: {
                          $0.id.projectID == request.projectID && $0.id.iid == request.iid
                      }), current.mergeRequest?.author.username == username, current.canOfferManualMerge(using: status)
                else { continue }
                let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
                guard (items.first(where: { $0.id == id })?.draftCount ?? 0) == 0 else { continue }
                let automatic = (availableAssistants.contains(settings.automation.assistant) || assistantDependencies.isChecking)
                    && status.mayAutoMerge && settings.permitsAutomaticAction(.merge, for: request,
                        target: .init(host: host, username: username, projectID: request.projectID, iid: request.iid))
                    && !AssistantJobExecution.hasUnfinishedWork(in: settings.assistantHandoffs,
                        for: .init(host: host, projectID: id.projectID, iid: id.iid), username: username,
                        currentRequest: request, feedbackStatus: current.authorFeedbackStatus,
                        discussionFingerprint: current.observedDiscussionFingerprint)
                guard !automatic else { continue }
                if let index = items.firstIndex(where: { $0.id == id }) { items[index].needsMerge = true }
                else { items.append(.init(id: id, title: request.title, url: request.webURL, needsMerge: true, mergeRequest: request, isAuthored: true)) }
            }
        }
        let visible = items.compactMap { item -> MergeRequestAttentionMonitor.Item? in
            guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return item }
            let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: item.id.projectID, iid: item.id.iid)
            let currentEvents = authoredMergeRequests.workflow.entries.filter {
                $0.event.mergeRequest.projectID == item.id.projectID && $0.event.mergeRequest.iid == item.id.iid
                    && $0.event.mergeRequest.sha == item.mergeRequest?.sha
            }
            var failures = Set(MergeWorkflowTrigger.allCases.filter { trigger in
                guard let entry = currentEvents.first(where: { $0.event.kind == trigger }) else { return false }
                return entry.state == .failed && !entry.isReadOnlyFailure
            })
            if failedAttentionFeedback.contains(work) { failures.insert(.newDiscussion) }
            let conflictFailed = item.mergeRequest.map {
                authoredMergeRequests.conflictTaskFailed(for: $0)
                    || ($0.hasMergeConflict && authoredMergeRequests.conflictAutomationState(for: $0) == nil)
            } ?? false
            let pipelineState = currentEvents.first { $0.event.kind == .pipelineFailure
                && $0.event.pipelineID == item.mergeRequest?.headPipeline?.id }?.state
            let pipelineOwned = pipelineState.map { [.queued, .running, .waitingForAssistant, .completed, .alreadyRegistered].contains($0) } ?? false
            let feedbackState = currentEvents.first { $0.event.kind == .newDiscussion }?.state
            let feedbackOwned = feedbackState.map { [.queued, .running, .waitingForAssistant, .completed].contains($0) } ?? false
            let visible = item.requiringUserAttention(automation: settings.automation, target: target,
                                                     failedTriggers: failures, conflictTaskFailed: conflictFailed,
                                                     pipelineOwnedAutomatically: pipelineOwned, feedbackOwnedAutomatically: feedbackOwned)
            return visible.needsAttention ? visible : nil
        }
        return MergeRequestAttentionMonitor.Item.ordered(visible)
    }

    func unmanagedTarget(for item: MergeRequestAttentionMonitor.Item) -> MRAutomationScope.Target? {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              !settings.automation.scope.resolve(target).active else { return nil }
        return target
    }

    func manageAttentionItem(_ item: MergeRequestAttentionMonitor.Item) async {
        guard let target = unmanagedTarget(for: item) else { return }
        settings.automation.scope[target] = .active
        settings.automation.scope.rememberRepository(item.url.gitLabProjectPath, for: target)
        settings.save()
        if automaticallyHandlesFeedback(item) { await runAttentionFeedback(for: item, manual: false) }
        await refreshNow()
    }

    private func automaticallyHandlesFeedback(_ item: MergeRequestAttentionMonitor.Item) -> Bool {
        guard let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
              let request = item.authoredRequest, request.state == "opened",
              settings.automation.scope.permits(request, host: target.host, username: target.username),
              request.author.username == target.username else { return false }
        let rule = settings.automation.workflowRules[.newDiscussion]
        let feedback = settings.automation.authorFeedback
        guard feedback.runner == .assistant, feedback.isConfigured, feedback.includes(project: item.url.gitLabProjectPath) else { return false }
        return feedback.isEnabled || (rule.mode == .assistant && rule.includes(request))
    }

    var assistantHandoffs: [AssistantAutomationRunner.Handoff] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return settings.assistantHandoffs.filter { $0.key.work.host == host && $0.key.username == username }
    }

    var unavailableAssistant: AutomationAssistant? {
        let assistant = settings.automation.assistant
        if (settings.automation.usesAssistant || settings.automation.autoReReviewEnabled
            || settings.automation.autoMergeEnabled || settings.automation.autoApproveEnabled
            || settings.automation.publishDraftsWithoutConfirmation || settings.automation.publishAIRepliesWithoutConfirmation),
           let status = assistantDependencies.statuses[assistant], !status.isReady { return assistant }
        return assistantHandoffs.first { handoff in
            handoff.execution?.state.isActive == true && assistantDependencies.statuses[handoff.key.assistant].map { !$0.isReady } == true
        }?.key.assistant
    }

    var assistantDependencyWarning: LocalizedStringResource? {
        guard let assistant = unavailableAssistant else { return nil }
        return assistantDependencies.statuses[assistant]?.message(for: assistant)
    }

    // Retained for decoding old integration state; desktop listeners no longer execute work.
    func checkCodexListener(force: Bool = false, now: Date = Date()) {
        codexIntegrationHealth.checkListener(force: force, now: now)
    }
    var codexListenerWarning: LocalizedStringResource? { codexIntegrationHealth.listenerWarning }

    func automaticConflictIsProcessing(for request: GitLabMergeRequest) -> Bool {
        guard availableAssistants.contains(settings.automation.assistant) || assistantDependencies.isChecking,
              let state = authoredMergeRequests.conflictAutomationState(for: request) else { return false }
        return state == .available || state == .processing
    }

    /// Shared semantic projection for the menu indicator and native notifications.
    private var pendingUserAttention: ConfirmedAttentionSnapshot.Input {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return .init(account: nil) }
        let ready = availableAssistants.contains(settings.automation.assistant)
        let preparing = ready || assistantDependencies.isChecking
        let board = MergeRequestBoardSnapshot(own: ownMergeRequestItems, reviewed: reviewedMergeRequestItems,
            todos: currentAccountTodos, attention: attentionItems, handoffs: settings.assistantHandoffs,
            host: host, username: username, intents: currentMRTodoIntents, routedTodoIDs: routedMRTodoIDs,
            ignoredTargets: hiddenBoardTargets, pipelineEvidence: currentPipelineEvidence,
            pipelineEvidenceCheckedAt: currentPipelineEvidenceDate, automation: settings.automation)
        var rows: [BoardAttentionPresenter.PresentedRow] = []
        for row in board.own + board.reviewed {
            guard row.item.mergeRequest?.state == "opened" else { continue }
            let target = MRAutomationScope.Target(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid)
            guard !settings.ignoredMergeRequests.contains(target) else { continue }
            let item = row.item.presentingHumanAttention(
                filtered: attentionItems.first { $0.id == row.id },
                unfiltered: attention.currentItems.first { $0.id == row.id },
                assistantReady: preparing)
            let state = attention.confirmationStates[row.id]
            let conflictProcessing = row.item.mergeRequest.map { automaticConflictIsProcessing(for: $0) } ?? false
            let pipelineProcessing = row.item.mergeRequest.map { authoredMergeRequests.workflow.isAutomaticallyProcessingPipeline($0) } ?? false
            let recoveryWaitsForHuman = (row.item.draftProofRecoveryChecking || row.isCheckingReadOnlyReconciliation) && row.hasIndependentStoppedWork
            let busy = row.latestJob?.operationalExecution?.state.isActive == true || state?.isBusy == true
                || row.item.aiOriginChecking
                || (!recoveryWaitsForHuman && (row.item.authorFeedbackStatus?.phase == .checking || row.item.draftProofRecoveryChecking))
                || conflictProcessing || pipelineProcessing
                || (!recoveryWaitsForHuman && !row.item.isAuthored && reviewingContext(for: row).isAutomaticProcessing)
            let automaticDrafts = item.draftIDsHandledAutomatically(automation: settings.automation,
                target: target, assistantPreparing: preparing,
                publicationAutomatic: settings.actionIsAutomatic(.commentPublication, for: target))
            rows.append(.init(row: row, item: item, confirmationState: state, busy: busy,
                automaticDraftIDs: automaticDrafts,
                checking: isRecheckingAttention(for: row) || attentionRefreshFailed(for: row),
                automaticIntentIDs: Set(row.attentionIntents.filter { attentionIntentIsAutomatic($0, ready: preparing) }.map(\.id))))
        }
        return BoardAttentionPresenter.project(.init(account: attentionPresentationAccount, host: host, username: username,
            rows: rows, proposals: board.proposals, otherTodos: board.otherTodos, inboxLoading: isLoading,
            assessingMentionNoteIDs: assessingMentionNoteIDs, assistantReady: ready, assistantPreparing: preparing))
    }

    private func attentionIntentIsAutomatic(_ intent: MRTodoIntent, ready: Bool) -> Bool {
        let configuration = settings.automation
        guard configuration.packageDecision != .disabled, configuration.scope.resolve(intent.target).active,
              !settings.ignoredMergeRequests.contains(intent.target), intent.request.state == "opened",
              intent.isDeferredReview || (ready && configuration.scope.permits(intent.request,
                  host: intent.target.host, username: intent.target.username)) else { return false }
        let project = intent.request.webURL.gitLabProjectPath
        switch intent.kind {
        case .review:
            let rule = configuration.reviewRequested
            return rule.isEnabled && rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
        case .followUp:
            let rule = configuration.authorFeedback
            let workflow = configuration.workflowRules[.newDiscussion]
            return rule.runner == .assistant && rule.isConfigured && rule.includes(project: project)
                && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(intent.request)))
        case .pipeline:
            let rule = configuration.workflowRules[.pipelineFailure]
            return intent.request.author.username == intent.target.username && configuration.autoClaimPipelineFailures
                && rule.mode == .assistant && rule.includes(intent.request)
        default: return false
        }
    }

    var attentionCount: Int { inbox.attention.count + standaloneManualAssistantGroups.count + (hasAssistantAction ? 1 : 0) }
    var badgeCount: Int { inbox.count + standaloneManualAssistantGroups.count + (hasAssistantAction ? 1 : 0) }

    var hasUnseenTodos: Bool {
        guard !currentAccountTodos.isEmpty else { return false }
        guard let lastOpened = settings.lastMenuOpenedAt else { return false }
        return currentAccountTodos.contains { $0.createdAt > lastOpened }
    }

    var dashboardURL: URL {
        glab.dashboardTodosURL ?? URL(string: "https://gitlab.com/dashboard/todos")!
    }

    // MARK: - Lifecycle

    func start() {
        Task { await refreshNow() }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = settings.refreshInterval.seconds
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshNow()
            }
        }
        restartUnreadReminderTimer()
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        stopUnreadReminderTimer()
    }

    func markMenuOpened() {
        settings.lastMenuOpenedAt = Date()
        settings.save()
        stopUnreadReminderTimer()
    }

    /// Retained for settings compatibility; periodic raw-to-do reminders are retired.
    func restartUnreadReminderTimer() { attentionNotificationScheduler.restartUnreadReminderTimer() }

    private func stopUnreadReminderTimer() { attentionNotificationScheduler.stopUnreadReminderTimer() }

    // MARK: - Commands

    /// A visible user request may join a background read. Its intent remains until the
    /// existing catalog children settle; it never changes their fetch or action policy.
    func refreshManually() async {
        await refreshProgress.perform(scope: .global, accountRevision: glab.accountRevision,
            currentAccountRevision: { self.glab.accountRevision },
            isRefreshing: { self.isLoading || self.attention.isLoading || self.authoredMergeRequests.isLoading },
            refresh: { await self.refreshNow() })
    }

    func refreshFromGitLab(for id: MergeRequestAttentionMonitor.Item.ID) async {
        await refreshProgress.perform(scope: .mergeRequest(id), accountRevision: glab.accountRevision,
            currentAccountRevision: { self.glab.accountRevision },
            isRefreshing: { self.isLoading || self.attention.isLoading || self.authoredMergeRequests.isLoading },
            refresh: { await self.forceRefreshFromGitLab() })
    }

    func refreshNow() async {
        retireLegacyGUIQueueIfNeeded()
        refreshAvailableAssistants()
        refreshAssistantRelay()
        guard todoStore.beginRefresh() else { return }
        defer {
            todoStore.finishRefresh()
            boardAttentionPresenter.updateAttention(pendingUserAttention)
            scheduleUserAttentionNotifications()
        }

        // A launch-time probe can fail while offline. Fetching to-dos alone
        // cannot restore the account required by the MR monitors.
        if glab.currentUsername == nil || lastError == .notAuthenticated {
            if await recheckIntegration() != nil { return }
        }
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

            if let host, let username, !isAutomating {
                automation.prune(fetchedIDs: fetchedIDs, host: host, username: username, settings: settings)
            }

            settings.lastSeenTodoIDs = fetchedIDs
            settings.save()

            todoStore.accept(fetchedFiltered)
            restartUnreadReminderTimer()
            if let host, let username {
                if settings.onboardingCompleted {
                    attention.refresh(host: host, username: username, todos: fetchedFiltered)
                }
                await routeMRTodos(host: host, username: username)
                await acknowledgeHandledTodos(host: host, username: username)
                scheduleAutomation(host: host, username: username)
            }

        case .failure(let err):
            Log.monitor.error("Refresh failed: \(String(describing: err), privacy: .public)")
            lastError = err
            // Intentionally keep allTodos as-is: a stale list is more useful
            // than an empty one while the user fixes their glab auth.
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

    private func scheduleAutomation(host: String, username: String) {
        guard !isAutomating,
              settings.onboardingCompleted,
              settings.automation.reviewRequested.isEnabled || settings.automation.authorFeedback.isEnabled
        else { return }

        let candidates = visibleTodos.reversed().compactMap { todo in
            // MR events are classified exclusively by the durable router. Unknown
            // mentions must not fall through to the former broad automation path.
            guard todo.targetType != .mergeRequest else { return Optional<(Todo, TodoAutomationEvent)>.none }
            return TodoAutomationEvent(todo: todo, username: username).map { (todo, $0) }
        }
        guard !candidates.isEmpty else { return }

        isAutomating = true
        Task {
            defer { isAutomating = false }
            for (todo, event) in candidates {
                await runAutomation(todo, event: event, host: host, username: username, manual: false)
            }
        }
    }

    func automationAction(for todo: Todo) -> TodoAutomationService.ActionState? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, inboxHost == host else { return nil }
        return automation.actionState(
            for: todo, host: host, username: username, settings: settings, available: availableAssistants
        )
    }

    func attentionFeedbackAction(for item: MergeRequestAttentionMonitor.Item) -> TodoAutomationService.ActionState? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername, inboxHost == host,
              let request = item.authoredRequest, request.author.username == username,
              availableAssistants.contains(settings.automation.assistant) else { return nil }
        let rule = settings.automation.authorFeedback
        guard rule.runner == .assistant, rule.isConfigured, rule.includes(project: item.url.gitLabProjectPath) else { return nil }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
        if runningAttentionFeedback.contains(work) { return .running }
        guard !attentionFeedbackNoteIDs(for: item, work: work, username: username).isEmpty else { return nil }
        return failedAttentionFeedback.contains(work) ? .failed : .ready(.assistant)
    }

    private func attentionFeedbackNoteIDs(
        for item: MergeRequestAttentionMonitor.Item, work: AssistantAutomationRunner.MergeRequestWork, username: String
    ) -> [Int] {
        let notes = TodoAutomationEvent.feedbackWithoutTodo(
            item.feedback, todos: allTodos, host: work.host, projectID: work.projectID, iid: work.iid, username: username
        ).compactMap(\.id)
        return AssistantAutomationRunner.unhandledFeedback(notes, work: work, username: username, settings: settings)
    }

    func runAttentionFeedback(for item: MergeRequestAttentionMonitor.Item, manual: Bool = true) async {
        guard let action = attentionFeedbackAction(for: item), action == .ready(.assistant) || action == .failed,
              let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: item.id.projectID, iid: item.id.iid)
        guard runningAttentionFeedback.insert(work).inserted else { return }
        defer { runningAttentionFeedback.remove(work) }
        failedAttentionFeedback.remove(work)
        let notes = attentionFeedbackNoteIDs(for: item, work: work, username: username)
        do {
            try await automation.prepareFeedback(work: work, noteIDs: notes, username: username, settings: settings, glab: glab, manual: manual) {
                self.glab.resolvedHost == host && self.glab.currentUsername == username && self.inboxHost == host
                    && self.attentionFeedbackNoteIDs(for: item, work: work, username: username) == notes
                    && (manual || self.automaticallyHandlesFeedback(item))
            }
        } catch {
            failedAttentionFeedback.insert(work)
            Log.monitor.error("Could not prepare MR feedback: \(String(describing: error), privacy: .private)")
        }
    }

    func runVerifiedAuthorFeedback(request: GitLabMergeRequest, noteIDs: Set<Int>, fingerprint: String,
                                  residual: AuthorFeedbackResidual? = nil, manual: Bool = true) async {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              request.author.username == username, !noteIDs.isEmpty else { return }
        let configuration = settings.automation
        let rule = configuration.authorFeedback
        let workflow = configuration.workflowRules[.newDiscussion]
        guard rule.runner == .assistant, rule.isConfigured, rule.includes(project: request.webURL.gitLabProjectPath),
              manual || (configuration.packageDecision != .disabled && configuration.scope.permits(request, host: host, username: username)
                  && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(request)))) else { return }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
        guard manual || !failedAttentionFeedback.contains(work),
              !AssistantAutomationRunner.isWorking(on: work), runningAttentionFeedback.insert(work).inserted else { return }
        defer { runningAttentionFeedback.remove(work) }
        failedAttentionFeedback.remove(work)
        do {
            try await automation.prepareFeedback(work: work, noteIDs: noteIDs.sorted(), username: username,
                settings: settings, glab: glab, manual: manual, verifiedFingerprint: fingerprint, expectedHeadSHA: request.sha,
                verifiedResidual: residual ?? attention.authorFeedbackCoordinator?.reviewContext(for: request, fingerprint: fingerprint)) {
                    self.glab.resolvedHost == host && self.glab.currentUsername == username
                        && self.settings.automation == configuration
                }
        } catch {
            failedAttentionFeedback.insert(work)
            Log.monitor.error("Could not handle verified author feedback: \(String(describing: error), privacy: .private)")
        }
    }

    private func acknowledgeHandledTodos(host: String, username: String) async {
        var handled = Set(assistantHandoffs.flatMap(\.deliveredFeedbackTodos))
        handled.formUnion(settings.pendingTodoAcknowledgements.lazy
            .filter { $0.host == host && $0.username == username }.map(\.todo))
        for todo in visibleTodos where handled.contains(todo.feedbackIdentity) {
            if todo.targetType == .mergeRequest,
               !settings.routedMRTodoReceipts.contains(where: { $0.target.host == host && $0.target.username == username && $0.event == todo.feedbackIdentity }),
               !settings.pendingTodoAcknowledgements.contains(where: { $0.host == host && $0.username == username && $0.todo == todo.feedbackIdentity }) { continue }
            guard glab.resolvedHost == host, glab.currentUsername == username, inboxHost == host else { return }
            await markDone(todo)
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
        @MainActor func isPending() -> Bool {
            glab.resolvedHost == host && glab.currentUsername == username && inboxHost == host
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
            if shouldAcknowledge, isPending() { await markDone(todo) }
        } catch {
            if isPending() { failedAutomationTodoID = todo.id }
            Log.monitor.error("Automation failed for todo \(todo.id, privacy: .public): \(String(describing: error), privacy: .private)")
        }
    }

    func prepareForTermination() {
        attention.automationConfigurationChanged()
        automation.cancelRunningScripts()
        AssistantAutomationRunner.prepareForTermination(settings: settings)
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
    }

    func automationConfigurationChanged(previous: AutomationSettings) {
        let current = settings.automation
        guard previous != current else { return }
        boardPolicyOrder.policyChanged(from: previous, to: current, grouping: settings.boardGrouping)
        let scopeOnly = previous.preservingScope(from: current) == current
        let host = glab.resolvedHost ?? "", username = glab.currentUsername ?? ""
        let targets = Set(previous.scope.individualTargets(host: host, username: username)
            + current.scope.individualTargets(host: host, username: username)
            + previous.scope.repositoryOverrides(host: host, username: username)
            + current.scope.repositoryOverrides(host: host, username: username))
        let executionChanged = previous.scope.mode != current.scope.mode
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
                let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                    projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
                guard handoff.manual != true, !cancellationScope.resolve(target).active else { continue }
            }
            cancelPolicyJob(handoff.id, settings)
        }
        attention.automationConfigurationChanged(outsideScope: scopeOnly ? cancellationScope : nil)
        assistantDependencies.refresh(requireCLI: true, force: !scopeOnly)
        authoredMergeRequests.automationConfigurationChanged(outsideScope: scopeOnly ? cancellationScope : nil)
        authoredMergeRequests.workflow.synchronizeAssistantJobs()
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
            !targets.contains(.init(host: host, username: username, projectID: request.projectID, iid: request.iid))
        }
        return settings.automation.scope.cancellationScope(for: latest + fallback,
            host: host, username: username)
    }

    var hiddenBoardTargets: Set<MRAutomationScope.Target> {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return settings.ignoredMergeRequests }
        return settings.ignoredMergeRequests.union(settings.mrLifecycleLedger.targets(host: host, username: username)
            .filter { target in
                let state = settings.mrLifecycleLedger.request(for: target)?.state
                return state == "merged" || state == "closed"
            })
    }

    private func lifecycleCatalogItems(host: String, username: String) -> [MergeRequestAttentionMonitor.Item] {
        var rows = Dictionary(attention.currentOpenItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for request in settings.mrLifecycleLedger.retainedRequests(host: host, username: username) {
            let id = MergeRequestAttentionMonitor.Item.ID(projectID: request.projectID, iid: request.iid)
            let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
            if let original = rows[id]?.mergeRequest, original.sha == request.sha,
               original.state == request.state, original.draft == request.draft {
                rows[id]?.lifecycleCompletionID = settings.mrLifecycleLedger.completionID(for: target)
                continue
            }
            // Never attach old publication/feedback proof to newly observed source or lifecycle state.
            rows[id] = .init(id: id, title: request.title, url: request.webURL,
                mergeRequest: request, isAuthored: request.author.username == username)
            rows[id]?.lifecycleCompletionID = settings.mrLifecycleLedger.completionID(for: target)
        }
        return rows.values.filter {
            !hiddenBoardTargets.contains(.init(host: host, username: username, projectID: $0.id.projectID, iid: $0.id.iid))
        }
    }

    private func recordOwnedLifecycleObservations(_ requests: [GitLabMergeRequest], observedAt: Date) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        for request in requests where request.author.username == username {
            let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
            guard !settings.ignoredMergeRequests.contains(target) else { continue }
            settings.mrLifecycleLedger.record(request, for: target, now: observedAt,
                autoRemoveFinished: true)
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
              current.state == "merged" || current.state == "closed" else { return false }
        return !settings.mrLifecycleLedger.isSuppressed(target)
    }

    func acknowledgeFinishedMergeRequest(_ item: MergeRequestAttentionMonitor.Item) {
        guard canAcknowledgeFinishedMergeRequest(item),
              let target = scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) else { return }
        settings.mrLifecycleLedger.acknowledgeFinished(target)
        settings.save()
        boardAttentionPresenter.updateAttention(pendingUserAttention)
    }

    func applySettings() {
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            settings.mrLifecycleLedger.prepareFinishedRemoval(host: host, username: username)
        }
        settings.save()
        boardAttentionPresenter.updateAttention(pendingUserAttention)
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
              settings.mrLifecycleLedger.acknowledgeCompletion(id: id, host: host, username: username) else { return false }
        settings.save()
        boardAttentionPresenter.updateAttention(pendingUserAttention)
        return true
    }

    func boardOrderingEntries(_ board: MergeRequestBoardSnapshot) -> [BoardPolicyOrder.Entry] {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        return [board.own, board.reviewed].flatMap { rows in
            rows.filter { $0.item.mergeRequest?.state == "opened" }.enumerated().compactMap { rank, row in
                guard let request = row.item.mergeRequest else { return nil }
                let target = MRAutomationScope.Target(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid)
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
            let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
            if !scope.resolve(target).active { cancelPolicyJob(handoff.id, settings) }
        }
        attention.authorFeedbackCoordinator?.cancel(outsideScope: scope)
        attention.draftProofRecoveryCoordinator?.cancel(outsideScope: scope)
        attention.aiOriginCoordinator.cancel(outsideScope: scope)
    }

    func refreshAssistantRelay() {
        FollowUpVerificationStore.synchronizeRuns(settings: settings)
        assistantDependencies.refresh(requireCLI: true)
    }

    func retryAssistantJob(_ id: UUID) async {
        guard let job = assistantHandoffs.first(where: { $0.id == id }), !job.isObsoleteReminder else { return }
        let target = MRAutomationScope.Target(host: job.key.work.host, username: job.key.username,
            projectID: job.key.work.projectID, iid: job.key.work.iid)
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .requested, jobID: id)
        assistantJobActionError = nil
        assistantJobActionNotices.removeValue(forKey: id)
        do {
            let replacement = try await AssistantAutomationRunner.retry(id, settings: settings)
            mrTodoRouter.rebindJob(oldID: id, replacement: replacement)
            authoredMergeRequests.workflow.synchronizeAssistantJobs()
            settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .queued,
                jobID: replacement.id, relatedJobID: id)
        } catch {
            if let pipelineError = error as? AssistantAutomationRunner.HandoffError, pipelineError.isObsoletePipelineRetry {
                assistantJobActionNotices[id] = pipelineError.localizedDescription
                settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .completed,
                    message: pipelineError.localizedDescription, jobID: id)
                await forceRefreshFromGitLab()
                return
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
        }
    }

    func cancelAssistantJob(_ id: UUID) {
        guard assistantHandoffs.contains(where: { $0.id == id }) else { return }
        AssistantAutomationRunner.cancel(id, settings: settings)
    }

    // Compatibility for old unmounted views. Manual opening is now a separate per-MR menu.
    func openAssistantHandoff(_ id: UUID) async { await retryAssistantJob(id) }
    func openCodexForListener() async {}
    func requestCodexDispatch(_ id: UUID) { Task { await retryAssistantJob(id) } }

    func dismissAssistantHandoff(_ id: UUID) {
        guard let handoff = assistantHandoffs.first(where: { $0.id == id }) else { return }
        if let reservation = handoff.pipelineReservation {
            try? ExistingPipelineWorkDetector().finishHandoff(for: reservation)
        }
        AssistantAutomationRunner.cancel(id, settings: settings)
        settings.assistantHandoffs.removeAll { $0.id == id }
        settings.save()
    }

    func markDone(_ todo: Todo) async { await todoStore.markDone(todo) }

    /// Hides the to-do immediately but waits `undoWindow` before calling GitLab.
    func markDoneWithUndo(_ todo: Todo) { todoStore.markDoneWithUndo(todo) }

    func undoMarkDone() { todoStore.undoMarkDone() }

    /// Refreshes glab authentication and shares the current host with settings.
    @discardableResult
    func recheckIntegration() async -> GlabError? {
        let error = await glab.recheck()
        lastError = error
        settings.resolvedHost = glab.resolvedHost
        settings.save()
        if error == nil { authoredMergeRequests.refreshIfNeeded() }
        return error
    }
}
