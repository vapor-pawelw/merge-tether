import Foundation
import Observation

@MainActor
@Observable
final class SettingsManager {
    var pendingCommentReviews: Set<MRAutomationScope.Target> = []
    var commentReviewProgress: [MRAutomationScope.Target: CommentReviewProgress] = [:]
    @ObservationIgnored var commentReviewRevisions: [MRAutomationScope.Target: UInt64] = [:]
    private let defaults: UserDefaults
    let persistenceStore: DurableSettingsStore
    let automationProfileHistory: AutomationProfileHistoryStore
    private(set) var acceptedAutomation: AutomationSettings
    /// Convenience caches are preserved and diagnosed without stopping MR actions.
    var persistenceDegraded: Set<String> {
        Set(persistenceStore.failures.keys).subtracting(Self.conveniencePersistenceKeys)
    }
    var automaticActionsAllowed: Bool { persistenceDegraded.isEmpty }
    var automaticWritesAllowed: Bool { automaticActionsAllowed && automation.hasAutomaticActionConsent }
    var automaticPublicWritesAllowed: Bool { automaticActionsAllowed && automation.hasAutomaticPublicActionConsent }
    private static let conveniencePersistenceKeys: Set<String> = [
        "automationEvents", "boardPins", "boardManualOrder", "lastSeenTodoIDs", "reviewAssignments", "incomingReviewFilterSettings"
    ]

    func recordPersistenceFailure(_ key: String) { persistenceStore.recordFailure(key) }
    @ObservationIgnored private var lastSavedAutomation: AutomationSettings?
    @ObservationIgnored var onAutomationChanged: ((AutomationSettings) -> Void)?
    @ObservationIgnored private var changedHistoryKeys: Set<String> = []

    var refreshInterval: RefreshInterval
    var unreadReminderInterval: UnreadReminderInterval
    var unreadReminderSound: ReminderSound
    var notificationsEnabled: Bool
    var conversationDestination: AssistantContextLauncher.Destination
    var autoHandledEventBannersEnabled: Bool
    var lastSeenTodoIDs: Set<Int>
    var onboardingCompleted: Bool
    var glabPath: URL?
    var resolvedHost: String?
    var launchAtLoginPreference: Bool
    var lastMenuOpenedAt: Date?
    /// Managed MRs where the user turned off automatic approval.
    var autoApproveOptOuts: Set<MRAutomationScope.Target>
    var independentApprovalPreferences: [MRAutomationScope.Target: MRAutomationPreference]
    var autoPublishOptOuts: Set<MRAutomationScope.Target> = []
    var autoMergeOptOuts: Set<MRAutomationScope.Target> = []
    var autoMergeOptIns: Set<MRAutomationScope.Target> = []
    var automaticActionOptIns: [MRAutomaticAction: Set<MRAutomationScope.Target>] = [:]
    var mergeSubmissions: [MergeSubmissionReceipt] = []
    private var hiddenMergeRequests: HiddenMergeRequests
    var ignoredMergeRequests: Set<MRAutomationScope.Target> {
        get { hiddenMergeRequests.targets }
        set { hiddenMergeRequests.targets = newValue }
    }
    var hiddenReviewDetails: [MRAutomationScope.Target: HiddenReview] { hiddenMergeRequests.details }
    var filteredHiddenReviewDetails: [MRAutomationScope.Target: HiddenReview] {
        hiddenMergeRequests.details.filter { $0.value.manuallyHidden != true }
    }

    func intakeFilterHolds(_ target: MRAutomationScope.Target) -> Bool {
        reviewAssignments.incomingReviewFilter.suppresses(target)
            || hiddenMergeRequests.details[target].map { $0.manuallyHidden != true } == true
    }

    func hideReviewedMergeRequest(_ review: HiddenReview) -> Bool {
        var updated = hiddenMergeRequests
        guard updated.targets.insert(review.target).inserted else { return true }
        var hidden = review
        hidden.hideID = UUID()
        hidden.manuallyHidden = true
        updated.details[review.target] = hidden
        return saveHiddenMergeRequests(updated)
    }

    func hideFilteredReviews(_ reviews: [HiddenReview], reasons: [MRAutomationScope.Target: String] = [:]) -> Bool {
        var updated = hiddenMergeRequests
        let observedAt = Date()
        for var review in reviews {
            guard updated.targets.insert(review.target).inserted else { continue }
            review.hideID = UUID()
            review.inboxNotification = incomingReviewFilterSettings.showHiddenReviewsInInbox
                ? .init(id: UUID(), observedAt: observedAt, reason: reasons[review.target]) : nil
            updated.details[review.target] = review
        }
        guard updated.targets != hiddenMergeRequests.targets else { return false }
        return saveHiddenMergeRequests(updated)
    }

