import Foundation
import Observation

@MainActor
@Observable
final class SettingsManager {
    private let defaults: UserDefaults
    @ObservationIgnored private var lastSavedAutomation: AutomationSettings?
    @ObservationIgnored var onAutomationChanged: ((AutomationSettings) -> Void)?

    var refreshInterval: RefreshInterval
    var unreadReminderInterval: UnreadReminderInterval
    var unreadReminderSound: ReminderSound
    var notificationsEnabled: Bool
    var lastSeenTodoIDs: Set<Int>
    var onboardingCompleted: Bool
    var glabPath: URL?
    var resolvedHost: String?
    var launchAtLoginPreference: Bool
    var lastMenuOpenedAt: Date?
    var lastMenuSection: String?
    /// Managed MRs where the user turned off automatic approval.
    var autoApproveOptOuts: Set<MRAutomationScope.Target>
    var ignoredMergeRequests: Set<MRAutomationScope.Target>
    var automation: AutomationSettings
    var automationReceipts: Set<TodoAutomationReceipt>
    var automationAttemptReceipts: Set<TodoAutomationReceipt>
    var authorFeedbackAttempts: Set<AuthorFeedbackAttempt>
    var pendingTodoAcknowledgements: Set<TodoActionAcknowledgement>
    var conflictReceipts: Set<MergeConflictReceipt>
    var reReviewReceipts: [ReReviewReceipt.Key: ReReviewReceipt]
    var reReviewDraftBaselines: [MRAutomationScope.Target: Int]
    var assistantHandoffs: [AssistantAutomationRunner.Handoff]
    var assistantChats: [AssistantAutomationRunner.ChatKey: String]
    var workflowActivity: [MergeWorkflowActivityEntry]
    var mrActionIntents: [MRTodoIntent]
    var routedMRTodoReceipts: Set<MRTodoRouteReceipt>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.registerDefaults(in: defaults)

        automation = defaults.data(forKey: Key.automation)
            .flatMap { try? JSONDecoder().decode(AutomationSettings.self, from: $0) }
            ?? AutomationSettings()
        automationReceipts = defaults.data(forKey: Key.automationReceipts)
            .flatMap { try? JSONDecoder().decode(Set<TodoAutomationReceipt>.self, from: $0) }
            ?? []
        automationAttemptReceipts = defaults.data(forKey: Key.automationAttemptReceipts)
            .flatMap { try? JSONDecoder().decode(Set<TodoAutomationReceipt>.self, from: $0) } ?? []
        authorFeedbackAttempts = defaults.data(forKey: Key.authorFeedbackAttempts)
            .flatMap { try? JSONDecoder().decode(Set<AuthorFeedbackAttempt>.self, from: $0) } ?? []
        pendingTodoAcknowledgements = defaults.data(forKey: Key.pendingTodoAcknowledgements)
            .flatMap { try? JSONDecoder().decode(Set<TodoActionAcknowledgement>.self, from: $0) } ?? []
        assistantHandoffs = defaults.data(forKey: Key.assistantHandoffs)
            .flatMap { try? JSONDecoder().decode([AssistantAutomationRunner.Handoff].self, from: $0) } ?? []
        assistantChats = defaults.data(forKey: Key.assistantChats)
            .flatMap { try? JSONDecoder().decode([AssistantAutomationRunner.ChatKey: String].self, from: $0) } ?? [:]
        workflowActivity = defaults.data(forKey: Key.workflowActivity)
            .flatMap { try? JSONDecoder().decode([MergeWorkflowActivityEntry].self, from: $0) } ?? []
        mrActionIntents = defaults.data(forKey: Key.mrActionIntents)
            .flatMap { try? JSONDecoder().decode([MRTodoIntent].self, from: $0) } ?? []
        routedMRTodoReceipts = defaults.data(forKey: Key.routedMRTodoReceipts)
            .flatMap { try? JSONDecoder().decode(Set<MRTodoRouteReceipt>.self, from: $0) } ?? []
        conflictReceipts = defaults.data(forKey: Key.conflictReceipts)
            .flatMap { try? JSONDecoder().decode(Set<MergeConflictReceipt>.self, from: $0) }
            ?? []
        reReviewReceipts = defaults.data(forKey: Key.reReviewReceipts)
            .flatMap { try? JSONDecoder().decode([ReReviewReceipt.Key: ReReviewReceipt].self, from: $0) } ?? [:]
        reReviewDraftBaselines = defaults.data(forKey: Key.reReviewDraftBaselines)
            .flatMap { try? JSONDecoder().decode([MRAutomationScope.Target: Int].self, from: $0) } ?? [:]

