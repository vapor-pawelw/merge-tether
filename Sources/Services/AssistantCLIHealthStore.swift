import Foundation
import Observation

@MainActor @Observable
final class AssistantCLIHealthStore {
    struct Hold: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let issue: AssistantCLIHealthIssue
        let executable: URL
        let startedAt: Date
        var observedAt: Date? = nil
        var detectedAt: Date { observedAt ?? startedAt }
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
        let detectedAt = observedAt ?? startedAt
        guard successfulStarts[assistant].map({ $0 < detectedAt }) ?? true else { return }
        if let previous = holds[assistant.rawValue] {
            guard previous.detectedAt <= detectedAt else { return }
            if previous.detectedAt == detectedAt && previous.issue == issue { return }
        }
        holds[assistant.rawValue] = .init(id: UUID(), issue: issue, executable: executable, startedAt: startedAt,
            observedAt: detectedAt)
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
