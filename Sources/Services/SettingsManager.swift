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
    /// Convenience caches are preserved and diagnosed without stopping MR actions.
    var persistenceDegraded: Set<String> {
        Set(persistenceStore.failures.keys).subtracting(Self.conveniencePersistenceKeys)
    }
    var automaticActionsAllowed: Bool { persistenceDegraded.isEmpty }
    var automaticWritesAllowed: Bool { automaticActionsAllowed && automation.hasAutomaticActionConsent }
    private static let conveniencePersistenceKeys: Set<String> = [
        "assistantChats", "automationEvents", "boardPins", "lastSeenTodoIDs"
    ]

    func recordPersistenceFailure(_ key: String) { persistenceStore.recordFailure(key) }
    @ObservationIgnored private var lastSavedAutomation: AutomationSettings?
    @ObservationIgnored var onAutomationChanged: ((AutomationSettings) -> Void)?

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
    var autoPublishOptOuts: Set<MRAutomationScope.Target> = []
    var autoMergeOptOuts: Set<MRAutomationScope.Target> = []
    var mergeSubmissions: [MergeSubmissionReceipt] = []
    var ignoredMergeRequests: Set<MRAutomationScope.Target>
    var automation: AutomationSettings
    var automationReceipts: Set<TodoAutomationReceipt>
    var automationAttemptReceipts: Set<TodoAutomationReceipt>
    var authorFeedbackAttempts: Set<AuthorFeedbackAttempt>
    var feedbackSuggestionDecisions = FeedbackSuggestionDecisions()
    var pipelineRefreshAttempts: Set<PipelineRefreshAttempt>
    var pipelineClaimAssessmentAttempts: [PipelineClaimAssessmentAttempt]
    var pendingTodoAcknowledgements: Set<TodoActionAcknowledgement>
    var conflictReceipts: Set<MergeConflictReceipt>
    var reReviewReceipts: [ReReviewReceipt.Key: ReReviewReceipt]
    var reReviewDraftBaselines: [MRAutomationScope.Target: Int]
    var assistantHandoffs: [AssistantAutomationRunner.Handoff]
    var assistantChats: [AssistantAutomationRunner.ChatKey: String]
    var workflowActivity: [MergeWorkflowActivityEntry]
    var automationEvents: [MRAutomationEvent]
    var mrActionIntents: [MRTodoIntent]
    var routedMRTodoReceipts: Set<MRTodoRouteReceipt>
    var boardPins: Set<BoardCardPin>
    var boardGrouping: MRBoardGrouping = .withoutAutomation
    var effectiveBoardGrouping: MRBoardGrouping { boardGrouping.effective(for: automation) }
    var mrLifecycleLedger = MergeRequestLifecycleLedger()
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let store = DurableSettingsStore(defaults: defaults)
        persistenceStore = store
        Self.registerDefaults(in: defaults)
        conversationDestination = defaults.string(forKey: Key.conversationDestination)
            .flatMap(AssistantContextLauncher.Destination.init(rawValue:)) ?? .codexApp

        automation = store.load(Key.automation, fallback: AutomationSettings())
        mergeSubmissions = store.load(Key.mergeSubmissions, fallback: [])
        automationReceipts = store.load(Key.automationReceipts, fallback: [])
        automationAttemptReceipts = store.load(Key.automationAttemptReceipts, fallback: [])
        authorFeedbackAttempts = store.load(Key.authorFeedbackAttempts, fallback: [])
        feedbackSuggestionDecisions = store.load(Key.feedbackSuggestionDecisions, fallback: FeedbackSuggestionDecisions())
        pipelineRefreshAttempts = store.load(Key.pipelineRefreshAttempts, fallback: [])
        pipelineClaimAssessmentAttempts = store.load(Key.pipelineClaimAssessmentAttempts, fallback: [])
        pendingTodoAcknowledgements = store.load(Key.pendingTodoAcknowledgements, fallback: [])
        assistantHandoffs = store.load(Key.assistantHandoffs, fallback: [])
        assistantChats = store.load(Key.assistantChats, fallback: [:])
        workflowActivity = store.load(Key.workflowActivity, fallback: [])
        automationEvents = store.load(Key.automationEvents, fallback: [])
        mrActionIntents = store.load(Key.mrActionIntents, fallback: [])
        routedMRTodoReceipts = store.load(Key.routedMRTodoReceipts, fallback: [])
        boardGrouping = defaults.string(forKey: Key.boardGrouping).flatMap(MRBoardGrouping.init(rawValue:)) ?? .withoutAutomation
        boardPins = store.load(Key.boardPins, fallback: [])
        mrLifecycleLedger = store.load(Key.mrLifecycleLedger, fallback: .init())
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

        self.ignoredMergeRequests = store.load(Key.ignoredMergeRequests, fallback: [])
        self.autoApproveOptOuts = store.load(Key.autoApproveOptOuts, fallback: [])
        self.autoPublishOptOuts = store.load(Key.autoPublishOptOuts, fallback: [])
        self.autoMergeOptOuts = store.load(Key.autoMergeOptOuts, fallback: [])

        if let pathString = defaults.string(forKey: Key.glabPath), !pathString.isEmpty {
            self.glabPath = URL(fileURLWithPath: pathString)
        } else {
            self.glabPath = nil
        }

        lastSeenTodoIDs = store.load(Key.lastSeenTodoIDs, fallback: [])
        for handoff in assistantHandoffs {
            let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
            for (noteID, revision) in handoff.verifiedFeedbackNotes ?? [:] {
                authorFeedbackAttempts.insert(.init(target: target, noteID: noteID, revision: revision))
            }
        }
        lastSavedAutomation = automation
        mrLifecycleLedger.prepareFinishedRemoval()
    }

    func save() {
        persistenceStore.preserveCorruptValues()
        persistenceStore.save(pendingCommentReviews, forKey: Key.pendingCommentReviews)
        persistenceStore.save(commentReviewProgress, forKey: Key.commentReviewProgress)
        defaults.set(conversationDestination.rawValue, forKey: Key.conversationDestination)
        let previousAutomation = lastSavedAutomation ?? automation
        let automationSaved = persistenceStore.save(automation, forKey: Key.automation)
        persistenceStore.save(automationReceipts, forKey: Key.automationReceipts)
        persistenceStore.save(automationAttemptReceipts, forKey: Key.automationAttemptReceipts)
        persistenceStore.save(authorFeedbackAttempts, forKey: Key.authorFeedbackAttempts)
        persistenceStore.save(feedbackSuggestionDecisions, forKey: Key.feedbackSuggestionDecisions)
        persistenceStore.save(pipelineRefreshAttempts, forKey: Key.pipelineRefreshAttempts)
        persistenceStore.save(pipelineClaimAssessmentAttempts, forKey: Key.pipelineClaimAssessmentAttempts)
        persistenceStore.save(pendingTodoAcknowledgements, forKey: Key.pendingTodoAcknowledgements)
        persistenceStore.save(assistantHandoffs, forKey: Key.assistantHandoffs)
        persistenceStore.save(assistantChats, forKey: Key.assistantChats)
        persistenceStore.save(workflowActivity, forKey: Key.workflowActivity)
        persistenceStore.save(automationEvents, forKey: Key.automationEvents)
        persistenceStore.save(mrActionIntents, forKey: Key.mrActionIntents)
        persistenceStore.save(routedMRTodoReceipts, forKey: Key.routedMRTodoReceipts)
        persistenceStore.save(boardPins, forKey: Key.boardPins)
        persistenceStore.save(mrLifecycleLedger, forKey: Key.mrLifecycleLedger)
        defaults.removeObject(forKey: Key.autoRemoveFinishedMRs)
        defaults.removeObject(forKey: Key.showMergedMRCompletions)
        defaults.removeObject(forKey: Key.showClosedMRCompletions)
        defaults.set(boardGrouping.rawValue, forKey: Key.boardGrouping)
        persistenceStore.save(conflictReceipts, forKey: Key.conflictReceipts)
        persistenceStore.save(reReviewReceipts, forKey: Key.reReviewReceipts)
        persistenceStore.save(reReviewDraftBaselines, forKey: Key.reReviewDraftBaselines)
        defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        defaults.set(unreadReminderInterval.rawValue, forKey: Key.unreadReminderInterval)
        defaults.set(unreadReminderSound.rawValue, forKey: Key.unreadReminderSound)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(autoHandledEventBannersEnabled, forKey: Key.autoHandledEventBannersEnabled)
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
        persistenceStore.save(ignoredMergeRequests, forKey: Key.ignoredMergeRequests)
        persistenceStore.save(autoApproveOptOuts, forKey: Key.autoApproveOptOuts)
        persistenceStore.save(autoPublishOptOuts, forKey: Key.autoPublishOptOuts)
        persistenceStore.save(mergeSubmissions, forKey: Key.mergeSubmissions)
        persistenceStore.save(autoMergeOptOuts, forKey: Key.autoMergeOptOuts)
        let synchronized = persistenceStore.synchronize()
        if automationSaved && synchronized {
            lastSavedAutomation = automation
            if previousAutomation != automation { onAutomationChanged?(previousAutomation) }
        }
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
            Key.boardGrouping: MRBoardGrouping.withoutAutomation.rawValue,
            Key.onboardingCompleted: false,
            Key.launchAtLoginPreference: true,
            Key.hasLaunchedBefore: false,
        ])
    }

    private enum Key {
        static let conversationDestination = "conversationDestination"
        static let automation = "automation"
        static let automationReceipts = "automationReceipts"
        static let automationAttemptReceipts = "automationAttemptReceipts"
        static let authorFeedbackAttempts = "authorFeedbackAttempts"
        static let pipelineRefreshAttempts = "pipelineRefreshAttempts"
        static let pipelineClaimAssessmentAttempts = "pipelineClaimAssessmentAttempts"
        static let pendingTodoAcknowledgements = "pendingTodoAcknowledgements"
        static let boardPins = "boardPins"
        static let boardGrouping = "boardGrouping"
        static let mrLifecycleLedger = "mrLifecycleLedger"
        static let autoRemoveFinishedMRs = "autoRemoveFinishedMRs"
        static let showMergedMRCompletions = "showMergedMRCompletions"
        static let showClosedMRCompletions = "showClosedMRCompletions"
        static let conflictReceipts = "conflictReceipts"
        static let reReviewReceipts = "reReviewReceipts"
        static let reReviewDraftBaselines = "reReviewDraftBaselines"
        static let pendingCommentReviews = "pendingCommentReviews"
        static let commentReviewProgress = "commentReviewProgress"
        static let assistantHandoffs = "assistantHandoffs"
        static let assistantChats = "assistantChats"
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
        static let autoPublishOptOuts = "autoPublishOptOuts"
        static let mergeSubmissions = "mergeSubmissions"
        static let autoMergeOptOuts = "autoMergeOptOuts"
        static let ignoredMergeRequests = "ignoredMergeRequests"
        static let feedbackSuggestionDecisions = "feedbackSuggestionDecisions"
    }
}