        let rawInterval = defaults.integer(forKey: Key.refreshInterval)
        self.refreshInterval = RefreshInterval(rawValue: rawInterval) ?? .fiveMinutes
        let rawReminderInterval = defaults.integer(forKey: Key.unreadReminderInterval)
        self.unreadReminderInterval = UnreadReminderInterval(rawValue: rawReminderInterval) ?? .fiveMinutes
        let rawReminderSound = defaults.string(forKey: Key.unreadReminderSound) ?? ReminderSound.off.rawValue
        self.unreadReminderSound = ReminderSound(rawValue: rawReminderSound) ?? .off
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        self.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        self.launchAtLoginPreference = defaults.bool(forKey: Key.launchAtLoginPreference)
        self.resolvedHost = defaults.string(forKey: Key.resolvedHost)
        let storedMenuOpenedAt = defaults.double(forKey: Key.lastMenuOpenedAt)
        self.lastMenuOpenedAt = storedMenuOpenedAt > 0
            ? Date(timeIntervalSince1970: storedMenuOpenedAt)
            : nil

        self.lastMenuSection = defaults.string(forKey: Key.lastMenuSection)
        self.ignoredMergeRequests = defaults.data(forKey: Key.ignoredMergeRequests)
            .flatMap { try? JSONDecoder().decode(Set<MRAutomationScope.Target>.self, from: $0) } ?? []
        self.autoApproveOptOuts = defaults.data(forKey: Key.autoApproveOptOuts)
            .flatMap { try? JSONDecoder().decode(Set<MRAutomationScope.Target>.self, from: $0) } ?? []

        if let pathString = defaults.string(forKey: Key.glabPath), !pathString.isEmpty {
            self.glabPath = URL(fileURLWithPath: pathString)
        } else {
            self.glabPath = nil
        }