    func acknowledgeHiddenReviewNotifications(_ ids: Set<UUID>, host: String, username: String) -> Bool {
        var updated = hiddenMergeRequests
        let matching = updated.details.values.filter { review in
            review.target.host == host && review.target.username == username
                && review.inboxNotification.map { ids.contains($0.id) } == true
        }
        guard !matching.isEmpty else { return false }
        for review in matching { updated.details[review.target]?.inboxNotification = nil }
        return saveHiddenMergeRequests(updated)
    }

    func restoreHiddenReviews(_ targets: Set<MRAutomationScope.Target>) -> Bool {
        var updated = hiddenMergeRequests
        updated.targets.subtract(targets)
        guard updated.targets != hiddenMergeRequests.targets else { return false }
        return saveHiddenMergeRequests(updated)
    }

    private func saveHiddenMergeRequests(_ updated: HiddenMergeRequests) -> Bool {
        persistenceStore.preserveCorruptValues()
        guard persistenceStore.save(updated, forKey: Key.ignoredMergeRequests) else { return false }
        guard persistenceStore.synchronize() else {
            persistenceStore.save(hiddenMergeRequests, forKey: Key.ignoredMergeRequests)
            persistenceStore.synchronize()
            return false
        }
        hiddenMergeRequests = updated
        return true
    }
    var automation: AutomationSettings {
        didSet {
            if automation.isGloballySuspended == automationGloballyEnabled {
                automation.isGloballySuspended = !automationGloballyEnabled
            }
        }
    }
    /// The app-wide automation killswitch. It is stored apart from `automation`, so turning it off
    /// overrides presets and per-MR choices at runtime without changing them.
    private(set) var automationGloballyEnabled: Bool
    var confirmGlobalAutomationChanges: Bool
    var keepMacAwakeDuringAgentTasks: Bool
    /// New review candidates go straight to Reviewing (marked NEW) instead of waiting in the inbox.
    var addNewReviewsToReviewed: Bool
    /// Reviewing cards that arrived directly and have not been acted on yet.
    var newReviewTargets: Set<MRAutomationScope.Target> {
        didSet {
            for target in newReviewTargets.subtracting(oldValue) { newReviewGenerations[target] = UUID() }
            for target in oldValue.subtracting(newReviewTargets) { newReviewGenerations.removeValue(forKey: target) }
        }
    }
    // Invalidate older phone actions when a candidate becomes new again in the same host session.
    private(set) var newReviewGenerations: [MRAutomationScope.Target: UUID] = [:]
    /// New reviews whose automation MergeTether paused until the user starts them.
    var heldNewReviewTargets: Set<MRAutomationScope.Target>
    /// Automation as configured. Presentation reads this so the killswitch only stops execution
    /// and never changes how cards, menus or groupings look.
    var configuredAutomation: AutomationSettings { automation.ignoringGlobalSuspension }
    /// Whether the killswitch has any configured automation to control.
    var configuredAutomationAvailable: Bool {
        incomingReviewFilterSettings.activeCriteria != nil || configuredAutomation.hasEnabledAutomation
            || (configuredAutomation.hasAutomaticPublicActionConsent && hasAutomaticActionOptIn())
    }
    var automationGloballyActive: Bool { automationGloballyEnabled && configuredAutomationAvailable }
    var automationReceipts: Set<TodoAutomationReceipt>
    var automationAttemptReceipts: Set<TodoAutomationReceipt>
    var authorFeedbackAttempts: Set<AuthorFeedbackAttempt>
    var assistantAutomaticRetryAttempts: [AssistantAutomaticRetryAttempt] = []
    var feedbackSuggestionDecisions = FeedbackSuggestionDecisions()
    var reviewParticipationPreferences = ReviewParticipationPreferences()
    var pipelineRefreshAttempts: Set<PipelineRefreshAttempt>
    var pipelineClaimAssessmentAttempts: [PipelineClaimAssessmentAttempt]
    var pendingTodoAcknowledgements: Set<TodoActionAcknowledgement>
    var conflictReceipts: Set<MergeConflictReceipt>
    var reReviewReceipts: [ReReviewReceipt.Key: ReReviewReceipt]
    var reReviewDraftBaselines: [MRAutomationScope.Target: Int]
    var assistantHandoffs: [AssistantAutomationRunner.Handoff] {
        didSet { changedHistoryKeys.insert(Key.assistantHandoffs) }
    }
    var workflowActivity: [MergeWorkflowActivityEntry] {
        didSet { changedHistoryKeys.insert(Key.workflowActivity) }
    }
    var automationEvents: [MRAutomationEvent] {
        didSet { changedHistoryKeys.insert(Key.automationEvents) }
    }
    var mrActionIntents: [MRTodoIntent] {
        didSet { changedHistoryKeys.insert(Key.mrActionIntents) }
    }
    var routedMRTodoReceipts: Set<MRTodoRouteReceipt>
    var boardPins: Set<BoardCardPin>

