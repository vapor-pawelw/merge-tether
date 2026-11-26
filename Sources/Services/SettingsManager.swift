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
    var automaticWritesAllowed: Bool { automaticActionsAllowed && accountReadyForWrites && automation.hasAutomaticActionConsent }
    var automaticPublicWritesAllowed: Bool { automaticActionsAllowed && accountReadyForWrites && automation.hasAutomaticPublicActionConsent }
    private static let conveniencePersistenceKeys: Set<String> = [
        "automationEvents", "boardPins", "boardManualOrder", "lastSeenTodoIDs", "reviewAssignments", "incomingReviewFilterSettings"
    ]

    func recordPersistenceFailure(_ key: String) { persistenceStore.recordFailure(key) }
    @ObservationIgnored private var lastSavedAutomation: AutomationSettings?
    @ObservationIgnored var onAutomationChanged: ((AutomationSettings) -> Void)?
    @ObservationIgnored private var changedMRKeys: Set<String> = []
    @ObservationIgnored private var mrSettingsArchive = MRSettingsArchive()
    @ObservationIgnored private var activeGitLabAccount: GitLabAccountIdentity?
    var requiresAuthenticatedGitLabAccount = false
    private var accountBindingSaved = false
    var accountReadyForWrites: Bool { !requiresAuthenticatedGitLabAccount || accountBindingSaved }

    func approvalBaseline(for target: MRAutomationScope.Target, user: GitLabAuthenticatedUser) -> ReviewApprovalBaseline? {
        guard let key = MRSettingsKey(target.forAccount(.init(host: target.host, username: target.username))),
              target.account.matches(user.account(on: target.host)) else { return nil }
        let accountKey = MRSettingsKey(target.forAccount(user.account(on: target.host)))
        return (accountKey.flatMap { mrSettingsArchive.records[$0] }?.reviewerApprovals
            ?? mrSettingsArchive.records[key]?.reviewerApprovals)?.first { $0.user.id == user.id }?.baseline
    }

    @discardableResult
    func setApprovalBaseline(_ baseline: ReviewApprovalBaseline?, for target: MRAutomationScope.Target,
                             user: GitLabAuthenticatedUser) -> Bool {
        let account = user.account(on: target.host)
        guard let legacyKey = MRSettingsKey(target.forAccount(.init(host: target.host, username: target.username))),
              let accountKey = MRSettingsKey(target.forAccount(account)), user.id > 0, target.account.matches(account),
              approvalBaseline(for: target, user: user) != baseline else { return false }
        let key = mrSettingsArchive.accountNames.isEmpty ? legacyKey : accountKey
        var approvals = mrSettingsArchive.records[key]?.reviewerApprovals ?? []
        approvals.removeAll { $0.user.id == user.id }
        if let baseline { approvals.append(.init(user: user, baseline: baseline)) }
        mrSettingsArchive.setReviewerApprovals(approvals, for: key)
        if key != legacyKey, let legacy = mrSettingsArchive.records[legacyKey]?.reviewerApprovals {
            mrSettingsArchive.setReviewerApprovals(legacy.filter { $0.user.id != user.id }, for: legacyKey)
        }
        changedMRKeys.insert(Key.reviewerApprovals)
        return true
    }

    func approvalBaselineTargets(host: String, user: GitLabAuthenticatedUser) -> Set<MRAutomationScope.Target> {
        Set(mrSettingsArchive.records.compactMap { key, record in
            guard key.host == host, key.userID == nil || key.userID == user.id,
                  record.reviewerApprovals?.contains(where: { $0.user.id == user.id }) == true else { return nil }
            return .mergeRequest(host: host, username: user.username, projectID: key.request.projectID, iid: key.request.iid)
        })
    }

    /// Called synchronously after a successful, session-bound read of GitLab's /user.
    func bindAuthenticatedAccount(_ account: GitLabAccountIdentity) -> Bool {
        guard let id = account.userID, id > 0, !account.host.isEmpty, !account.username.isEmpty else { return false }
        if activeGitLabAccount == account, activeGitLabAccount?.username == account.username {
            if !accountBindingSaved { accountBindingSaved = save() }
            return accountBindingSaved
        }

        let previous = activeGitLabAccount
        accountBindingSaved = false
        if mrSettingsArchive.accountNames.last(where: { $0 == account })?.username != account.username
            || mrSettingsArchive.accountNames.last(where: { $0.host == account.host && $0.username == account.username }) != account {
            mrSettingsArchive.accountNames.append(account)
        }
        activeGitLabAccount = account
        assistantHandoffs = assistantHandoffs.map { handoff in
            guard handoff.accountUserID == nil else { return handoff }
            var bound = handoff
            bound.accountUserID = reboundTarget(handoff.key.automationTarget, projectedFor: previous).userID
            return bound
        }
        reprojectAccountTargets(from: previous)
        accountBindingSaved = save()
        return accountBindingSaved
    }

    func clearAuthenticatedAccount() {
        guard let previous = activeGitLabAccount else { return }
        activeGitLabAccount = nil
        accountBindingSaved = false
        reprojectAccountTargets(from: previous)
    }

    private func reprojectAccountTargets(from previous: GitLabAccountIdentity?) {
        func reproject(_ target: MRAutomationScope.Target) -> MRAutomationScope.Target {
            projectedTarget(reboundTarget(target, projectedFor: previous))
        }
        automation.scope.mapAccountTargets(pausedTarget: {
            self.projectedTarget(self.reboundTarget($0, projectedFor: previous, unboundSafety: true))
        }, reproject)
        transferMRSettings(.rebind(previous))
        newReviewGenerations = Dictionary(newReviewGenerations.map { (reproject($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first })
    }

    func knownUsernames(for account: GitLabAccountIdentity) -> Set<String> {
        Set(mrSettingsArchive.accountNames.filter { $0 == account }.map(\.username)).union([account.username])
    }

    func unambiguousLegacyUsernames(for account: GitLabAccountIdentity) -> Set<String> {
        knownUsernames(for: account).filter { username in
            let candidates = mrSettingsArchive.accountNames.filter { $0.host == account.host && $0.username == username }
            return candidates.allSatisfy { $0 == account }
        }
    }

    func authenticatedAccountID(host: String, username: String) -> Int? {
        guard let account = activeGitLabAccount, account.host == host, account.username == username else { return nil }
        return account.userID
    }

    func handoffMatchesAccount(_ handoff: AssistantAutomationRunner.Handoff, host: String, username: String) -> Bool {
        guard handoff.key.work.host == host else { return false }
        guard let currentID = authenticatedAccountID(host: host, username: username) else {
            return handoff.accountUserID == nil && handoff.key.username == username
        }
        if let owner = handoff.accountUserID { return owner == currentID }
        guard handoff.key.username == username else { return false }
        let knownOwner = mrSettingsArchive.accountNames.first { $0.host == host && $0.username == username }
        return knownOwner?.userID.map { $0 == currentID } ?? true
    }

    func scopedTarget(for handoff: AssistantAutomationRunner.Handoff) -> MRAutomationScope.Target {
        let target = handoff.key.automationTarget
        let account = GitLabAccountIdentity(host: target.host, username: target.username, userID: handoff.accountUserID)
        return projectedTarget(reboundTarget(target.forAccount(account), projectedFor: nil))
    }

    private func canonicalTarget(_ target: MRAutomationScope.Target,
                                 projectedFor account: GitLabAccountIdentity?) -> MRAutomationScope.Target {
        if target.userID == nil, let account, target.account.matches(account) {
            return target.forAccount(account)
        }
        guard target.userID != nil, let account = mrSettingsArchive.accountNames.last(where: { $0 == target.account }) else {
            return target
        }
        return target.forAccount(account)
    }

    private func reboundTarget(_ target: MRAutomationScope.Target,
                               projectedFor previous: GitLabAccountIdentity?,
                               unboundSafety: Bool = false) -> MRAutomationScope.Target {
        let canonical = canonicalTarget(target, projectedFor: previous)
        guard canonical.userID == nil, let account = activeGitLabAccount, canonical.account.matches(account) else {
            return canonical
        }
        // An unbound safety preference must take effect in the session that binds it.
        if unboundSafety { return canonical.forAccount(account) }
        // A reused handle cannot transfer older data to the new account.
        let owner = mrSettingsArchive.accountNames.first(where: { canonical.account.matches($0) }) ?? account
        return canonicalTarget(canonical.forAccount(owner), projectedFor: nil)
    }

    private func projectedTarget(_ target: MRAutomationScope.Target) -> MRAutomationScope.Target {
        guard let account = activeGitLabAccount, target.account == account else { return target }
        return target.forAccount(.init(host: account.host, username: account.username))
    }

    private func mirrorTarget(_ target: MRAutomationScope.Target) -> MRAutomationScope.Target? {
        mirrorAccount(target.account).map(target.forAccount)
    }

    private func mirrorAccount(_ account: GitLabAccountIdentity) -> GitLabAccountIdentity? {
        guard account.userID != nil else { return account }
        let owner = mrSettingsArchive.accountNames.last { $0.host == account.host && $0.username == account.username }
        guard owner == nil || owner == account else { return nil }
        return .init(host: account.host, username: account.username)
    }

    private func downgradeTarget(_ target: MRAutomationScope.Target) -> MRAutomationScope.Target? {
        if target.userID != nil { return canonicalTarget(target, projectedFor: nil) }
        // Once a handle has been reassigned, an old client cannot distinguish its owners.
        guard !hasReassignedUsername(target) else { return nil }
        return target
    }

    private func hasReassignedUsername(_ target: MRAutomationScope.Target) -> Bool {
        hasReassignedUsername(target.account)
    }

    private func hasReassignedUsername(_ account: GitLabAccountIdentity) -> Bool {
        Set(mrSettingsArchive.accountNames.filter { $0.host == account.host && $0.username == account.username }).count > 1
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

    func hideReviewedMergeRequest(_ review: HiddenReview) -> Bool {
        var updated = hiddenMergeRequests
        guard updated.targets.insert(review.target).inserted else { return true }
        var hidden = review
        hidden.hideID = UUID()
        hidden.manuallyHidden = true
        updated.details[review.target] = hidden
        return saveHiddenMergeRequests(updated)
    }

    func hideFilteredReviews(_ reviews: [HiddenReview], reasons: [MRAutomationScope.Target: String] = [:],
                             now: Date = .now) -> Bool {
        var updated = hiddenMergeRequests
        for var review in reviews {
            guard updated.targets.insert(review.target).inserted else { continue }
            review.hideID = UUID()
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
            review.target.account == .init(host: host, username: username)
                && review.inboxNotification.map { ids.contains($0.id) } == true
        }
        guard !matching.isEmpty else { return false }
        for review in matching { updated.details[review.target]?.inboxNotification = nil }
        return saveHiddenMergeRequests(updated)
    }

    func canRestoreHiddenReview(_ target: MRAutomationScope.Target) -> Bool {
        guard hiddenMergeRequests.targets.contains(target) else { return false }
        let review = hiddenMergeRequests.details[target]
        if let request = review?.request { return MergeRequestFinishedState(request) == nil }
        if review?.wasFinishedBeforeUpgrade == true { return false }
        let request = mrLifecycleLedger.request(for: target)
        return MergeRequestFinishedState(request) == nil
    }

    /// Only an authenticated single-MR read may remove a hide due to reviewer changes.
    @discardableResult
    func reconcileHiddenReview(_ target: MRAutomationScope.Target, request: GitLabMergeRequest,
                               reviewerID: Int, hideID: UUID?) -> Bool {
        let owner = canonicalTarget(target, projectedFor: activeGitLabAccount).userID
        guard hiddenMergeRequests.targets.contains(target),
              hiddenMergeRequests.details[target]?.hideID == hideID,
              owner == nil || owner == reviewerID,
              let iid = target.iid, request.mergeRequestID == target.mergeRequestID,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: iid),
              [.opened, .closed, .merged].contains(request.state), reviewerID > 0 else { return false }
        var updated = hiddenMergeRequests
        if request.reviewers?.contains(where: { $0.id == reviewerID }) == false {
            var assignments = reviewAssignments
            if assignments.removeAssignment(target), !saveReviewAssignments(assignments) { return false }
            updated.targets.remove(target)
            return saveHiddenMergeRequests(updated)
        }
        var review = updated.details[target] ?? .init(target: target, title: request.title, url: request.webURL,
                                                      manuallyHidden: true)
        if let previous = review.request, previous.state == request.state, previous.title == request.title,
           previous.webURL == request.webURL, previous.author == request.author, previous.reviewers == request.reviewers {
            return false
        }
        review.title = request.title
        review.url = request.webURL
        review.restoreUntil = nil
        review.request = request
        updated.details[target] = review
        _ = saveHiddenMergeRequests(updated)
        return false
    }

    func restoreHiddenReviews(_ targets: Set<MRAutomationScope.Target>) -> Bool {
        var updated = hiddenMergeRequests
        updated.targets.subtract(targets.filter { canRestoreHiddenReview($0) })
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
    var treatAssignedMergeRequestsAsOwn: Bool

    func owns(_ request: GitLabMergeRequest, userID: Int) -> Bool {
        request.isOwned(by: userID, includingAssignee: treatAssignedMergeRequestsAsOwn)
    }

    func owns(_ request: GitLabMergeRequest, username: String) -> Bool {
        ownerID(of: request, username: username) != nil
    }

    func ownerID(of request: GitLabMergeRequest, username: String) -> Int? {
        request.ownerID(for: username, includingAssignee: treatAssignedMergeRequestsAsOwn)
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
    var feedbackSuggestionDecisions = FeedbackSuggestionDecisions() {
        didSet { changedMRKeys.insert(Key.feedbackSuggestionDecisions) }
    }
    var reviewParticipationPreferences = ReviewParticipationPreferences() {
        didSet { changedMRKeys.insert(Key.reviewParticipationPreferences) }
    }
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
        treatAssignedMergeRequestsAsOwn = defaults.bool(forKey: Key.treatAssignedMergeRequestsAsOwn)
        var runtimeAutomation = loadedAutomation
        runtimeAutomation.isGloballySuspended = !globallyEnabled
        automation = runtimeAutomation
        acceptedAutomation = loadedAutomation
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
        let legacyArchive = store.load(Key.mergeRequestRecords, fallback: MRSettingsArchive())
        mrSettingsArchive = store.load(Key.mergeRequestAccountRecords, fallback: legacyArchive)
        if var savedScope = mrSettingsArchive.accountAutomationScope {
            if store.savedFingerprint(forKey: Key.automation) == mrSettingsArchive.mirrorFingerprints[Key.automation] {
                savedScope.isGloballySuspended = !globallyEnabled
                automation.scope = savedScope
            } else {
                savedScope.mapAccountTargets { mirrorTarget($0) == nil || hasReassignedUsername($0) ? $0 : nil }
                automation.scope.mapAccountTargets(downgradeTarget)
                automation.scope.retainAccountTargets(from: savedScope)
            }
        }
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
            let source = handoff.key.automationTarget
            let target = source.forAccount(.init(host: source.host, username: source.username, userID: handoff.accountUserID))
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
        defaults.set(conversationDestination.rawValue, forKey: Key.conversationDestination)
        let previousAutomation = lastSavedAutomation ?? automation
        var storedAutomation = automation
        if !mrSettingsArchive.accountNames.isEmpty {
            storedAutomation.scope.mapAccountTargets { canonicalTarget($0, projectedFor: activeGitLabAccount) }
            mrSettingsArchive.accountAutomationScope = storedAutomation.scope
            storedAutomation.scope.mapAccountTargets(mirrorTarget)
        }
        let automationSaved = persistenceStore.save(storedAutomation, forKey: Key.automation)
        if automationSaved, mrSettingsArchive.accountAutomationScope != nil {
            mrSettingsArchive.mirrorFingerprints[Key.automation] = persistenceStore.savedFingerprint(forKey: Key.automation)
            changedMRKeys.insert(Key.automation)
        }
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
        defaults.set(treatAssignedMergeRequestsAsOwn, forKey: Key.treatAssignedMergeRequestsAsOwn)
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
        transferMRSettings(.savePreference(.reviewParticipation(reviewParticipationPreferences)))
            && persistenceStore.synchronize()
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
        return commitReviewParticipationPreferences(candidate)
    }

    func unmarkAutomationAuthor(_ id: UUID, host: String, username: String) -> Bool {
        var candidate = reviewParticipationPreferences
        guard candidate.unmarkAutomationAuthor(id, host: host, username: username) else { return false }
        return commitReviewParticipationPreferences(candidate)
    }

    @discardableResult
    func recordAIReplyTrust(_ classification: AICommentOriginOverride.Classification,
        notes: [GitLabMergeRequestDiscussion.Note], host: String, user: GitLabAuthenticatedUser, at date: Date = Date()) -> Bool {
        var candidate = reviewParticipationPreferences
        candidate.recordAIReplyTrust(classification, notes: notes, host: host, user: user, at: date)
        return commitReviewParticipationPreferences(candidate)
    }

    func resetAIReplyTrust(_ id: ReviewParticipationPreferences.AIReplyTrust.ID) -> Bool {
        var candidate = reviewParticipationPreferences
        candidate.resetAIReplyTrust(id)
        return commitReviewParticipationPreferences(candidate)
    }

    private func commitReviewParticipationPreferences(_ candidate: ReviewParticipationPreferences) -> Bool {
        guard candidate != reviewParticipationPreferences else { return true }
        persistenceStore.preserveCorruptValues()
        let saved = transferMRSettings(.savePreference(.reviewParticipation(candidate)))
        let synchronized = persistenceStore.synchronize()
        guard saved && synchronized else {
            if saved {
                // Restore the prior durable decision if synchronization rejected the new one.
                _ = transferMRSettings(.savePreference(.reviewParticipation(reviewParticipationPreferences)))
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
        guard automaticActionsAllowed,
              !pipelineClaimAssessmentAttempts.contains(where: { $0.matchesAttempt(attempt) }) else { return false }
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
            Key.treatAssignedMergeRequestsAsOwn: true,
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
        static let mergeRequestAccountRecords = "mergeRequestAccountRecords"
        static let reviewerApprovals = "reviewerApprovals"
        static let conversationDestination = "conversationDestination"
        static let automation = "automation"
        static let automationGloballyEnabled = "automationGloballyEnabled"
        static let confirmGlobalAutomationChanges = "confirmGlobalAutomationChanges"
        static let keepMacAwakeDuringAgentTasks = "keepMacAwakeDuringAgentTasks"
        static let addNewReviewsToReviewed = "addNewReviewsToReviewed"
        // Retain the persisted key so upgrades preserve the user's choice.
        static let treatAssignedMergeRequestsAsOwn = "treatSoleAssigneeAsOwn"
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
        case reviewParticipation(ReviewParticipationPreferences)

        var key: String {
            switch self {
            case .hiddenReviews: Key.ignoredMergeRequests
            case .boardPins: Key.boardPins
            case .reviewParticipation: Key.reviewParticipationPreferences
            }
        }
    }

    private enum MRSettingsTransfer {
        case load
        case rebind(GitLabAccountIdentity?)
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
        typealias TargetTransform = (Target) -> Target?
        var archive = mrSettingsArchive
        var updatedKeys = Set<String>()
        var failedKeys = Set<String>()
        var candidateHides: HiddenMergeRequests?
        var candidatePins: Set<BoardCardPin>?
        var candidateParticipation: ReviewParticipationPreferences?
        if case let .savePreference(preference) = transfer {
            switch preference {
            case .hiddenReviews(let value): candidateHides = value
            case .boardPins(let value): candidatePins = value
            case .reviewParticipation(let value): candidateParticipation = value
            }
        }

        func field<Value: Codable, Element>(
            _ path: ReferenceWritableKeyPath<SettingsManager, Value>,
            _ field: WritableKeyPath<Record, [Element]?>, _ key: String,
            candidate: Value? = nil, repartition: Bool = false,
            split: (Value) -> [Element], combine: ([Element]) -> Value,
            restorePayload: (Value, Value) -> Value = { value, _ in value },
            mapTarget: ((Element, TargetTransform) -> Element?)? = nil,
            mirrorEntry: ((Element) -> Element?)? = nil,
            archiveEntry: (Element) -> Element = { $0 },
            unboundSafety: (Element) -> Bool = { _ in false },
            scope: (Element) -> MRSettingsKey?
        ) {
            func mapped(_ values: [Element], by transform: TargetTransform) -> [Element] {
                guard let mapTarget, !archive.accountNames.isEmpty else { return values }
                return values.compactMap { mapTarget($0, transform) }
            }
            switch transfer {
            case .load:
                let legacy = persistenceStore.load(key, fallback: self[keyPath: path])
                let fingerprint = persistenceStore.savedFingerprint(forKey: key)
                if let previous = archive.mirrorFingerprints[key], fingerprint == nil || fingerprint == previous {
                    let canonical = archive.values(field)
                    self[keyPath: path] = restorePayload(combine(mapped(canonical) { projectedTarget($0) }), legacy)
                } else if !archive.accountNames.isEmpty, mapTarget != nil, archive.mirrorFingerprints[key] != nil {
                    let retained = mapped(archive.values(field)) {
                        mirrorTarget($0) == nil || hasReassignedUsername($0) ? $0 : nil
                    }
                    let incoming = mapped(split(legacy)) { downgradeTarget($0) }
                    self[keyPath: path] = combine(mapped(retained + incoming) { projectedTarget($0) })
                } else {
                    self[keyPath: path] = legacy
                }
            case .rebind(let previous):
                guard let mapTarget else { return }
                self[keyPath: path] = combine(split(self[keyPath: path]).compactMap { entry in
                    mapTarget(entry) {
                        projectedTarget(reboundTarget($0, projectedFor: previous, unboundSafety: unboundSafety(entry)))
                    }
                })
                changedMRKeys.insert(key)
            case .save, .savePreference:
                if case .savePreference(let selected) = transfer, key != selected.key { return }
                let changed = candidate != nil || changedMRKeys.contains(key)
                let value = candidate ?? self[keyPath: path]
                let canonical = mapped(split(value)) { canonicalTarget($0, projectedFor: activeGitLabAccount) }
                let mirror: Value
                if !archive.accountNames.isEmpty, let mirrorEntry {
                    mirror = combine(canonical.compactMap(mirrorEntry))
                } else {
                    mirror = mapTarget == nil || archive.accountNames.isEmpty
                        ? value : combine(mapped(canonical) { mirrorTarget($0) })
                }
                guard persistenceStore.save(mirror, forKey: key, changed: changed),
                      let fingerprint = persistenceStore.savedFingerprint(forKey: key) else {
                    failedKeys.insert(key)
                    return
                }
                guard changed || repartition || archive.mirrorFingerprints[key] != fingerprint else { return }
                archive.replace(field, with: canonical.map(archiveEntry), keyedBy: scope)
                archive.mirrorFingerprints[key] = fingerprint
                updatedKeys.insert(key)
            }
        }

        func targets(_ path: ReferenceWritableKeyPath<SettingsManager, Set<Target>>,
                     _ value: WritableKeyPath<Record, [Target]?>, _ key: String, unboundSafety: Bool = false) {
            field(path, value, key, split: Array.init, combine: Set.init, mapTarget: { $1($0) },
                  unboundSafety: { _ in unboundSafety }, scope: MRSettingsKey.init)
        }

        func scoped<Value: Codable & Sendable>(_ path: ReferenceWritableKeyPath<SettingsManager, [Target: Value]>,
                                    _ value: WritableKeyPath<Record, [Record.Scoped<Value>]?>, _ key: String,
                                    unboundSafety: (Value) -> Bool = { _ in false },
                                    combineDuplicates: (Value, Value) -> Value = { first, _ in first }) {
            field(path, value, key, split: { $0.map { .init(target: $0.key, value: $0.value) } },
                combine: { Dictionary($0.map { ($0.target, $0.value) }, uniquingKeysWith: combineDuplicates) },
                mapTarget: { entry, transform in transform(entry.target).map { .init(target: $0, value: entry.value) } },
                unboundSafety: { unboundSafety($0.value) },
                scope: { MRSettingsKey($0.target) })
        }

        func ordered<Value: Codable>(_ path: ReferenceWritableKeyPath<SettingsManager, [Value]>,
                                      _ value: WritableKeyPath<Record, [Record.Ordered<Value>]?>, _ key: String,
                                      target: WritableKeyPath<Value, Target>? = nil,
                                      owner: KeyPath<Value, Int>? = nil,
                                      scope: (Value) -> MRSettingsKey?) {
            let mapper: ((Record.Ordered<Value>, TargetTransform) -> Record.Ordered<Value>?)? = target.map { path in
                { entry, transform in
                    let candidate = mapEntry(entry.value, target: path, owner: owner, using: transform)
                    return candidate.map { .init(position: entry.position, value: $0) }
                }
            }
            field(path, value, key, split: { $0.enumerated().map { .init(position: $0.offset, value: $0.element) } },
                combine: { $0.sorted { $0.position < $1.position }.map(\.value) },
                mapTarget: mapper, scope: { scope($0.value) })
        }

        func mapEntry<Value>(_ entry: Value, target: WritableKeyPath<Value, Target>, owner: KeyPath<Value, Int>?,
                             using transform: TargetTransform) -> Value? {
            var previous = entry[keyPath: target]
            if let owner {
                previous = previous.forAccount(.init(host: previous.host, username: previous.username, userID: entry[keyPath: owner]))
            }
            guard let updated = transform(previous) else { return nil }
            var result = entry
            result[keyPath: target] = updated
            return result
        }

        func accountEntry<Value>(_ entry: Value, host: KeyPath<Value, String>,
                                 username: WritableKeyPath<Value, String>, owner: WritableKeyPath<Value, Int?>,
                                 using transform: TargetTransform) -> Value? {
            let previous = Target(host: entry[keyPath: host], username: entry[keyPath: username],
                projectID: 0, iid: nil, userID: entry[keyPath: owner])
            guard let updated = transform(previous) else { return nil }
            var result = entry
            result[keyPath: username] = updated.username
            result[keyPath: owner] = updated.userID
            return result
        }

        func targetSet<Value: Codable & Hashable & Sendable>(_ path: ReferenceWritableKeyPath<SettingsManager, Set<Value>>,
                                                   _ value: WritableKeyPath<Record, [Value]?>, _ key: String,
                                                   target: WritableKeyPath<Value, Target>, owner: KeyPath<Value, Int>? = nil) {
            field(path, value, key, split: Array.init, combine: Set.init, mapTarget: { entry, transform in
                mapEntry(entry, target: target, owner: owner, using: transform)
            }, scope: { MRSettingsKey($0[keyPath: target]) })
        }

        targets(\.autoApproveOptOuts, \.autoApproveOptOuts, Key.autoApproveOptOuts, unboundSafety: true)
        scoped(\.independentApprovalPreferences, \.independentApprovalPreferences, Key.independentApprovalPreferences,
            unboundSafety: { $0 == .off })
            { first, second in first == .off || second == .off ? .off : first }
        targets(\.autoPublishOptOuts, \.autoPublishOptOuts, Key.autoPublishOptOuts, unboundSafety: true)
        targets(\.autoMergeOptOuts, \.autoMergeOptOuts, Key.autoMergeOptOuts, unboundSafety: true)
        targets(\.autoMergeOptIns, \.autoMergeOptIns, Key.autoMergeOptIns)
        let emptyActionOptIns = archive.emptyActionOptIns ?? []
        field(\.automaticActionOptIns, \.automaticActionOptIns, Key.automaticActionOptIns,
            split: { actions in actions.flatMap { action, targets in targets.map { .init(action: action, target: $0) } } },
            combine: { entries in
                var result = Dictionary(uniqueKeysWithValues: emptyActionOptIns.map { ($0, Set<Target>()) })
                for entry in entries { result[entry.action, default: []].insert(entry.target) }
                return result
            }, mapTarget: { entry, transform in transform(entry.target).map { .init(action: entry.action, target: $0) } },
            scope: { MRSettingsKey($0.target) })
        ordered(\.mergeSubmissions, \.mergeSubmissions, Key.mergeSubmissions, target: \.target, owner: \.userID,
            scope: { MRSettingsKey($0.target) })
        field(\.hiddenMergeRequests, \.hiddenReviews, Key.ignoredMergeRequests, candidate: candidateHides,
            split: { hides in hides.targets.map { .init(target: $0, detail: hides.details[$0]) } },
            combine: { entries in
                var hides = HiddenMergeRequests()
                hides.targets = Set(entries.map(\.target))
                hides.details = Dictionary(entries.compactMap { entry in entry.detail.map { (entry.target, $0) } },
                    uniquingKeysWith: { first, _ in first })
                return hides
            }, mapTarget: { entry, transform in
                guard let target = transform(entry.target) else { return nil }
                return .init(target: target, detail: entry.detail.map { detail in
                    var updated = detail
                    updated.target = target
                    return updated
                })
            }, unboundSafety: { _ in true }, scope: { MRSettingsKey($0.target) })
        targets(\.newReviewTargets, \.newReviewTargets, Key.newReviewTargets)
        targets(\.heldNewReviewTargets, \.heldNewReviewTargets, Key.heldNewReviewTargets)
        targetSet(\.authorFeedbackAttempts, \.authorFeedbackAttempts, Key.authorFeedbackAttempts, target: \.target)
        field(\.assistantAutomaticRetryAttempts, \.assistantAutomaticRetryAttempts, Key.assistantAutomaticRetryAttempts,
            split: { $0.enumerated().map { .init(position: $0.offset, value: $0.element) } },
            combine: { $0.sorted { $0.position < $1.position }.map(\.value) },
            mapTarget: { entry, transform in
                guard let target = accountEntry(entry.value.target, host: \.host, username: \.username,
                    owner: \.accountUserID, using: transform) else { return nil }
                var value = entry.value
                value.target = target
                return .init(position: entry.position, value: value)
            }, scope: {
                let target = $0.value.target
                return MRSettingsKey(host: target.host, projectID: target.projectID, iid: target.iid, userID: target.accountUserID)
            })
        targetSet(\.pipelineRefreshAttempts, \.pipelineRefreshAttempts, Key.pipelineRefreshAttempts, target: \.target, owner: \.userID)
        ordered(\.pipelineClaimAssessmentAttempts, \.pipelineClaimAssessmentAttempts, Key.pipelineClaimAssessmentAttempts,
            target: \.target, owner: \.userID, scope: { MRSettingsKey($0.target) })
        field(\.conflictReceipts, \.conflictReceipts, Key.conflictReceipts, split: Array.init, combine: Set.init,
            scope: { MRSettingsKey(host: $0.host, projectID: $0.projectID, iid: $0.iid, userID: $0.userID) })
        field(\.reReviewReceipts, \.reReviewReceipts, Key.reReviewReceipts,
            split: { $0.map { .init(key: $0.key, value: $0.value) } },
            combine: { Dictionary($0.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }) },
            scope: { MRSettingsKey(host: $0.key.host, projectID: $0.key.projectID, iid: $0.key.iid, userID: $0.key.authorID) })
        scoped(\.reReviewDraftBaselines, \.reReviewDraftBaselines, Key.reReviewDraftBaselines, combineDuplicates: max)
        field(\.assistantHandoffs, \.assistantHandoffs, Key.assistantHandoffs,
            split: { $0.enumerated().map { .init(position: $0.offset, value: $0.element) } },
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
            }, mirrorEntry: { entry in
                var job = entry.value
                let key = job.key
                let original = GitLabAccountIdentity(host: key.work.host, username: key.username, userID: job.accountUserID)
                guard self.mirrorAccount(original) != nil else { return nil }
                job.accountUserID = nil
                return .init(position: entry.position, value: job)
            }, archiveEntry: { entry in
                var job = entry.value
                let account = GitLabAccountIdentity(host: job.key.work.host, username: job.key.username, userID: job.accountUserID)
                // Successful transcripts live in the compatibility history when it can represent their owner.
                if job.execution?.state == .succeeded, self.mirrorAccount(account) != nil { job.execution?.output = nil }
                return .init(position: entry.position, value: job)
            }, scope: {
                let target = $0.value.key.automationTarget
                return MRSettingsKey(host: target.host, projectID: target.projectID, iid: target.iid, userID: $0.value.accountUserID)
            })
        ordered(\.workflowActivity, \.workflowActivity, Key.workflowActivity, scope: {
            let request = $0.event.mergeRequest
            return MRSettingsKey(host: $0.host, projectID: request.projectID, iid: request.iid, userID: $0.user.id)
        })
        ordered(\.automationEvents, \.automationEvents, Key.automationEvents, target: \.target, scope: { MRSettingsKey($0.target) })
        ordered(\.mrActionIntents, \.mrActionIntents, Key.mrActionIntents, target: \.target, scope: { MRSettingsKey($0.target) })
        targetSet(\.routedMRTodoReceipts, \.routedMRTodoReceipts, Key.routedMRTodoReceipts, target: \.target)
        let todoTargets = Dictionary(grouping: routedMRTodoReceipts) {
            let target = canonicalTarget($0.target, projectedFor: activeGitLabAccount)
            return TodoAutomationReceipt(host: target.host, username: target.username, accountUserID: target.userID, todoID: $0.event.id)
        }.compactMapValues { routes -> MRSettingsKey? in
            let targets = Set(routes.map { canonicalTarget($0.target, projectedFor: activeGitLabAccount) })
            guard targets.count == 1, let target = targets.first else { return nil }
            return MRSettingsKey(target)
        }
        let routesChanged = updatedKeys.contains(Key.routedMRTodoReceipts)
        func todoReceipts(_ path: ReferenceWritableKeyPath<SettingsManager, Set<TodoAutomationReceipt>>,
                          _ value: WritableKeyPath<Record, [TodoAutomationReceipt]?>, _ key: String) {
            field(path, value, key, repartition: routesChanged, split: Array.init, combine: Set.init,
                mapTarget: { accountEntry($0, host: \.host, username: \.username, owner: \.accountUserID, using: $1) },
                scope: { todoTargets[$0] })
        }
        todoReceipts(\.automationReceipts, \.automationReceipts, Key.automationReceipts)
        todoReceipts(\.automationAttemptReceipts, \.automationAttemptReceipts, Key.automationAttemptReceipts)
        field(\.pendingTodoAcknowledgements, \.pendingTodoAcknowledgements, Key.pendingTodoAcknowledgements, repartition: routesChanged,
            split: Array.init, combine: Set.init,
            mapTarget: { accountEntry($0, host: \.host, username: \.username, owner: \.accountUserID, using: $1) },
            scope: {
                todoTargets[.init(host: $0.host, username: $0.username, accountUserID: $0.accountUserID, todoID: $0.todo.id)]
            })
        field(\.boardPins, \.boardPins, Key.boardPins, candidate: candidatePins, split: Array.init, combine: Set.init,
            mapTarget: { accountEntry($0, host: \.host, username: \.username, owner: \.accountUserID, using: $1) },
            scope: { pin in
            guard case let .mergeRequest(projectID, iid) = pin.item else { return nil }
            return MRSettingsKey(host: pin.host, projectID: projectID, iid: iid, userID: pin.accountUserID)
        })
        targets(\.pendingCommentReviews, \.pendingCommentReviews, Key.pendingCommentReviews)
        scoped(\.commentReviewProgress, \.commentReviewProgress, Key.commentReviewProgress)
        field(\.reviewParticipationPreferences, \.reviewParticipationPreferences, Key.reviewParticipationPreferences,
            candidate: candidateParticipation, split: \.storedEntries, combine: ReviewParticipationPreferences.init(storedEntries:),
            mapTarget: { stored, transform in
                // AI reply trust records are already keyed by host and user IDs, so renames never remap them.
                guard let entry = stored.entry else { return stored }
                return accountEntry(entry, host: \.host, username: \.username, owner: \.accountUserID, using: transform)
                    .map { .init(automationAuthor: stored.automationAuthor, entry: $0) }
            }, scope: { _ in nil })
        field(\.feedbackSuggestionDecisions, \.feedbackSuggestionDecisions, Key.feedbackSuggestionDecisions,
            split: \.accountEntries, combine: FeedbackSuggestionDecisions.init(accountEntries:),
            mapTarget: { entry, transform in transform(entry.target).map(entry.replacingTarget) },
            scope: { MRSettingsKey($0.target) })

        if case .load = transfer { return true }
        if case .rebind = transfer { return true }
        for archiveOnlyKey in [Key.reviewerApprovals, Key.automation] where changedMRKeys.contains(archiveOnlyKey) {
            updatedKeys.insert(archiveOnlyKey)
        }
        if updatedKeys.contains(Key.newReviewTargets) {
            archive.replace(\.newReviewGenerations, with: newReviewGenerations.map {
                .init(target: canonicalTarget($0.key, projectedFor: activeGitLabAccount), value: $0.value)
            },
                keyedBy: { MRSettingsKey($0.target) })
        }
        if updatedKeys.contains(Key.automaticActionOptIns) {
            archive.emptyActionOptIns = Set(automaticActionOptIns.compactMap { $0.value.isEmpty ? $0.key : nil })
        }
        if !updatedKeys.isEmpty { archive.discardEmptyRecords() }
        let hasAccountRecords = !archive.accountNames.isEmpty
        let archiveKey = hasAccountRecords ? Key.mergeRequestAccountRecords : Key.mergeRequestRecords
        guard persistenceStore.save(archive, forKey: archiveKey, changed: !updatedKeys.isEmpty) else { return false }
        if hasAccountRecords {
            // The previous app can always read the legacy collections directly.
            // Its archive must never take precedence over a newer username mirror.
            var legacy = MRSettingsArchive()
            for (key, record) in archive.records {
                guard let approvals = record.reviewerApprovals, !approvals.isEmpty,
                      let legacyKey = MRSettingsKey(host: key.host, projectID: key.request.projectID, iid: key.request.iid) else { continue }
                legacy.setReviewerApprovals((legacy.records[legacyKey]?.reviewerApprovals ?? []) + approvals, for: legacyKey)
            }
            guard persistenceStore.save(legacy, forKey: Key.mergeRequestRecords) else { return false }
        }
        mrSettingsArchive = archive
        changedMRKeys.subtract(updatedKeys)
        if case .savePreference = transfer { return failedKeys.isEmpty }
        return !failedKeys.contains(Key.independentApprovalPreferences)
    }
}