        if let data = defaults.data(forKey: Key.lastSeenTodoIDs),
           let decoded = try? JSONDecoder().decode([Int].self, from: data)
        {
            self.lastSeenTodoIDs = Set(decoded)
        } else {
            self.lastSeenTodoIDs = []
        }
        for handoff in assistantHandoffs {
            let target = MRAutomationScope.Target(host: handoff.key.work.host, username: handoff.key.username,
                projectID: handoff.key.work.projectID, iid: handoff.key.work.iid)
            for (noteID, revision) in handoff.verifiedFeedbackNotes ?? [:] {
                authorFeedbackAttempts.insert(.init(target: target, noteID: noteID, revision: revision))
            }
        }
        lastSavedAutomation = automation
    }

    func save() {
        let previousAutomation = lastSavedAutomation ?? automation
        lastSavedAutomation = automation
        if let data = try? JSONEncoder().encode(automation) {
            defaults.set(data, forKey: Key.automation)
        }
        if let data = try? JSONEncoder().encode(automationReceipts) {
            defaults.set(data, forKey: Key.automationReceipts)
        }
        if let data = try? JSONEncoder().encode(automationAttemptReceipts) {
            defaults.set(data, forKey: Key.automationAttemptReceipts)
        }
        if let data = try? JSONEncoder().encode(authorFeedbackAttempts) {
            defaults.set(data, forKey: Key.authorFeedbackAttempts)
        }
        if let data = try? JSONEncoder().encode(pendingTodoAcknowledgements) {
            defaults.set(data, forKey: Key.pendingTodoAcknowledgements)
        }
        if let data = try? JSONEncoder().encode(assistantHandoffs) {
            defaults.set(data, forKey: Key.assistantHandoffs)
        }
        if let data = try? JSONEncoder().encode(assistantChats) {
            defaults.set(data, forKey: Key.assistantChats)
        }
        if let data = try? JSONEncoder().encode(workflowActivity) {
            defaults.set(data, forKey: Key.workflowActivity)
        }
        if let data = try? JSONEncoder().encode(mrActionIntents) { defaults.set(data, forKey: Key.mrActionIntents) }
        if let data = try? JSONEncoder().encode(routedMRTodoReceipts) { defaults.set(data, forKey: Key.routedMRTodoReceipts) }
        if let data = try? JSONEncoder().encode(conflictReceipts) {
            defaults.set(data, forKey: Key.conflictReceipts)
        }
        if let data = try? JSONEncoder().encode(reReviewReceipts) {
            defaults.set(data, forKey: Key.reReviewReceipts)
        }
        if let data = try? JSONEncoder().encode(reReviewDraftBaselines) {
            defaults.set(data, forKey: Key.reReviewDraftBaselines)
        }
        defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        defaults.set(unreadReminderInterval.rawValue, forKey: Key.unreadReminderInterval)
        defaults.set(unreadReminderSound.rawValue, forKey: Key.unreadReminderSound)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
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
        if let data = try? JSONEncoder().encode(Array(lastSeenTodoIDs).sorted()) {
            defaults.set(data, forKey: Key.lastSeenTodoIDs)
        }
        if let lastMenuOpenedAt {
            defaults.set(lastMenuOpenedAt.timeIntervalSince1970, forKey: Key.lastMenuOpenedAt)
        } else {
            defaults.removeObject(forKey: Key.lastMenuOpenedAt)
        }
        if let data = try? JSONEncoder().encode(ignoredMergeRequests) {
            defaults.set(data, forKey: Key.ignoredMergeRequests)
        }
        if let data = try? JSONEncoder().encode(autoApproveOptOuts) {
            defaults.set(data, forKey: Key.autoApproveOptOuts)
        }
        if let lastMenuSection {
            defaults.set(lastMenuSection, forKey: Key.lastMenuSection)
        } else {
            defaults.removeObject(forKey: Key.lastMenuSection)
        }
        if previousAutomation != automation { onAutomationChanged?(previousAutomation) }
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
            Key.onboardingCompleted: false,
            Key.launchAtLoginPreference: true,
            Key.hasLaunchedBefore: false,
        ])
    }

    private enum Key {
        static let automation = "automation"
        static let automationReceipts = "automationReceipts"
        static let automationAttemptReceipts = "automationAttemptReceipts"
        static let authorFeedbackAttempts = "authorFeedbackAttempts"
        static let pendingTodoAcknowledgements = "pendingTodoAcknowledgements"
        static let conflictReceipts = "conflictReceipts"
        static let reReviewReceipts = "reReviewReceipts"
        static let reReviewDraftBaselines = "reReviewDraftBaselines"
        static let assistantHandoffs = "assistantHandoffs"
        static let assistantChats = "assistantChats"
        static let workflowActivity = "workflowActivity"
        static let mrActionIntents = "mrActionIntents"
        static let routedMRTodoReceipts = "routedMRTodoReceipts"
        static let refreshInterval = "refreshInterval"
        static let unreadReminderInterval = "unreadReminderInterval"
        static let unreadReminderSound = "unreadReminderSound"
        static let notificationsEnabled = "notificationsEnabled"
        static let lastSeenTodoIDs = "lastSeenTodoIDs"
        static let onboardingCompleted = "onboardingCompleted"
        static let glabPath = "glabPath"
        static let resolvedHost = "resolvedHost"
        static let launchAtLoginPreference = "launchAtLoginPreference"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let lastMenuOpenedAt = "lastMenuOpenedAt"
        static let lastMenuSection = "lastMenuSection"
        static let autoApproveOptOuts = "autoApproveOptOuts"
        static let ignoredMergeRequests = "ignoredMergeRequests"
    }
}
