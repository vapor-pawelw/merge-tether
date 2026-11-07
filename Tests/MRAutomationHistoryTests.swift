import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRAutomationHistoryTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 13)
    private let start = Date(timeIntervalSince1970: 100)

    private func job(username: String = "me", host: String = "gitlab.example.test", projectID: Int = 7,
                     iid: Int = 13, at: Date, state: AssistantJobExecution.State = .failed,
                     finished: Date? = nil) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: projectID, iid: iid), username: username, workspace: "", access: .gitLabRead),
            title: "Follow up", prompt: "", createdAt: at, allowsPush: false,
            execution: .init(state: state, finishedAt: finished, error: "Process exited with status 1"))
    }

    private func workflow(username: String = "me", host: String = "gitlab.example.test") throws -> MergeWorkflowActivityEntry {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":13,"author":{"id":1,"username":"me","name":"Me"},"title":"Sample","web_url":"https://gitlab.example.test/group/repo/-/merge_requests/13","state":"opened","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        return .init(id: UUID().uuidString, event: .init(kind: .newDiscussion, mergeRequest: request,
            identity: "new-note", context: "Reviewer replied"), createdAt: start.addingTimeInterval(3),
            host: host, user: .init(id: 1, username: username), state: .failed)
    }

    @Test func chronologyIncludesApplicationFailureAfterSuccessfulWorkerAndKeepsAttemptNumbers() throws {
        let first = job(at: start)
        let second = job(at: start.addingTimeInterval(1), state: .succeeded, finished: start.addingTimeInterval(5))
        let event = MRAutomationEvent(id: UUID(), target: target, createdAt: start.addingTimeInterval(6),
            action: .followUp, origin: .automatic, state: .failed, message: "Fresh remote evidence is missing.", jobID: second.id)
        let workflow = try workflow()
        let history = MRAutomationHistory(target: target, handoffs: [second, first], workflows: [workflow], events: [event])
        #expect(history.entries.map(\.createdAt) == [event.createdAt, second.execution!.finishedAt!, workflow.createdAt, first.createdAt])
        let attempts = history.entries.compactMap { entry -> Int? in
            guard case .job(_, let attempt) = entry.source else { return nil }
            return attempt
        }
        #expect(attempts == [2, 1])
        guard case .event(let failure)? = history.entries.first?.source else { Issue.record("Missing application failure"); return }
        #expect(failure.message == "Fresh remote evidence is missing.")
        #expect(failure.jobID == second.id)
    }

    @Test func accountAndMergeRequestFenceApplyToEverySource() throws {
        let current = job(at: start)
        let excluded = [job(username: "other", at: start), job(host: "other.example.test", at: start),
                        job(projectID: 9, at: start), job(iid: 14, at: start)]
        let otherTarget = MRAutomationScope.Target(host: target.host, username: "other", projectID: 7, iid: 13)
        let event = MRAutomationEvent(id: UUID(), target: otherTarget, createdAt: start,
            action: .retry, origin: .manual, state: .failed, message: "Private diagnostic")
        let history = MRAutomationHistory(target: target, handoffs: excluded + [current],
            workflows: [try workflow(username: "other"), try workflow(host: "other.example.test")], events: [event])
        #expect(history.entries.count == 1)
        guard case .job(let visible, let attempt)? = history.entries.first?.source else { Issue.record("Missing current run"); return }
        #expect(visible.id == current.id)
        #expect(attempt == 1)
    }

    @Test func rejectedRetrySurvivesReloadWithoutAWorkerRunAndHistoryIsBounded() {
        let suite = "MRAutomationHistoryTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        for index in 0..<105 {
            settings.automationEvents.append(.init(id: UUID(), target: target,
                createdAt: start.addingTimeInterval(Double(index)), action: .retry, origin: .manual,
                state: .requested, message: nil))
        }
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .failed,
            message: "The selected account changed before retry.", now: start.addingTimeInterval(200))
        let reloaded = SettingsManager(defaults: defaults)
        #expect(reloaded.automationEvents.count == 100)
        #expect(reloaded.automationEvents.first?.message == "The selected account changed before retry.")
        #expect(reloaded.assistantHandoffs.isEmpty)
        for index in 0..<1_005 {
            let other = MRAutomationScope.Target(host: target.host, username: "me", projectID: index + 10, iid: 1)
            settings.automationEvents.append(.init(id: UUID(), target: other,
                createdAt: start.addingTimeInterval(Double(index)), action: .retry, origin: .manual,
                state: .requested, message: nil))
        }
        settings.recordAutomationEvent(target: target, action: .retry, origin: .manual, state: .failed,
            message: "Already running", now: start.addingTimeInterval(2_000))
        #expect(SettingsManager(defaults: defaults).automationEvents.count == 1_000)
    }
}
