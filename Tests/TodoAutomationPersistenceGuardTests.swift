import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct TodoAutomationPersistenceGuardTests {
    @Test(arguments: ["healthy", "corruptAttempt", "dropAttemptWrite", "corruptCompletion", "unrelatedHold"], [false, true])
    func requiredAttemptJournalPrecedesEvenAManualLegacyShell(scenario: String, manual: Bool) async throws {
        let name = "TodoAutomationPersistenceGuardTests-\(UUID())"
        let defaults = try #require(AttemptFaultDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if scenario == "corruptAttempt" { defaults.set(Data("broken".utf8), forKey: "automationAttemptReceipts") }
        if scenario == "corruptCompletion" { defaults.set(Data("broken".utf8), forKey: "automationReceipts") }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appending(path: "executions")
        let todo = try #require(GlabService.decodeTodos(Data(#"[{"id":42,"action_name":"review_requested","target_type":"MergeRequest","target_url":"https://gitlab.example.test/team/repo/-/merge_requests/2","body":"Review","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Team / Repo","path_with_namespace":"team/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":2,"iid":2,"title":"Example","state":"opened","author":{"id":8,"username":"anna","name":"Anna"}}}]"#.utf8)).first)
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        settings.automation.reviewRequested.runner = .shell
        settings.automation.reviewRequested.projects = "team/repo"
        settings.automation.reviewRequested.command = "printf x >> '\(counter.path)'"
        settings.automation.reviewRequested.markDoneOnSuccess = true
        settings.save()
        if scenario == "dropAttemptWrite" { defaults.rejectedKey = "automationAttemptReceipts" }
        if scenario == "unrelatedHold" { settings.recordPersistenceFailure("mergeSubmissions") }
        let service = TodoAutomationService(canAutomate: { _ in true })
        let acknowledged = try await service.prepareToAcknowledge(todo, event: .reviewRequested,
            host: "gitlab.example.test", username: "me", settings: settings, glab: GlabService(),
            manual: manual, isPending: { true })
        let expectedExecution = scenario == "healthy"
        #expect(FileManager.default.fileExists(atPath: counter.path) == expectedExecution)
        #expect(acknowledged == expectedExecution)
        #expect(settings.automation.reviewRequested.runner == .shell)
    }
}

private final class AttemptFaultDefaults: UserDefaults, @unchecked Sendable {
    var rejectedKey: String?
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName != rejectedKey { super.set(value, forKey: defaultName) }
    }
}
