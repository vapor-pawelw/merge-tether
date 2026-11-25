import Foundation
import Observation

@MainActor @Observable
final class AssistantCLIHealthStore {
    struct Hold: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var issue: AssistantCLIHealthIssue
        let executable: URL
        let startedAt: Date
        var observedAt: Date? = nil
        var limitRecheck: LimitRecheck? = nil
        var detectedAt: Date { observedAt ?? startedAt }
        var limitCheckAt: Date? {
            guard issue.kind == .rateLimited, limitRecheck?.exhausted != true else { return nil }
            let resetCheckAt = issue.reportedReset?.addingTimeInterval(LimitRecheck.initialDelay)
            guard let nextAt = limitRecheck?.nextAt else { return resetCheckAt }
            return max(nextAt, resetCheckAt ?? nextAt)
        }
    }

    struct LimitRecheck: Codable, Equatable, Sendable {
        static let initialDelay: TimeInterval = 60
        private static let maximumDelay: TimeInterval = 3_600
        private var delay: TimeInterval = 0
        private var hourlyFailures = 0
        private(set) var nextAt: Date?
        var exhausted: Bool { hourlyFailures >= 3 }

        mutating func recordFailure(at now: Date, reset: Date?) {
            if delay == Self.maximumDelay { hourlyFailures += 1 }
            delay = min(Self.maximumDelay, max(Self.initialDelay, delay * 2))
            let backoff = now.addingTimeInterval(delay)
            nextAt = exhausted ? nil : max(backoff, reset?.addingTimeInterval(Self.initialDelay) ?? backoff)
        }
    }
    static let shared: AssistantCLIHealthStore = {
        let testing = Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return AssistantCLIHealthStore(defaults: testing
            ? UserDefaults(suiteName: "MergeTether-CLIHealthTests-\(UUID())")! : .standard, persists: !testing)
    }()
    private let defaults: UserDefaults
    private let persists: Bool
    private static let key = "assistantCLIHealth.v1"
    private var holds: [String: Hold]
    private var successfulStarts: [AutomationAssistant: Date] = [:]

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        holds = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Hold].self, from: $0) } ?? [:]
    }

    func hold(for assistant: AutomationAssistant) -> Hold? { holds[assistant.rawValue] }

    func record(_ issue: AssistantCLIHealthIssue, assistant: AutomationAssistant, executable: URL, startedAt: Date,
                observedAt: Date? = nil) {
        var issue = issue
        let detectedAt = observedAt ?? startedAt
        guard successfulStarts[assistant].map({ $0 < detectedAt }) ?? true else { return }
        let previous = hold(for: assistant)
        if let previous {
            guard previous.detectedAt <= detectedAt else { return }
            if previous.detectedAt == detectedAt && previous.issue == issue { return }
        }
        if issue.kind == .rateLimited, issue.reportedReset == nil {
            issue.resetsAt = previous?.issue.reportedReset
        }
        let recheck = issue.kind == .rateLimited ? previous?.limitRecheck : nil
        holds[assistant.rawValue] = .init(id: UUID(), issue: issue, executable: executable, startedAt: startedAt,
            observedAt: detectedAt, limitRecheck: recheck)
        save()
    }

    func recordFailedLimitCheck(_ assistant: AutomationAssistant, expectedID: UUID, checkedAt: Date,
                                reportedIssue: AssistantCLIHealthIssue? = nil) {
        guard var hold = hold(for: assistant), hold.id == expectedID,
              let dueAt = hold.limitCheckAt, checkedAt >= dueAt else { return }
        if let reportedIssue, let reset = reportedIssue.reportedReset, reset > checkedAt {
            hold.issue = reportedIssue
        }
        var recheck = hold.limitRecheck ?? LimitRecheck()
        recheck.recordFailure(at: checkedAt, reset: hold.issue.reportedReset)
        hold.limitRecheck = recheck
        holds[assistant.rawValue] = hold
        save()
    }

    func recordSuccess(assistant: AutomationAssistant, startedAt: Date) {
        successfulStarts[assistant] = max(successfulStarts[assistant] ?? .distantPast, startedAt)
        guard let hold = hold(for: assistant), hold.detectedAt <= startedAt else { return }
        holds[assistant.rawValue] = nil
        save()
    }

    @discardableResult
    func clear(_ assistant: AutomationAssistant, expectedID: UUID) -> Bool {
        guard let hold = hold(for: assistant), hold.id == expectedID else { return false }
        successfulStarts[assistant] = max(successfulStarts[assistant] ?? .distantPast, hold.detectedAt)
        holds[assistant.rawValue] = nil
        save()
        return true
    }

    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(holds) { defaults.set(data, forKey: Self.key) }
    }
}
