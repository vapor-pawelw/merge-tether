import Foundation
import Observation

@MainActor
@Observable
final class SettingsManager {
    var pendingCommentReviews: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.pendingCommentReviews) }
    }
    var commentReviewProgress: [MRAutomationScope.Target: CommentReviewProgress] = [:] {
        didSet { changedMRKeys.insert(Key.commentReviewProgress) }
    }
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
    @ObservationIgnored private var changedMRKeys: Set<String> = []
    @ObservationIgnored private var mrSettingsArchive = MRSettingsArchive()

    func approvalBaseline(for target: MRAutomationScope.Target, user: GitLabAuthenticatedUser) -> ReviewApprovalBaseline? {
        guard let key = MRSettingsKey(target), target.username == user.username else { return nil }
        return mrSettingsArchive.records[key]?.reviewerApprovals?.first { $0.user == user }?.baseline
    }

    @discardableResult
    func setApprovalBaseline(_ baseline: ReviewApprovalBaseline?, for target: MRAutomationScope.Target,
                             user: GitLabAuthenticatedUser) -> Bool {
        guard let key = MRSettingsKey(target), user.id > 0, target.username == user.username,
              approvalBaseline(for: target, user: user) != baseline else { return false }
        var approvals = mrSettingsArchive.records[key]?.reviewerApprovals ?? []
        approvals.removeAll { $0.user == user }
        if let baseline { approvals.append(.init(user: user, baseline: baseline)) }
        mrSettingsArchive.setReviewerApprovals(approvals, for: key)
        changedMRKeys.insert(Key.reviewerApprovals)
        return true
    }

    func approvalBaselineTargets(host: String, user: GitLabAuthenticatedUser) -> Set<MRAutomationScope.Target> {
        Set(mrSettingsArchive.records.compactMap { key, record in
            guard key.host == host, record.reviewerApprovals?.contains(where: { $0.user == user }) == true else { return nil }
            return .mergeRequest(host: host, username: user.username, projectID: key.request.projectID, iid: key.request.iid)
        })
    }

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
    var autoApproveOptOuts: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.autoApproveOptOuts) }
    }
    var independentApprovalPreferences: [MRAutomationScope.Target: MRAutomationPreference] = [:] {
        didSet { changedMRKeys.insert(Key.independentApprovalPreferences) }
    }
    var autoPublishOptOuts: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.autoPublishOptOuts) }
    }
    var autoMergeOptOuts: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.autoMergeOptOuts) }
    }
    var autoMergeOptIns: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.autoMergeOptIns) }
    }
    var automaticActionOptIns: [MRAutomaticAction: Set<MRAutomationScope.Target>] = [:] {
        didSet { changedMRKeys.insert(Key.automaticActionOptIns) }
    }
    var mergeSubmissions: [MergeSubmissionReceipt] = [] {
        didSet { changedMRKeys.insert(Key.mergeSubmissions) }
    }
    private var hiddenMergeRequests: HiddenMergeRequests = .init() {
        didSet { changedMRKeys.insert(Key.ignoredMergeRequests) }
    }
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

    func hideReviewedMergeRequest(_ review: HiddenReview, now: Date = .now) -> Bool {
        var updated = hiddenMergeRequests
        guard updated.targets.insert(review.target).inserted else { return true }
        var hidden = review
        hidden.hideID = UUID()
        hidden.manuallyHidden = true
        hidden.restoreUntil = now.addingTimeInterval(HiddenReview.restorationInterval)
        updated.details[review.target] = hidden
        return saveHiddenMergeRequests(updated)
    }

    func hideFilteredReviews(_ reviews: [HiddenReview], reasons: [MRAutomationScope.Target: String] = [:],
                             now: Date = .now) -> Bool {
        var updated = hiddenMergeRequests
        for var review in reviews {
            guard updated.targets.insert(review.target).inserted else { continue }
            review.hideID = UUID()
            review.restoreUntil = now.addingTimeInterval(HiddenReview.restorationInterval)
            review.inboxNotification = incomingReviewFilterSettings.showHiddenReviewsInInbox
                ? .init(id: UUID(), observedAt: now, reason: reasons[review.target]) : nil
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

    func canRestoreHiddenReview(_ target: MRAutomationScope.Target, now: Date = .now) -> Bool {
        guard hiddenMergeRequests.targets.contains(target),
              let deadline = hiddenMergeRequests.details[target]?.restoreUntil ?? hiddenMergeRequests.legacyRestoreUntil,
              now < deadline else { return false }
        return MergeRequestFinishedState(mrLifecycleLedger.request(for: target)) == nil
    }

    func retireFinishedHiddenReview(_ target: MRAutomationScope.Target, request: GitLabMergeRequest,
                                    hideID: UUID?, now: Date = .now) {
        guard MergeRequestFinishedState(request) != nil, canRestoreHiddenReview(target, now: now),
              hiddenMergeRequests.details[target]?.hideID == hideID else { return }
        var updated = hiddenMergeRequests
        var review = updated.details[target] ?? .init(target: target, title: request.title, url: request.webURL,
                                                      manuallyHidden: true)
        review.restoreUntil = .distantPast
        review.inboxNotification = nil
        updated.details[target] = review
        _ = saveHiddenMergeRequests(updated)
    }

    func restoreHiddenReviews(_ targets: Set<MRAutomationScope.Target>, now: Date = .now) -> Bool {
        var updated = hiddenMergeRequests
        updated.targets.subtract(targets.filter { canRestoreHiddenReview($0, now: now) })
        guard updated.targets != hiddenMergeRequests.targets else { return false }
        return saveHiddenMergeRequests(updated)
    }

    private func saveHiddenMergeRequests(_ updated: HiddenMergeRequests) -> Bool {
        guard saveMRPreference(.hiddenReviews(updated), replacing: .hiddenReviews(hiddenMergeRequests)) else { return false }
        hiddenMergeRequests = updated
        changedMRKeys.remove(Key.ignoredMergeRequests)
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
    var treatSoleAssigneeAsOwn: Bool

    func owns(_ request: GitLabMergeRequest, userID: Int) -> Bool {
        request.isOwned(by: userID, includingSoleAssignee: treatSoleAssigneeAsOwn)
    }

    func owns(_ request: GitLabMergeRequest, username: String) -> Bool {
        ownerID(of: request, username: username) != nil
    }

    func ownerID(of request: GitLabMergeRequest, username: String) -> Int? {
        if request.author.username == username { return request.author.id }
        guard treatSoleAssigneeAsOwn, let assignee = request.soleAssignee, assignee.username == username else { return nil }
        return assignee.id
    }
    /// Reviewing cards that arrived directly and have not been acted on yet.
    var newReviewTargets: Set<MRAutomationScope.Target> = [] {
        didSet {
            changedMRKeys.insert(Key.newReviewTargets)
            for target in newReviewTargets.subtracting(oldValue) { newReviewGenerations[target] = UUID() }
            for target in oldValue.subtracting(newReviewTargets) { newReviewGenerations.removeValue(forKey: target) }
        }
    }
    // Invalidate older phone actions when a candidate becomes new again in the same host session.
    private(set) var newReviewGenerations: [MRAutomationScope.Target: UUID] = [:]
    /// New reviews whose automation MergeTether paused until the user starts them.
    var heldNewReviewTargets: Set<MRAutomationScope.Target> = [] {
        didSet { changedMRKeys.insert(Key.heldNewReviewTargets) }
    }
    /// Automation as configured. Presentation reads this so the killswitch only stops execution
    /// and never changes how cards, menus or groupings look.
    var configuredAutomation: AutomationSettings { automation.ignoringGlobalSuspension }
    /// Whether the killswitch has any configured automation to control.
    var configuredAutomationAvailable: Bool {
        incomingReviewFilterSettings.activeCriteria != nil || configuredAutomation.hasEnabledAutomation
            || (configuredAutomation.hasAutomaticPublicActionConsent && hasAutomaticActionOptIn())
    }
    var automationGloballyActive: Bool { automationGloballyEnabled && configuredAutomationAvailable }
    var automationReceipts: Set<TodoAutomationReceipt> = [] {
        didSet { changedMRKeys.insert(Key.automationReceipts) }
    }
    var automationAttemptReceipts: Set<TodoAutomationReceipt> = [] {
        didSet { changedMRKeys.insert(Key.automationAttemptReceipts) }
    }
    var authorFeedbackAttempts: Set<AuthorFeedbackAttempt> = [] {
        didSet { changedMRKeys.insert(Key.authorFeedbackAttempts) }
    }
    var assistantAutomaticRetryAttempts: [AssistantAutomaticRetryAttempt] = [] {
        didSet { changedMRKeys.insert(Key.assistantAutomaticRetryAttempts) }
    }
    var feedbackSuggestionDecisions = FeedbackSuggestionDecisions()
    var reviewParticipationPreferences = ReviewParticipationPreferences()
    var pipelineRefreshAttempts: Set<PipelineRefreshAttempt> = [] {
        didSet { changedMRKeys.insert(Key.pipelineRefreshAttempts) }
    }
    var pipelineClaimAssessmentAttempts: [PipelineClaimAssessmentAttempt] = [] {
        didSet { changedMRKeys.insert(Key.pipelineClaimAssessmentAttempts) }
    }
    var pendingTodoAcknowledgements: Set<TodoActionAcknowledgement> = [] {
        didSet { changedMRKeys.insert(Key.pendingTodoAcknowledgements) }
    }
    var conflictReceipts: Set<MergeConflictReceipt> = [] {
        didSet { changedMRKeys.insert(Key.conflictReceipts) }
    }
    var reReviewReceipts: [ReReviewReceipt.Key: ReReviewReceipt] = [:] {
        didSet { changedMRKeys.insert(Key.reReviewReceipts) }
    }
    var reReviewDraftBaselines: [MRAutomationScope.Target: Int] = [:] {
        didSet { changedMRKeys.insert(Key.reReviewDraftBaselines) }
    }
    var assistantHandoffs: [AssistantAutomationRunner.Handoff] = [] {
        didSet { changedMRKeys.insert(Key.assistantHandoffs) }
    }
    var workflowActivity: [MergeWorkflowActivityEntry] = [] {
        didSet { changedMRKeys.insert(Key.workflowActivity) }
    }
    var automationEvents: [MRAutomationEvent] = [] {
        didSet { changedMRKeys.insert(Key.automationEvents) }
    }
    var mrActionIntents: [MRTodoIntent] = [] {
        didSet { changedMRKeys.insert(Key.mrActionIntents) }
    }
    var routedMRTodoReceipts: Set<MRTodoRouteReceipt> = [] {
        didSet { changedMRKeys.insert(Key.routedMRTodoReceipts) }
    }
    var boardPins: Set<BoardCardPin> = [] {
        didSet { changedMRKeys.insert(Key.boardPins) }
    }

    @discardableResult
    func setBoardPin(_ pin: BoardCardPin, pinned: Bool) -> Bool {
        var updated = boardPins
        if pinned { updated.insert(pin) } else { updated.remove(pin) }
        guard updated != boardPins else { return true }
        guard saveMRPreference(.boardPins(updated), replacing: .boardPins(boardPins)) else { return false }
        boardPins = updated
        changedMRKeys.remove(Key.boardPins)
        return true
    }
    var ownAutomationOffExpanded: Bool
    var reviewingAutomationOffExpanded: Bool
    var boardOrderingMethod: MRBoardOrderingMethod
    var promoteBoardAttention: Bool
    var findMergeRequestIssues: Bool
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

    init(defaults: UserDefaults = .standard, now: Date = .now) {
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
        treatSoleAssigneeAsOwn = defaults.bool(forKey: Key.treatSoleAssigneeAsOwn)
        var runtimeAutomation = loadedAutomation
        runtimeAutomation.isGloballySuspended = !globallyEnabled
        automation = runtimeAutomation
        acceptedAutomation = loadedAutomation
        feedbackSuggestionDecisions = store.load(Key.feedbackSuggestionDecisions, fallback: FeedbackSuggestionDecisions())
        reviewParticipationPreferences = store.load(Key.reviewParticipationPreferences, fallback: ReviewParticipationPreferences())
        boardGrouping = defaults.string(forKey: Key.boardGrouping).flatMap(MRBoardGrouping.init(rawValue:)) ?? .withoutAutomation
        ownAutomationOffExpanded = defaults.bool(forKey: Key.ownAutomationOffExpanded)
        reviewingAutomationOffExpanded = defaults.bool(forKey: Key.reviewingAutomationOffExpanded)
        boardOrderingMethod = defaults.string(forKey: Key.boardOrderingMethod).flatMap(MRBoardOrderingMethod.init(rawValue:)) ?? .manual
        promoteBoardAttention = defaults.bool(forKey: Key.promoteBoardAttention)
        findMergeRequestIssues = defaults.bool(forKey: Key.findMergeRequestIssues)
        boardManualOrder = store.load(Key.boardManualOrder, fallback: .init())
        mrLifecycleLedger = store.load(Key.mrLifecycleLedger, fallback: .init())
        reviewAssignments = store.load(Key.reviewAssignments, fallback: .init())
        incomingReviewFilterSettings = store.load(Key.incomingReviewFilterSettings, fallback: .init())

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


        if let pathString = defaults.string(forKey: Key.glabPath), !pathString.isEmpty {
            self.glabPath = URL(fileURLWithPath: pathString)
        } else {
            self.glabPath = nil
        }

        lastSeenTodoIDs = store.load(Key.lastSeenTodoIDs, fallback: [])
        mrSettingsArchive = store.load(Key.mergeRequestRecords, fallback: .init())
        transferMRSettings(.load)
        changedMRKeys.removeAll()
        let jobs = assistantHandoffs.filter { $0.execution != nil }
        if jobs.count != assistantHandoffs.count { assistantHandoffs = jobs }
        let acceptedActivity = workflowActivity.filter { $0.state != .waitingForAssistant || $0.assistantJobID != nil }
        if acceptedActivity.count != workflowActivity.count { workflowActivity = acceptedActivity }
        newReviewGenerations = Dictionary(mrSettingsArchive.values(\.newReviewGenerations).compactMap { entry in
            newReviewTargets.contains(entry.target) ? (entry.target, entry.value) : nil
        }, uniquingKeysWith: { first, _ in first })
        for handoff in assistantHandoffs where handoff.execution?.state != .feedbackResolved {
            let target = handoff.key.automationTarget
            for (noteID, revision) in handoff.verifiedFeedbackNotes ?? [:] {
                authorFeedbackAttempts.insert(.init(target: target, noteID: noteID, revision: revision))
            }
        }
        lastSavedAutomation = automation
        mrLifecycleLedger.prepareFinishedRemoval()
        var migratedHides = hiddenMergeRequests
        if migratedHides.migrateRestorationDeadlines(now: now) {
            // Preserve the one-time upgrade window even if the app quits before its first settings save.
            persistenceStore.preserveCorruptValues()
            if persistenceStore.save(migratedHides, forKey: Key.ignoredMergeRequests), !persistenceStore.synchronize() {
                persistenceStore.save(hiddenMergeRequests, forKey: Key.ignoredMergeRequests)
                persistenceStore.synchronize()
            }
            hiddenMergeRequests = migratedHides
        }
    }

    @discardableResult
    func save() -> Bool {
        persistenceStore.preserveCorruptValues()
        defaults.set(conversationDestination.rawValue, forKey: Key.conversationDestination)
        let previousAutomation = lastSavedAutomation ?? automation
        let automationSaved = persistenceStore.save(automation, forKey: Key.automation)
        persistenceStore.save(feedbackSuggestionDecisions, forKey: Key.feedbackSuggestionDecisions)
        persistenceStore.save(reviewParticipationPreferences, forKey: Key.reviewParticipationPreferences)
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
        defaults.set(findMergeRequestIssues, forKey: Key.findMergeRequestIssues)
        defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        defaults.set(unreadReminderInterval.rawValue, forKey: Key.unreadReminderInterval)
        defaults.set(unreadReminderSound.rawValue, forKey: Key.unreadReminderSound)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(autoHandledEventBannersEnabled, forKey: Key.autoHandledEventBannersEnabled)
        defaults.set(confirmGlobalAutomationChanges, forKey: Key.confirmGlobalAutomationChanges)
        defaults.set(keepMacAwakeDuringAgentTasks, forKey: Key.keepMacAwakeDuringAgentTasks)
        defaults.set(addNewReviewsToReviewed, forKey: Key.addNewReviewsToReviewed)
        defaults.set(treatSoleAssigneeAsOwn, forKey: Key.treatSoleAssigneeAsOwn)
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
        let recordsSaved = transferMRSettings(.save)
        let synchronized = persistenceStore.synchronize()
        if !synchronized {
            changedMRKeys.formUnion([Key.assistantHandoffs, Key.workflowActivity,
                Key.automationEvents, Key.mrActionIntents])
        }
        let accepted = automationSaved && recordsSaved && synchronized
        if accepted { acceptedAutomation = automation.ignoringGlobalSuspension }
        if automationSaved && synchronized {
            lastSavedAutomation = automation
            if previousAutomation != automation { onAutomationChanged?(previousAutomation) }
        }
        return accepted
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
            Key.treatSoleAssigneeAsOwn: true,
            Key.boardGrouping: MRBoardGrouping.withoutAutomation.rawValue,
            Key.ownAutomationOffExpanded: true,
            Key.reviewingAutomationOffExpanded: true,
            Key.boardOrderingMethod: MRBoardOrderingMethod.manual.rawValue,
            Key.promoteBoardAttention: true,
            Key.findMergeRequestIssues: true,
            Key.onboardingCompleted: false,
            Key.launchAtLoginPreference: true,
            Key.hasLaunchedBefore: false,
        ])
    }

    private enum Key {
        static let mergeRequestRecords = "mergeRequestRecords"
        static let reviewerApprovals = "reviewerApprovals"
        static let conversationDestination = "conversationDestination"
        static let automation = "automation"
        static let automationGloballyEnabled = "automationGloballyEnabled"
        static let confirmGlobalAutomationChanges = "confirmGlobalAutomationChanges"
        static let keepMacAwakeDuringAgentTasks = "keepMacAwakeDuringAgentTasks"
        static let addNewReviewsToReviewed = "addNewReviewsToReviewed"
        static let treatSoleAssigneeAsOwn = "treatSoleAssigneeAsOwn"
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
        static let findMergeRequestIssues = "findMergeRequestIssues"
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

extension SettingsManager {
    private enum MRSettingsPreference {
        case hiddenReviews(HiddenMergeRequests)
        case boardPins(Set<BoardCardPin>)

        var key: String {
            switch self {
            case .hiddenReviews: Key.ignoredMergeRequests
            case .boardPins: Key.boardPins
            }
        }
    }

    private enum MRSettingsTransfer {
        case load
        case save
        case savePreference(MRSettingsPreference)
    }

    private func saveMRPreference(_ value: MRSettingsPreference, replacing previous: MRSettingsPreference) -> Bool {
        persistenceStore.preserveCorruptValues()
        guard transferMRSettings(.savePreference(value)), persistenceStore.synchronize() else {
            _ = transferMRSettings(.savePreference(previous))
            _ = persistenceStore.synchronize()
            return false
        }
        return true
    }

    /// The existing collections are indexes for callers that filter by account, MR or work ID.
    /// Update their persisted records and the downgrade mirrors together at explicit save points.
    @discardableResult
    private func transferMRSettings(_ transfer: MRSettingsTransfer) -> Bool {
        typealias Record = MRSettingsRecord
        typealias Target = MRAutomationScope.Target
        var archive = mrSettingsArchive
        var updatedKeys = Set<String>()
        var failedKeys = Set<String>()
        var candidateHides: HiddenMergeRequests?
        var candidatePins: Set<BoardCardPin>?
        if case let .savePreference(preference) = transfer {
            switch preference {
            case .hiddenReviews(let value): candidateHides = value
            case .boardPins(let value): candidatePins = value
            }
        }

        func field<Value: Codable, Element>(
            _ path: ReferenceWritableKeyPath<SettingsManager, Value>,
            _ field: WritableKeyPath<Record, [Element]?>, _ key: String,
            candidate: Value? = nil, repartition: Bool = false,
            split: (Value) -> [Element], combine: ([Element]) -> Value,
            restorePayload: (Value, Value) -> Value = { value, _ in value },
            scope: (Element) -> MRSettingsKey?
        ) {
            switch transfer {
            case .load:
                let legacy = persistenceStore.load(key, fallback: self[keyPath: path])
                let fingerprint = persistenceStore.savedFingerprint(forKey: key)
                if let previous = archive.mirrorFingerprints[key], fingerprint == nil || fingerprint == previous {
                    self[keyPath: path] = restorePayload(combine(archive.values(field)), legacy)
                } else {
                    self[keyPath: path] = legacy
                }
            case .save, .savePreference:
                if case .savePreference(let selected) = transfer, key != selected.key { return }
                let changed = candidate != nil || changedMRKeys.contains(key)
                let value = candidate ?? self[keyPath: path]
                guard persistenceStore.save(value, forKey: key, changed: changed),
                      let fingerprint = persistenceStore.savedFingerprint(forKey: key) else {
                    failedKeys.insert(key)
                    return
                }
                guard changed || repartition || archive.mirrorFingerprints[key] != fingerprint else { return }
                archive.replace(field, with: split(value), keyedBy: scope)
                archive.mirrorFingerprints[key] = fingerprint
                updatedKeys.insert(key)
            }
        }

        func targets(_ path: ReferenceWritableKeyPath<SettingsManager, Set<Target>>,
                     _ value: WritableKeyPath<Record, [Target]?>, _ key: String) {
            field(path, value, key, split: Array.init, combine: Set.init, scope: MRSettingsKey.init)
        }

        func scoped<Value: Codable & Sendable>(_ path: ReferenceWritableKeyPath<SettingsManager, [Target: Value]>,
                                    _ value: WritableKeyPath<Record, [Record.Scoped<Value>]?>, _ key: String) {
            field(path, value, key, split: { $0.map { .init(target: $0.key, value: $0.value) } },
                combine: { Dictionary($0.map { ($0.target, $0.value) }, uniquingKeysWith: { first, _ in first }) },
                scope: { MRSettingsKey($0.target) })
        }

        func ordered<Value: Codable>(_ path: ReferenceWritableKeyPath<SettingsManager, [Value]>,
                                      _ value: WritableKeyPath<Record, [Record.Ordered<Value>]?>, _ key: String,
                                      scope: (Value) -> MRSettingsKey?) {
            field(path, value, key, split: { $0.enumerated().map { .init(position: $0.offset, value: $0.element) } },
                combine: { $0.sorted { $0.position < $1.position }.map(\.value) }, scope: { scope($0.value) })
        }

        func targetSet<Value: Codable & Hashable>(_ path: ReferenceWritableKeyPath<SettingsManager, Set<Value>>,
                                                   _ value: WritableKeyPath<Record, [Value]?>, _ key: String,
                                                   target: KeyPath<Value, Target>) {
            field(path, value, key, split: Array.init, combine: Set.init, scope: { MRSettingsKey($0[keyPath: target]) })
        }

        targets(\.autoApproveOptOuts, \.autoApproveOptOuts, Key.autoApproveOptOuts)
        scoped(\.independentApprovalPreferences, \.independentApprovalPreferences, Key.independentApprovalPreferences)
        targets(\.autoPublishOptOuts, \.autoPublishOptOuts, Key.autoPublishOptOuts)
        targets(\.autoMergeOptOuts, \.autoMergeOptOuts, Key.autoMergeOptOuts)
        targets(\.autoMergeOptIns, \.autoMergeOptIns, Key.autoMergeOptIns)
        let emptyActionOptIns = archive.emptyActionOptIns ?? []
        field(\.automaticActionOptIns, \.automaticActionOptIns, Key.automaticActionOptIns,
            split: { actions in actions.flatMap { action, targets in targets.map { .init(action: action, target: $0) } } },
            combine: { entries in
                var result = Dictionary(uniqueKeysWithValues: emptyActionOptIns.map { ($0, Set<Target>()) })
                for entry in entries { result[entry.action, default: []].insert(entry.target) }
                return result
            }, scope: { MRSettingsKey($0.target) })
        ordered(\.mergeSubmissions, \.mergeSubmissions, Key.mergeSubmissions, scope: { MRSettingsKey($0.target) })
        let legacyHideDeadline = archive.legacyHideDeadline
        field(\.hiddenMergeRequests, \.hiddenReviews, Key.ignoredMergeRequests, candidate: candidateHides,
            split: { hides in hides.targets.map { .init(target: $0, detail: hides.details[$0]) } },
            combine: { entries in
                var hides = HiddenMergeRequests()
                hides.targets = Set(entries.map(\.target))
                hides.details = Dictionary(entries.compactMap { entry in entry.detail.map { (entry.target, $0) } },
                    uniquingKeysWith: { first, _ in first })
                hides.legacyRestoreUntil = legacyHideDeadline
                return hides
            }, scope: { MRSettingsKey($0.target) })
        targets(\.newReviewTargets, \.newReviewTargets, Key.newReviewTargets)
        targets(\.heldNewReviewTargets, \.heldNewReviewTargets, Key.heldNewReviewTargets)
        targetSet(\.authorFeedbackAttempts, \.authorFeedbackAttempts, Key.authorFeedbackAttempts, target: \.target)
        ordered(\.assistantAutomaticRetryAttempts, \.assistantAutomaticRetryAttempts, Key.assistantAutomaticRetryAttempts,
            scope: { MRSettingsKey(host: $0.target.host, projectID: $0.target.projectID, iid: $0.target.iid) })
        targetSet(\.pipelineRefreshAttempts, \.pipelineRefreshAttempts, Key.pipelineRefreshAttempts, target: \.target)
        ordered(\.pipelineClaimAssessmentAttempts, \.pipelineClaimAssessmentAttempts, Key.pipelineClaimAssessmentAttempts,
            scope: { MRSettingsKey($0.target) })
        field(\.conflictReceipts, \.conflictReceipts, Key.conflictReceipts, split: Array.init, combine: Set.init,
            scope: { MRSettingsKey(host: $0.host, projectID: $0.projectID, iid: $0.iid) })
        field(\.reReviewReceipts, \.reReviewReceipts, Key.reReviewReceipts,
            split: { $0.map { .init(key: $0.key, value: $0.value) } },
            combine: { Dictionary($0.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }) },
            scope: { MRSettingsKey(host: $0.key.host, projectID: $0.key.projectID, iid: $0.key.iid) })
        scoped(\.reReviewDraftBaselines, \.reReviewDraftBaselines, Key.reReviewDraftBaselines)
        field(\.assistantHandoffs, \.assistantHandoffs, Key.assistantHandoffs,
            split: { jobs in
                jobs.enumerated().map { index, job in
                    // The compatibility key already holds successful display transcripts.
                    var record = job
                    if record.execution?.state == .succeeded { record.execution?.output = nil }
                    return .init(position: index, value: record)
                }
            },
            combine: { $0.sorted { $0.position < $1.position }.map(\.value) },
            restorePayload: { jobs, compatibilityJobs in
                let byID = Dictionary(compatibilityJobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                return jobs.map { job in
                    guard job.execution?.state == .succeeded, let previous = byID[job.id],
                          previous.key == job.key, previous.execution?.state == .succeeded else { return job }
                    var restored = job
                    restored.execution?.output = previous.execution?.output
                    return restored
                }
            }, scope: { MRSettingsKey($0.value.key.automationTarget) })
        ordered(\.workflowActivity, \.workflowActivity, Key.workflowActivity, scope: {
            let request = $0.event.mergeRequest
            return MRSettingsKey(host: $0.host, projectID: request.projectID, iid: request.iid)
        })
        ordered(\.automationEvents, \.automationEvents, Key.automationEvents, scope: { MRSettingsKey($0.target) })
        ordered(\.mrActionIntents, \.mrActionIntents, Key.mrActionIntents, scope: { MRSettingsKey($0.target) })
        targetSet(\.routedMRTodoReceipts, \.routedMRTodoReceipts, Key.routedMRTodoReceipts, target: \.target)
        let todoTargets = Dictionary(grouping: routedMRTodoReceipts) {
            TodoAutomationReceipt(host: $0.target.host, username: $0.target.username, todoID: $0.event.id)
        }.compactMapValues { routes -> MRSettingsKey? in
            let targets = Set(routes.map(\.target))
            guard targets.count == 1, let target = targets.first else { return nil }
            return MRSettingsKey(target)
        }
        let routesChanged = updatedKeys.contains(Key.routedMRTodoReceipts)
        field(\.automationReceipts, \.automationReceipts, Key.automationReceipts, repartition: routesChanged,
            split: Array.init, combine: Set.init, scope: { todoTargets[$0] })
        field(\.automationAttemptReceipts, \.automationAttemptReceipts, Key.automationAttemptReceipts, repartition: routesChanged,
            split: Array.init, combine: Set.init, scope: { todoTargets[$0] })
        field(\.pendingTodoAcknowledgements, \.pendingTodoAcknowledgements, Key.pendingTodoAcknowledgements, repartition: routesChanged,
            split: Array.init, combine: Set.init, scope: {
                todoTargets[.init(host: $0.host, username: $0.username, todoID: $0.todo.id)]
            })
        field(\.boardPins, \.boardPins, Key.boardPins, candidate: candidatePins, split: Array.init, combine: Set.init, scope: { pin in
            guard case let .mergeRequest(projectID, iid) = pin.item else { return nil }
            return MRSettingsKey(host: pin.host, projectID: projectID, iid: iid)
        })
        targets(\.pendingCommentReviews, \.pendingCommentReviews, Key.pendingCommentReviews)
        scoped(\.commentReviewProgress, \.commentReviewProgress, Key.commentReviewProgress)

        if case .load = transfer { return true }
        if changedMRKeys.contains(Key.reviewerApprovals) { updatedKeys.insert(Key.reviewerApprovals) }
        if updatedKeys.contains(Key.newReviewTargets) {
            archive.replace(\.newReviewGenerations, with: newReviewGenerations.map { .init(target: $0.key, value: $0.value) },
                keyedBy: { MRSettingsKey($0.target) })
        }
        if updatedKeys.contains(Key.ignoredMergeRequests) {
            archive.legacyHideDeadline = (candidateHides ?? hiddenMergeRequests).legacyRestoreUntil
        }
        if updatedKeys.contains(Key.automaticActionOptIns) {
            archive.emptyActionOptIns = Set(automaticActionOptIns.compactMap { $0.value.isEmpty ? $0.key : nil })
        }
        if !updatedKeys.isEmpty { archive.discardEmptyRecords() }
        guard persistenceStore.save(archive, forKey: Key.mergeRequestRecords, changed: !updatedKeys.isEmpty) else { return false }
        mrSettingsArchive = archive
        changedMRKeys.subtract(updatedKeys)
        if case .savePreference = transfer { return failedKeys.isEmpty }
        return !failedKeys.contains(Key.independentApprovalPreferences)
    }
}