    @discardableResult
    func setBoardPin(_ pin: BoardCardPin, pinned: Bool) -> Bool {
        var updated = boardPins
        if pinned { updated.insert(pin) } else { updated.remove(pin) }
        guard updated != boardPins else { return true }
        persistenceStore.preserveCorruptValues()
        guard persistenceStore.save(updated, forKey: Key.boardPins) else { return false }
        guard persistenceStore.synchronize() else {
            persistenceStore.save(boardPins, forKey: Key.boardPins)
            persistenceStore.synchronize()
            return false
        }
        boardPins = updated
        return true
    }
    var ownAutomationOffExpanded: Bool
    var reviewingAutomationOffExpanded: Bool
    var boardOrderingMethod: MRBoardOrderingMethod
    var promoteBoardAttention: Bool
    private(set) var boardManualOrder: MRBoardManualOrder
    var boardGrouping: MRBoardGrouping = .withoutAutomation
    var effectiveBoardGrouping: MRBoardGrouping { boardGrouping.effective(for: configuredAutomation) }
    var mrLifecycleLedger = MergeRequestLifecycleLedger()
    var reviewAssignments = ReviewAssignmentLedger()
    private(set) var incomingReviewFilterSettings = IncomingReviewFilterSettings()

    func acknowledgeLifecycleCompletion(id: UUID, host: String, username: String) -> Bool {
        var updated = mrLifecycleLedger
        guard updated.acknowledgeCompletion(id: id, host: host, username: username) else { return false }
        persistenceStore.preserveCorruptValues()
        guard persistenceStore.save(updated, forKey: Key.mrLifecycleLedger) else { return false }
        guard persistenceStore.synchronize() else {
            _ = persistenceStore.save(mrLifecycleLedger, forKey: Key.mrLifecycleLedger)
            _ = persistenceStore.synchronize()
            return false
        }
        mrLifecycleLedger = updated
        return true
    }

    @discardableResult
    func saveReviewAssignments(_ ledger: ReviewAssignmentLedger) -> Bool {
        persistenceStore.preserveCorruptValues()
        guard persistenceStore.save(ledger, forKey: Key.reviewAssignments), persistenceStore.synchronize() else { return false }
        reviewAssignments = ledger
        return true
    }

    @discardableResult
    func saveIncomingReviewFilterSettings(_ value: IncomingReviewFilterSettings) -> Bool {
        persistenceStore.preserveCorruptValues()
        guard persistenceStore.save(value, forKey: Key.incomingReviewFilterSettings) else { return false }
        guard persistenceStore.synchronize() else {
            persistenceStore.save(incomingReviewFilterSettings, forKey: Key.incomingReviewFilterSettings)
            persistenceStore.synchronize()
            return false
        }
        incomingReviewFilterSettings = value
        return true
    }

