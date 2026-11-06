import Foundation
import Testing
@testable import GitLabTodos

@Suite struct AssistantJobSnapshotTests {
    @Test func rejectsChangedOrMissingHeadBeforeExecution() throws {
        try AssistantJobExecutor.validateHeadSnapshot(expected: "abc", actual: "abc")
        for pair: (String?, String?) in [("abc", "def"), (nil, "abc"), ("abc", nil), ("", "")] {
            #expect(throws: AssistantJobExecutor.ExecutionError.headChanged) {
                try AssistantJobExecutor.validateHeadSnapshot(expected: pair.0, actual: pair.1)
            }
        }
    }

    @MainActor @Test func refreshesOnlyTheHeadInstructionForAnExplicitRetry() {
        let result = AssistantAutomationRunner.refreshedTaskPrompt("Task: review\nExpected head: old\nReview the feedback.", expectedHeadSHA: "new")
        #expect(result.hasPrefix("Expected head: new\n"))
        #expect(!result.contains("Expected head: old"))
        #expect(result.contains("Review the feedback."))
    }
    @MainActor @Test func rejectsQueuedJobsAfterTheirOriginatingRuleChanges() throws {
        let original = AutomationSettings()
        var handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, manual: false, configurationSnapshot: original)
        try AssistantJobExecutor.validateConfiguration(handoff, automation: original)
        var changed = original
        changed.reviewRequested.isEnabled.toggle()
        #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            try AssistantJobExecutor.validateConfiguration(handoff, automation: changed)
        }
        handoff.configurationSnapshot = nil
        #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            try AssistantJobExecutor.validateConfiguration(handoff, automation: original)
        }
        handoff.manual = true
        try AssistantJobExecutor.validateConfiguration(handoff, automation: changed)
    }

    @MainActor @Test func unrelatedRepositoryScopeChangesDoNotInvalidateQueuedConfiguration() throws {
        let original = AutomationSettings()
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 7, iid: 11),
                       username: "me", workspace: "", access: .gitLabRead), title: "Review", prompt: "Review",
            createdAt: Date(), allowsPush: false, manual: false, configurationSnapshot: original)
        var scopeOnly = original
        scopeOnly.scope[.init(host: "gitlab.example.test", username: "me", projectID: 99, iid: nil)] = .paused
        try AssistantJobExecutor.validateConfiguration(handoff, automation: scopeOnly)
        #expect(scopeOnly.scope.resolve(.init(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)).active)
        var changedRule = scopeOnly
        changedRule.reviewRequested.isEnabled.toggle()
        #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            try AssistantJobExecutor.validateConfiguration(handoff, automation: changedRule)
        }
    }

    @MainActor @Test func manualExecutionCannotBypassAnIgnoredMergeRequest() throws {
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 7, iid: 11)
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead),
            title: "Manual", prompt: "Manual", createdAt: Date(), allowsPush: false, manual: true)
        try AssistantJobExecutor.validateIgnoredTarget(handoff, ignored: [])
        let ignored = MRAutomationScope.Target(host: work.host, username: "me", projectID: work.projectID, iid: work.iid)
        #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            try AssistantJobExecutor.validateIgnoredTarget(handoff, ignored: [ignored])
        }
    }

}
