import Foundation
import Testing
@testable import GitLabTodos

struct MRFollowUpAutomationTests {
    @Test func independentWorkflowDoesNotBorrowObsoleteLegacyFilters() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.authorFeedback.projects = "another/project"
        configuration.authorFeedback.promptTemplate = ""
        configuration.workflowRules[.newDiscussion].mode = .assistant
        #expect(configuration.followUpAutomationHold(for: request, target: target, requiresTodoRouting: false) == nil)
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .notConfigured)
    }

    @Test func anEnabledScopeDoesNotEnableTheFollowUpRule() throws {
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        let configuration = AutomationSettings()
        #expect(configuration.scope.permits(request, host: target.host, username: target.username))
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .ruleDisabled)
    }

    @Test func aMatchingDiscussionWorkflowCanEnableFollowUpWithoutTheLegacyRule() throws {
        // given
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.workflowRules[.newDiscussion].mode = .assistant
        // when + then
        #expect(configuration.followUpAutomationHold(for: request, target: target) == nil)
        configuration.workflowRules[.newDiscussion].targetBranches = "release"
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .workflowExcluded)
        configuration.authorFeedback.isEnabled = true
        #expect(configuration.followUpAutomationHold(for: request, target: target) == nil)
    }

    @Test func adoptionAndExecutionExplainDraftScopeSeparately() throws {
        // given
        let request = try MRDependencyPresentationTests().request(2, project: 1, draft: true)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.authorFeedback.isEnabled = true
        // when + then
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .draftPaused)
        #expect(configuration.followUpAutomationHold(for: request, target: target, includeDraftPolicy: false) == nil)
        configuration.scope[target] = .forceOn
        #expect(configuration.followUpAutomationHold(for: request, target: target) == nil)
        configuration.scope[target] = .paused
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .scopePaused)
    }

    @Test func permissionsDoNotSilentlyEnableFollowUpAndFiltersRemainEffective() throws {
        // given
        let request = try MRDependencyPresentationTests().request(2, project: 1)
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "author7", projectID: 1, iid: 2)
        var configuration = AutomationSettings()
        configuration.allowFollowUpPush = true
        // when + then
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .ruleDisabled)
        configuration.authorFeedback.isEnabled = true
        configuration.authorFeedback.projects = "group/other"
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .projectExcluded)
        configuration.authorFeedback.projects = ""
        configuration.authorFeedback.promptTemplate = " "
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .notConfigured)
        configuration.packageDecision = .disabled
        #expect(configuration.followUpAutomationHold(for: request, target: target) == .packageDisabled)
    }
}