    @discardableResult
    func saveBoardManualOrder(_ order: MRBoardManualOrder) -> Bool {
        guard boardManualOrder != order else { return true }
        guard persistenceStore.save(order, forKey: Key.boardManualOrder) else { return false }
        boardManualOrder = order
        return true
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let store = DurableSettingsStore(defaults: defaults)
        persistenceStore = store
        automationProfileHistory = AutomationProfileHistoryStore(defaults: defaults)
        Self.registerDefaults(in: defaults)
        conversationDestination = defaults.string(forKey: Key.conversationDestination)
            .flatMap(AssistantContextLauncher.Destination.init(rawValue:)) ?? .codexApp

        var initialAutomation = AutomationSettings()
        initialAutomation.selectedAssistant = nil
        let loadedAutomation = store.load(Key.automation, fallback: initialAutomation)
        let globallyEnabled = defaults.bool(forKey: Key.automationGloballyEnabled)
        automationGloballyEnabled = globallyEnabled
        confirmGlobalAutomationChanges = defaults.bool(forKey: Key.confirmGlobalAutomationChanges)
        keepMacAwakeDuringAgentTasks = defaults.bool(forKey: Key.keepMacAwakeDuringAgentTasks)
        addNewReviewsToReviewed = defaults.bool(forKey: Key.addNewReviewsToReviewed)
        newReviewTargets = store.load(Key.newReviewTargets, fallback: [])
        heldNewReviewTargets = store.load(Key.heldNewReviewTargets, fallback: [])
        var runtimeAutomation = loadedAutomation
        runtimeAutomation.isGloballySuspended = !globallyEnabled
        automation = runtimeAutomation
        acceptedAutomation = loadedAutomation
        mergeSubmissions = store.load(Key.mergeSubmissions, fallback: [])
        automationReceipts = store.load(Key.automationReceipts, fallback: [])
        automationAttemptReceipts = store.load(Key.automationAttemptReceipts, fallback: [])
        authorFeedbackAttempts = store.load(Key.authorFeedbackAttempts, fallback: [])
        assistantAutomaticRetryAttempts = store.load(Key.assistantAutomaticRetryAttempts, fallback: [])
        feedbackSuggestionDecisions = store.load(Key.feedbackSuggestionDecisions, fallback: FeedbackSuggestionDecisions())
        reviewParticipationPreferences = store.load(Key.reviewParticipationPreferences, fallback: ReviewParticipationPreferences())
        pipelineRefreshAttempts = store.load(Key.pipelineRefreshAttempts, fallback: [])
        pipelineClaimAssessmentAttempts = store.load(Key.pipelineClaimAssessmentAttempts, fallback: [])
        pendingTodoAcknowledgements = store.load(Key.pendingTodoAcknowledgements, fallback: [])
        assistantHandoffs = store.load(Key.assistantHandoffs, fallback: [AssistantAutomationRunner.Handoff]())
            .filter { $0.execution != nil }
        workflowActivity = store.load(Key.workflowActivity, fallback: [MergeWorkflowActivityEntry]())
            .filter { $0.state != .waitingForAssistant || $0.assistantJobID != nil }
        automationEvents = store.load(Key.automationEvents, fallback: [])
        mrActionIntents = store.load(Key.mrActionIntents, fallback: [])
        routedMRTodoReceipts = store.load(Key.routedMRTodoReceipts, fallback: [])
        boardGrouping = defaults.string(forKey: Key.boardGrouping).flatMap(MRBoardGrouping.init(rawValue:)) ?? .withoutAutomation
        boardPins = store.load(Key.boardPins, fallback: [])
        ownAutomationOffExpanded = defaults.bool(forKey: Key.ownAutomationOffExpanded)
        reviewingAutomationOffExpanded = defaults.bool(forKey: Key.reviewingAutomationOffExpanded)
        boardOrderingMethod = defaults.string(forKey: Key.boardOrderingMethod).flatMap(MRBoardOrderingMethod.init(rawValue:)) ?? .manual
        promoteBoardAttention = defaults.bool(forKey: Key.promoteBoardAttention)
        boardManualOrder = store.load(Key.boardManualOrder, fallback: .init())
        mrLifecycleLedger = store.load(Key.mrLifecycleLedger, fallback: .init())
        reviewAssignments = store.load(Key.reviewAssignments, fallback: .init())
        incomingReviewFilterSettings = store.load(Key.incomingReviewFilterSettings, fallback: .init())
        conflictReceipts = store.load(Key.conflictReceipts, fallback: [])
        reReviewReceipts = store.load(Key.reReviewReceipts, fallback: [:])
        reReviewDraftBaselines = store.load(Key.reReviewDraftBaselines, fallback: [:])
        pendingCommentReviews = store.load(Key.pendingCommentReviews, fallback: [])
        commentReviewProgress = store.load(Key.commentReviewProgress, fallback: [:])

        let rawInterval = defaults.integer(forKey: Key.refreshInterval)
        self.refreshInterval = RefreshInterval(rawValue: rawInterval) ?? .fiveMinutes
        let rawReminderInterval = defaults.integer(forKey: Key.unreadReminderInterval)
        self.unreadReminderInterval = UnreadReminderInterval(rawValue: rawReminderInterval) ?? .fiveMinutes
        let rawReminderSound = defaults.string(forKey: Key.unreadReminderSound) ?? ReminderSound.off.rawValue
        self.unreadReminderSound = ReminderSound(rawValue: rawReminderSound) ?? .off
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        self.autoHandledEventBannersEnabled = defaults.bool(forKey: Key.autoHandledEventBannersEnabled)
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.launchAtLoginPreference = defaults.bool(forKey: Key.launchAtLoginPreference)
        self.resolvedHost = defaults.string(forKey: Key.resolvedHost)
        let storedMenuOpenedAt = defaults.double(forKey: Key.lastMenuOpenedAt)
        self.lastMenuOpenedAt = storedMenuOpenedAt > 0
            ? Date(timeIntervalSince1970: storedMenuOpenedAt)
            : nil

        self.hiddenMergeRequests = store.load(Key.ignoredMergeRequests, fallback: .init())
        self.autoApproveOptOuts = store.load(Key.autoApproveOptOuts, fallback: [])
        self.independentApprovalPreferences = store.load(Key.independentApprovalPreferences, fallback: [:])
        self.autoPublishOptOuts = store.load(Key.autoPublishOptOuts, fallback: [])
        self.autoMergeOptOuts = store.load(Key.autoMergeOptOuts, fallback: [])
        self.autoMergeOptIns = store.load(Key.autoMergeOptIns, fallback: [])
        self.automaticActionOptIns = store.load(Key.automaticActionOptIns, fallback: [:])

        if let pathString = defaults.string(forKey: Key.glabPath), !pathString.isEmpty {
            self.glabPath = URL(fileURLWithPath: pathString)
        } else {
            self.glabPath = nil
        }

        lastSeenTodoIDs = store.load(Key.lastSeenTodoIDs, fallback: [])
        for handoff in assistantHandoffs where handoff.execution?.state != .feedbackResolved {
            let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
            for (noteID, revision) in handoff.verifiedFeedbackNotes ?? [:] {
                authorFeedbackAttempts.insert(.init(target: target, noteID: noteID, revision: revision))
            }
        }
        lastSavedAutomation = automation
        mrLifecycleLedger.prepareFinishedRemoval()
    }

