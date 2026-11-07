import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AutomaticEnvironmentRecoveryTests {
    @Test func temporaryFileFailureGetsOneFreshAutomaticAttemptAcrossRestarts() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let recovery = f.coordinator()
        await recovery.recover(host: "gitlab.example.test", username: "me")
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 1)
        #expect(f.settings.assistantHandoffs.first?.environmentRecoveryAttempted == true)
        #expect(f.settings.assistantHandoffs.last?.environmentRecoveryOf == f.original.id)
        #expect(f.instructions.contains("TMPDIR"))
        #expect(f.instructions.contains("re-read"))
        #expect(f.settings.assistantHandoffs.first?.execution?.state == .blocked)
    }

    @Test(arguments: ["account", "head", "discussion", "policy"])
    func changedEvidenceOrPolicyCannotStartRecovery(_ change: String) async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.change = change
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
        #expect(f.settings.assistantHandoffs.count == 1)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .cancelled, .interrupted, .succeeded])
    func anUncertainOrFinishedRunIsNeverAutomaticallyReplayed(_ state: AssistantJobExecution.State) async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.settings.assistantHandoffs[0].execution?.state = state
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
    }

    @Test(arguments: [AssistantJobExecution.State.succeeded, .cancelled, .interrupted])
    func changingTheStoredOriginalDuringFreshReadsPreventsRecovery(_ state: AssistantJobExecution.State) async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.storedStateDuringFetch = state
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(f.settings.assistantHandoffs.first?.environmentRecoveryAttempted != true)
    }

    @Test func aDisabledFeedbackRuleCannotBypassAnExcludingDiscussionWorkflow() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.settings.automation.authorFeedback.isEnabled = false
        f.settings.automation.authorFeedback.projects = ""
        f.settings.automation.workflowRules[.newDiscussion].mode = .assistant
        f.settings.automation.workflowRules[.newDiscussion].projects = "group/other"
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(f.settings.assistantHandoffs.first?.environmentRecoveryAttempted != true)
    }

    @Test func disabledConfiguredToolAccessCannotStartAnEnvironmentReplacement() async throws {
        let f = try Fixture(access: .configuredTools)
        defer { f.cleanUp() }
        f.settings.automation.allowAssistantTools = false
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
        #expect(f.settings.assistantHandoffs.count == 1)
        #expect(f.settings.assistantHandoffs.first?.environmentRecoveryAttempted != true)
    }

    @Test func aCodeTestFailureDoesNotBecomeAnEnvironmentRetry() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        f.settings.assistantHandoffs[0].execution?.output = "Assertion failed: expected 3, actual 2"
        await f.coordinator().recover(host: "gitlab.example.test", username: "me")
        #expect(f.launched == 0)
    }

    @MainActor private final class Fixture {
        let suite = "AutomaticEnvironmentRecoveryTests.\(UUID())"
        let defaults: UserDefaults
        let settings: SettingsManager
        let original: AssistantAutomationRunner.Handoff
        let request: GitLabMergeRequest
        var fetched = 0
        var launched = 0
        var instructions = ""
        var change: String?
        var storedStateDuringFetch: AssistantJobExecution.State?

        init(access: AssistantAutomationRunner.Access = .gitLabRead) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: .codex)
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
                {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Example MR",
                 "web_url":"https://gitlab.example.test/group/repo/-/merge_requests/2","state":"opened","draft":false,
                 "sha":"\(String(repeating: "a", count: 40))","source_branch":"fix","target_branch":"main","labels":[]}
                """.utf8))
            original = .init(id: UUID(), key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 1, iid: 2), username: "me", workspace: "", access: access),
                title: "Follow-up", prompt: "Inspect the current feedback", createdAt: Date(), allowsPush: false,
                followUpPushAllowed: true, execution: .init(state: .blocked,
                    output: "Mockito java.io.IOException: Operation not permitted at java.io.File.createTempFile"),
                taskPrompt: "Inspect current feedback", mergeRequestURL: request.webURL, workflow: .followUp,
                manual: false, expectedHeadSHA: request.sha)
            settings.assistantHandoffs = [original]
        }

        func coordinator() -> AutomaticEnvironmentRecovery {
            .init(settings: settings, fetch: { [self] _ in
                fetched += 1
                let changed = fetched > 1
                if changed, let storedStateDuringFetch { settings.assistantHandoffs[0].execution?.state = storedStateDuringFetch }
                let user = GitLabAuthenticatedUser(id: changed && change == "account" ? 8 : 3, username: "me")
                var live = request
                if changed && change == "head" {
                    let raw = try JSONEncoder().encode(request)
                    live = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(String(decoding: raw, as: UTF8.self)
                        .replacingOccurrences(of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40)).utf8))
                }
                if changed && change == "policy" { settings.automation.allowFollowUpPush = false }
                let discussion: [GitLabMergeRequestDiscussion] = changed && change == "discussion"
                    ? [.init(id: "changed", notes: [.init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"),
                        system: false, resolvable: nil, resolved: nil, resolvedBy: nil, body: "New expectation")])] : []
                return .init(request: live, user: user, discussions: discussion)
            }, launch: { [self] old, _, prompt in
                launched += 1; instructions = prompt
                let next = AssistantAutomationRunner.Handoff(id: UUID(), key: old.key, title: old.title,
                    prompt: prompt, createdAt: Date().addingTimeInterval(1), allowsPush: false,
                    followUpPushAllowed: true, execution: .init(state: .succeeded), taskPrompt: prompt,
                    mergeRequestURL: old.mergeRequestURL, workflow: .followUp, manual: false,
                    expectedHeadSHA: request.sha)
                settings.assistantHandoffs.append(next)
                return next
            })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}
