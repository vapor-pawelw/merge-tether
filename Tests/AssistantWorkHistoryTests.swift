import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AssistantWorkHistoryTests {
    private let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)

    private func job(_ state: AssistantJobExecution.State?, createdAt: Date, username: String = "me") -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: work, username: username, workspace: "", access: .gitLabRead),
              title: "Follow up", prompt: "", createdAt: createdAt, allowsPush: false,
              execution: state.map { .init(state: $0) })
    }

    @Test func successfulHistoryDoesNotBlockMergeButANewerFailedJobDoes() {
        let succeeded = job(.succeeded, createdAt: .distantPast)
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [succeeded], for: work, username: "me"))
        let failed = job(.failed, createdAt: Date())
        #expect(AssistantJobExecution.hasUnfinishedWork(in: [succeeded, failed], for: work, username: "me"))
        let recovered = job(.succeeded, createdAt: .distantFuture)
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [succeeded, failed, recovered], for: work, username: "me"))
    }

    @Test func anotherAccountsFailedJobCannotBlockCurrentAccount() {
        let succeeded = job(.succeeded, createdAt: .distantPast)
        let other = job(.failed, createdAt: Date(), username: "another")
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [succeeded, other], for: work, username: "me"))
    }

    @Test func legacyUnknownCompletionAndCancellationBothBlockAutomaticMerge() {
        #expect(AssistantJobExecution.hasUnfinishedWork(in: [job(nil, createdAt: Date())], for: work, username: "me"))
        #expect(AssistantJobExecution.hasUnfinishedWork(in: [job(.cancelled, createdAt: Date())], for: work, username: "me"))
        #expect(!AssistantJobExecution.hasUnfinishedWork(in: [], for: work, username: "me"))
    }
}