    @discardableResult
    func save() -> Bool {
        persistenceStore.preserveCorruptValues()
        persistenceStore.save(pendingCommentReviews, forKey: Key.pendingCommentReviews)
        persistenceStore.save(commentReviewProgress, forKey: Key.commentReviewProgress)
        defaults.set(conversationDestination.rawValue, forKey: Key.conversationDestination)
        let previousAutomation = lastSavedAutomation ?? automation
        let automationSaved = persistenceStore.save(automation, forKey: Key.automation)
        persistenceStore.save(automationReceipts, forKey: Key.automationReceipts)
        persistenceStore.save(automationAttemptReceipts, forKey: Key.automationAttemptReceipts)
        persistenceStore.save(authorFeedbackAttempts, forKey: Key.authorFeedbackAttempts)
        persistenceStore.save(assistantAutomaticRetryAttempts, forKey: Key.assistantAutomaticRetryAttempts)
        persistenceStore.save(feedbackSuggestionDecisions, forKey: Key.feedbackSuggestionDecisions)
        persistenceStore.save(reviewParticipationPreferences, forKey: Key.reviewParticipationPreferences)
        persistenceStore.save(pipelineRefreshAttempts, forKey: Key.pipelineRefreshAttempts)
        persistenceStore.save(pipelineClaimAssessmentAttempts, forKey: Key.pipelineClaimAssessmentAttempts)
        persistenceStore.save(pendingTodoAcknowledgements, forKey: Key.pendingTodoAcknowledgements)
        saveHistory(assistantHandoffs, forKey: Key.assistantHandoffs)
        saveHistory(workflowActivity, forKey: Key.workflowActivity)
        saveHistory(automationEvents, forKey: Key.automationEvents)
        saveHistory(mrActionIntents, forKey: Key.mrActionIntents)
        persistenceStore.save(routedMRTodoReceipts, forKey: Key.routedMRTodoReceipts)
        persistenceStore.save(boardPins, forKey: Key.boardPins)
        persistenceStore.save(boardManualOrder, forKey: Key.boardManualOrder)
        persistenceStore.save(mrLifecycleLedger, forKey: Key.mrLifecycleLedger)
        persistenceStore.save(reviewAssignments, forKey: Key.reviewAssignments)
        defaults.removeObject(forKey: Key.autoRemoveFinishedMRs)
        defaults.removeObject(forKey: Key.showMergedMRCompletions)
        defaults.removeObject(forKey: Key.showClosedMRCompletions)
        defaults.set(boardGrouping.rawValue, forKey: Key.boardGrouping)
        defaults.set(ownAutomationOffExpanded, forKey: Key.ownAutomationOffExpanded)
        defaults.set(reviewingAutomationOffExpanded, forKey: Key.reviewingAutomationOffExpanded)
        defaults.set(boardOrderingMethod.rawValue, forKey: Key.boardOrderingMethod)
        defaults.set(promoteBoardAttention, forKey: Key.promoteBoardAttention)
        persistenceStore.save(conflictReceipts, forKey: Key.conflictReceipts)
        persistenceStore.save(reReviewReceipts, forKey: Key.reReviewReceipts)
        persistenceStore.save(reReviewDraftBaselines, forKey: Key.reReviewDraftBaselines)
        defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        defaults.set(unreadReminderInterval.rawValue, forKey: Key.unreadReminderInterval)
        defaults.set(unreadReminderSound.rawValue, forKey: Key.unreadReminderSound)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(autoHandledEventBannersEnabled, forKey: Key.autoHandledEventBannersEnabled)
        defaults.set(confirmGlobalAutomationChanges, forKey: Key.confirmGlobalAutomationChanges)
        defaults.set(keepMacAwakeDuringAgentTasks, forKey: Key.keepMacAwakeDuringAgentTasks)
        defaults.set(addNewReviewsToReviewed, forKey: Key.addNewReviewsToReviewed)
        persistenceStore.save(newReviewTargets, forKey: Key.newReviewTargets)
        persistenceStore.save(heldNewReviewTargets, forKey: Key.heldNewReviewTargets)
        defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted)
        defaults.set(launchAtLoginPreference, forKey: Key.launchAtLoginPreference)
        if let glabPath {
            defaults.set(glabPath.path, forKey: Key.glabPath)
        } else {
            defaults.removeObject(forKey: Key.glabPath)
        }
        if let resolvedHost {
            defaults.set(resolvedHost, forKey: Key.resolvedHost)
        } else {
            defaults.removeObject(forKey: Key.resolvedHost)
        }
        persistenceStore.save(Array(lastSeenTodoIDs).sorted(), forKey: Key.lastSeenTodoIDs)
        if let lastMenuOpenedAt {
            defaults.set(lastMenuOpenedAt.timeIntervalSince1970, forKey: Key.lastMenuOpenedAt)
        } else {
            defaults.removeObject(forKey: Key.lastMenuOpenedAt)
        }
        persistenceStore.save(hiddenMergeRequests, forKey: Key.ignoredMergeRequests)
        persistenceStore.save(autoApproveOptOuts, forKey: Key.autoApproveOptOuts)
        let approvalPreferencesSaved = persistenceStore.save(independentApprovalPreferences, forKey: Key.independentApprovalPreferences)
        persistenceStore.save(autoPublishOptOuts, forKey: Key.autoPublishOptOuts)
        persistenceStore.save(mergeSubmissions, forKey: Key.mergeSubmissions)
        persistenceStore.save(autoMergeOptOuts, forKey: Key.autoMergeOptOuts)
        persistenceStore.save(autoMergeOptIns, forKey: Key.autoMergeOptIns)
        persistenceStore.save(automaticActionOptIns, forKey: Key.automaticActionOptIns)
        let synchronized = persistenceStore.synchronize()
        if !synchronized {
            changedHistoryKeys.formUnion([Key.assistantHandoffs, Key.workflowActivity,
                Key.automationEvents, Key.mrActionIntents])
        }
        let accepted = automationSaved && approvalPreferencesSaved && synchronized
        if accepted { acceptedAutomation = automation.ignoringGlobalSuspension }
        if automationSaved && synchronized {
            lastSavedAutomation = automation
            if previousAutomation != automation { onAutomationChanged?(previousAutomation) }
        }
        return accepted
    }

    private func saveHistory<Value: Encodable>(_ value: Value, forKey key: String) {
        if persistenceStore.save(value, forKey: key, changed: changedHistoryKeys.contains(key)) {
            changedHistoryKeys.remove(key)
        }
    }

    /// Turns the global automation killswitch on or off and stops or resumes automation accordingly.
    @discardableResult
    func setAutomationGloballyEnabled(_ enabled: Bool) -> Bool {
        guard enabled != automationGloballyEnabled else { return true }
        let previous = automation
        automationGloballyEnabled = enabled
        defaults.set(enabled, forKey: Key.automationGloballyEnabled)
        automation.isGloballySuspended = !enabled
        let saved = save()
        // A degraded store still has to stop or resume runtime work for the override.
        if !saved { onAutomationChanged?(previous) }
        return saved
    }

    func saveReviewParticipationPreferences() -> Bool {
        persistenceStore.preserveCorruptValues()
        let saved = persistenceStore.save(reviewParticipationPreferences, forKey: Key.reviewParticipationPreferences)
        let synchronized = persistenceStore.synchronize()
        return saved && synchronized
    }

    func removeReviewParticipationExclusion(_ id: UUID) -> Bool {
        let previous = reviewParticipationPreferences
        guard reviewParticipationPreferences.remove(id) else { return false }
        guard saveReviewParticipationPreferences() else {
            reviewParticipationPreferences = previous
            return false
        }
        return true
    }

    func markAutomationAuthor(_ identity: PublicationIdentity, host: String, user: GitLabAuthenticatedUser) -> Bool {
        var candidate = reviewParticipationPreferences
        guard candidate.markAutomationAuthor(identity, host: host, user: user) else { return false }
        return commitAutomationAuthorPreferences(candidate)
    }

    func unmarkAutomationAuthor(_ id: UUID, host: String, username: String) -> Bool {
        var candidate = reviewParticipationPreferences
        guard candidate.unmarkAutomationAuthor(id, host: host, username: username) else { return false }
        return commitAutomationAuthorPreferences(candidate)
    }

    private func commitAutomationAuthorPreferences(_ candidate: ReviewParticipationPreferences) -> Bool {
        persistenceStore.preserveCorruptValues()
        let saved = persistenceStore.save(candidate, forKey: Key.reviewParticipationPreferences)
        let synchronized = persistenceStore.synchronize()
        guard saved && synchronized else {
            if saved {
                // Restore the prior durable decision if synchronization rejected the new one.
                _ = persistenceStore.save(reviewParticipationPreferences, forKey: Key.reviewParticipationPreferences)
                _ = persistenceStore.synchronize()
            }
            return false
        }
        // Observers may authorize automation, so expose only a successfully saved decision.
        reviewParticipationPreferences = candidate
        return true
    }

    func saveMergeSubmission(_ receipt: MergeSubmissionReceipt) -> Bool {
        guard automaticActionsAllowed else { return false }
        mergeSubmissions.removeAll { $0.target == receipt.target }
        mergeSubmissions.append(receipt)
        save()
        return automaticActionsAllowed
    }

    /// A non-idempotent CI request must not outrun its replay guard on disk.
    func savePipelineRefreshAttempt(_ attempt: PipelineRefreshAttempt) -> Bool {
        guard automaticActionsAllowed else { return false }
        pipelineRefreshAttempts.insert(attempt)
        save()
        return automaticActionsAllowed
    }

    func savePipelineClaimAssessmentAttempt(_ attempt: PipelineClaimAssessmentAttempt) -> Bool {
        guard automaticActionsAllowed, !pipelineClaimAssessmentAttempts.contains(where: {
            $0.target == attempt.target && $0.userID == attempt.userID && $0.lineage == attempt.lineage
                && $0.pipelineID == attempt.pipelineID && $0.pipelineSHA == attempt.pipelineSHA
                && $0.pipelineProjectID == attempt.pipelineProjectID
                && $0.sourceProjectID == attempt.sourceProjectID && $0.sourceBranch == attempt.sourceBranch && $0.sourceSHA == attempt.sourceSHA
                && $0.targetProjectID == attempt.targetProjectID && $0.targetBranch == attempt.targetBranch && $0.targetSHA == attempt.targetSHA
        }) else { return false }
        pipelineClaimAssessmentAttempts.append(attempt)
        save()
        return automaticActionsAllowed
    }

    func saveEnvironmentRecoveryAttempt(_ id: UUID) -> Bool {
        guard automaticActionsAllowed, let index = assistantHandoffs.firstIndex(where: { $0.id == id }),
              assistantHandoffs[index].environmentRecoveryAttempted != true else { return false }
        assistantHandoffs[index].environmentRecoveryAttempted = true
        save()
        return automaticActionsAllowed
    }

    var isFirstLaunch: Bool {
        !defaults.bool(forKey: Key.hasLaunchedBefore)
    }

    func markLaunched() {
        defaults.set(true, forKey: Key.hasLaunchedBefore)
    }

    private static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            Key.refreshInterval: RefreshInterval.fiveMinutes.rawValue,
            Key.unreadReminderInterval: UnreadReminderInterval.fiveMinutes.rawValue,
            Key.unreadReminderSound: ReminderSound.off.rawValue,
            Key.notificationsEnabled: true,
            Key.autoHandledEventBannersEnabled: true,
            Key.automationGloballyEnabled: true,
            Key.confirmGlobalAutomationChanges: true,
            Key.keepMacAwakeDuringAgentTasks: true,
            Key.addNewReviewsToReviewed: true,
            Key.boardGrouping: MRBoardGrouping.withoutAutomation.rawValue,
            Key.ownAutomationOffExpanded: true,
            Key.reviewingAutomationOffExpanded: true,
            Key.boardOrderingMethod: MRBoardOrderingMethod.manual.rawValue,
            Key.promoteBoardAttention: true,
            Key.onboardingCompleted: false,
            Key.launchAtLoginPreference: true,
            Key.hasLaunchedBefore: false,
        ])
    }

    private enum Key {
        static let conversationDestination = "conversationDestination"
        static let automation = "automation"
        static let automationGloballyEnabled = "automationGloballyEnabled"
        static let confirmGlobalAutomationChanges = "confirmGlobalAutomationChanges"
        static let keepMacAwakeDuringAgentTasks = "keepMacAwakeDuringAgentTasks"
        static let addNewReviewsToReviewed = "addNewReviewsToReviewed"
        static let newReviewTargets = "newReviewTargets"
        static let heldNewReviewTargets = "heldNewReviewTargets"
        static let automationReceipts = "automationReceipts"
        static let automationAttemptReceipts = "automationAttemptReceipts"
        static let authorFeedbackAttempts = "authorFeedbackAttempts"
        static let assistantAutomaticRetryAttempts = "assistantAutomaticRetryAttempts"
        static let pipelineRefreshAttempts = "pipelineRefreshAttempts"
        static let pipelineClaimAssessmentAttempts = "pipelineClaimAssessmentAttempts"
        static let pendingTodoAcknowledgements = "pendingTodoAcknowledgements"
        static let boardPins = "boardPins"
        static let boardGrouping = "boardGrouping"
        static let ownAutomationOffExpanded = "board.own.automationOffExpanded"
        static let reviewingAutomationOffExpanded = "board.reviewing.automationOffExpanded"
        static let boardOrderingMethod = "boardOrderingMethod"
        static let promoteBoardAttention = "promoteBoardAttention"
        static let boardManualOrder = "boardManualOrder"
        static let mrLifecycleLedger = "mrLifecycleLedger"
        static let reviewAssignments = "reviewAssignments"
        static let incomingReviewFilterSettings = "incomingReviewFilterSettings"
        static let autoRemoveFinishedMRs = "autoRemoveFinishedMRs"
        static let showMergedMRCompletions = "showMergedMRCompletions"
        static let showClosedMRCompletions = "showClosedMRCompletions"
        static let conflictReceipts = "conflictReceipts"
        static let reReviewReceipts = "reReviewReceipts"
        static let reReviewDraftBaselines = "reReviewDraftBaselines"
        static let pendingCommentReviews = "pendingCommentReviews"
        static let commentReviewProgress = "commentReviewProgress"
        static let assistantHandoffs = "assistantHandoffs"
        static let workflowActivity = "workflowActivity"
        static let automationEvents = "automationEvents"
        static let mrActionIntents = "mrActionIntents"
        static let routedMRTodoReceipts = "routedMRTodoReceipts"
        static let refreshInterval = "refreshInterval"
        static let unreadReminderInterval = "unreadReminderInterval"
        static let unreadReminderSound = "unreadReminderSound"
        static let notificationsEnabled = "notificationsEnabled"
        static let autoHandledEventBannersEnabled = "autoHandledEventBannersEnabled"
        static let lastSeenTodoIDs = "lastSeenTodoIDs"
        static let onboardingCompleted = "onboardingCompleted"
        static let glabPath = "glabPath"
        static let resolvedHost = "resolvedHost"
        static let launchAtLoginPreference = "launchAtLoginPreference"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let lastMenuOpenedAt = "lastMenuOpenedAt"
        static let autoApproveOptOuts = "autoApproveOptOuts"
        static let independentApprovalPreferences = "independentApprovalPreferences"
        static let autoPublishOptOuts = "autoPublishOptOuts"
        static let mergeSubmissions = "mergeSubmissions"
        static let autoMergeOptOuts = "autoMergeOptOuts"
        static let autoMergeOptIns = "autoMergeOptIns"
        static let automaticActionOptIns = "automaticActionOptIns"
        static let ignoredMergeRequests = "ignoredMergeRequests"
        static let feedbackSuggestionDecisions = "feedbackSuggestionDecisions"
        static let reviewParticipationPreferences = "reviewParticipationPreferences"
    }
}
