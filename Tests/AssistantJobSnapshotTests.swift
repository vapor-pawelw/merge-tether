import Foundation
import Testing
@testable import GitLabTodos

@Suite struct AssistantJobSnapshotTests {
    @MainActor @Test func legacyJobsDecodeWithoutAssigningANewRoleOrCodingModel() throws {
        let old = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: "gitlab.example.test", projectID: 1, iid: 2),
                username: "me", workspace: "", access: .gitLabRead), title: "Legacy", prompt: "Task", createdAt: Date(), allowsPush: false)
        let restored = try JSONDecoder().decode(AssistantAutomationRunner.Handoff.self, from: JSONEncoder().encode(old))
        #expect(restored.codingModel == nil && restored.codingThinking == nil && restored.draftRepair == nil)
        #expect(restored.reviewModel == nil && restored.workflow == nil)
    }
    @MainActor @Test(arguments: [true, false])
    func ownMergeRequestCannotLaunchAReviewIncludingLegacyReviewRouting(explicitWorkflow: Bool) async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "OwnReviewScope.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let executable = directory.appending(path: "glab")
        try Data("""
            #!/bin/sh
            case "$*" in
              'config get host') printf '%s' 'gitlab.example.test' ;;
              'auth status') printf '%s' 'Logged in to gitlab.example.test as me' >&2 ;;
              'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
              'api /projects/7/merge_requests/11 '*) printf '%s' '{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},"title":"Fixture","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"opened","sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}' ;;
              *) exit 20 ;;
            esac
            """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .succeeded, summary: "Fixture worker ran"), output: "")
        })

        // when + then
        await #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            _ = try await AssistantAutomationRunner.launch(.codex, title: "Review",
                mergeRequestURL: URL(string: "https://gitlab.example.test/team/repo/-/merge_requests/11")!,
                prompt: "Review current diff", workspace: "", access: .gitLabRead,
                work: .init(host: "gitlab.example.test", projectID: 7, iid: 11), username: "me", settings: settings,
                isReview: true, mrWorkflow: explicitWorkflow ? .review : nil, manual: true,
                jobCoordinator: coordinator, configurationSnapshot: settings.automation)
        }
        #expect(settings.assistantHandoffs.isEmpty)
    }

    @MainActor @Test(arguments: ["unrelated-scope", "pause", "permission"])
    func launchRechecksCapturedAutomaticPolicyAfterFreshRequest(mutation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AssistantLaunchPolicy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.full, for: .codex)
        let captured = settings.automation
        let host = "gitlab-\(UUID().uuidString.lowercased()).example.test"
        let sha = String(repeating: "a", count: 40)
        let executable = root.appending(path: "glab")
        try Data("""
        #!/bin/sh
        root="${0%/*}"
        case "$*" in
          'config get host') printf '%s' '\(host)' ;;
          'auth status') printf '%s' 'Logged in to \(host) as me' >&2 ;;
          'api /user '*) printf '%s' '{"id":1,"username":"me"}' ;;
          'api /projects/7/merge_requests/11 '*)
            touch "$root/entered"
            count=0
            while test ! -f "$root/release" && test "$count" -lt 500; do sleep 0.01; count=$((count + 1)); done
            printf '%s' '{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},"title":"Fixture","web_url":"https://\(host)/team/repo/-/merge_requests/11","state":"opened","sha":"\(sha)","source_branch":"feature","target_branch":"main","labels":[]}' ;;
          *) exit 20 ;;
        esac
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        settings.glabPath = executable
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            .init(result: .init(status: .blocked, summary: "Fixture boundary", blocker: "No commands executed."), output: "")
        })
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 7, iid: 11)
        let task = Task {
            try await AssistantAutomationRunner.launch(.codex, title: "Fresh assessment",
                mergeRequestURL: URL(string: "https://\(host)/team/repo/-/merge_requests/11")!, prompt: "Fresh task",
                workspace: "", access: .gitLabRead, work: work, username: "me", settings: settings,
                mrWorkflow: .followUp, expectedHeadSHA: sha, jobCoordinator: coordinator, configurationSnapshot: captured)
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: root.appending(path: "entered").path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "entered").path))
        if mutation == "unrelated-scope" { settings.automation.scope[.init(host: host, username: "me", projectID: 99, iid: nil)] = .active }
        else if mutation == "pause" { settings.automation.scope[.init(host: host, username: "me", projectID: 7, iid: 11)] = .paused }
        else { settings.automation.allowFollowUpPush = false }
        try Data().write(to: root.appending(path: "release"))
        do {
            let handoff = try await task.value
            #expect(mutation == "unrelated-scope")
            coordinator.cancel(handoff.id)
        } catch {
            #expect(mutation != "unrelated-scope")
            #expect(error as? AssistantJobExecutor.ExecutionError == .disabledPermission)
        }
        #expect(settings.assistantHandoffs.count == (mutation == "unrelated-scope" ? 1 : 0))
    }

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
