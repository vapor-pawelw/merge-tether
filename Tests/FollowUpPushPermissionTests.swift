import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct FollowUpPushPermissionTests {
    private let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)

    private func job(_ state: AssistantJobExecution.State? = .running, manual: Bool = false) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead),
              title: "Follow up", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: true,
              execution: state.map { .init(state: $0) }, manual: manual)
    }

    @Test func onlyActiveMatchingProviderAndPermittedScopeMayPush() {
        var configuration = AutomationSettings()
        configuration.assistant = .codex
        configuration.allowFollowUpPush = true
        #expect(FollowUpVerificationStore.canPush(job(), configuration: configuration))
        #expect(FollowUpVerificationStore.canPush(job(.queued), configuration: configuration))
        for state in [AssistantJobExecution.State.succeeded, .failed, .cancelled, .blocked, .interrupted] {
            #expect(!FollowUpVerificationStore.canPush(job(state), configuration: configuration))
        }
        #expect(!FollowUpVerificationStore.canPush(job(nil), configuration: configuration))
        configuration.allowFollowUpPush = false
        #expect(!FollowUpVerificationStore.canPush(job(), configuration: configuration))
        configuration.allowFollowUpPush = true
        configuration.assistant = .claude
        #expect(!FollowUpVerificationStore.canPush(job(), configuration: configuration))
        configuration.assistant = .codex
        configuration.scope.mode = .selected
        #expect(!FollowUpVerificationStore.canPush(job(), configuration: configuration))
        #expect(FollowUpVerificationStore.canPush(job(manual: true), configuration: configuration))
    }

    @Test func synchronizationRevokesStatusWithoutRemovingCompletedPublicationProof() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "FollowUpPushPermissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .codex
        settings.automation.allowFollowUpPush = true
        settings.assistantHandoffs = [job()]
        let status = FollowUpVerificationStore.recordURL(kind: "follow-up-runs", work: work, username: "me", in: folder)
        let receipt = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        let proof = Data("sealed remote publication proof".utf8)
        try proof.write(to: receipt)
        func isAllowed() throws -> Bool? {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any])?["pushAllowed"] as? Bool
        }
        FollowUpVerificationStore.synchronizeRuns(settings: settings, in: folder)
        #expect(try isAllowed() == true)
        settings.automation.scope.mode = .selected
        FollowUpVerificationStore.synchronizeRuns(settings: settings, in: folder)
        #expect(try isAllowed() == false)
        settings.automation.scope.mode = .all
        settings.assistantHandoffs[0].execution?.state = .succeeded
        FollowUpVerificationStore.synchronizeRuns(settings: settings, in: folder)
        #expect(try isAllowed() == false)
        #expect(try Data(contentsOf: receipt) == proof)
    }
}
