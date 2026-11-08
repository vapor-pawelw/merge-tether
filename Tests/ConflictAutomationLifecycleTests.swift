import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ConflictAutomationLifecycleTests {
    @Test(arguments: [false, true])
    func grantingPushAdvancesThePlanOnceAndDoesNotReplayThePushAttempt(_ isDraft: Bool) async throws {
        try await withHarness(isDraft: isDraft) { harness in
            if isDraft {
                try await harness.poll()
                #expect(harness.launches.isEmpty && harness.settings.conflictReceipts.isEmpty)
                harness.settings.automation.scope.setEnabled(true,
                    for: .init(host: Harness.host, username: "me", projectID: 1, iid: 2), isDraft: true)
            }
            harness.settings.automation.allowConflictPush = false
            try await harness.poll()
            #expect(harness.launches == [false])
            #expect(harness.settings.conflictReceipts.first?.allowsPush == false)
            #expect(harness.monitor.conflictAutomationState(for: harness.request) == .requiresAttention)

            harness.settings.automation.allowConflictPush = true
            #expect(harness.monitor.conflictAutomationState(for: harness.request) == .available)
            harness.monitor.automationConfigurationChanged()
            try await harness.waitUntilIdle()
            #expect(harness.launches == [false, true])
            #expect(harness.settings.conflictReceipts.count == 1)
            #expect(harness.settings.conflictReceipts.first?.allowsPush == true)
            #expect(harness.settings.conflictReceipts.first?.jobID == harness.settings.assistantHandoffs.last?.id)
            #expect(harness.monitor.conflictAutomationState(for: harness.request) == .requiresAttention)

            try await harness.poll()
            #expect(harness.launches == [false, true])
        }
    }

    @Test func unknownOrPushAuthorizedReceiptsRemainConservativeAfterPolicyChanges() async throws {
        for authorization in [nil, true] as [Bool?] {
            try await withHarness { harness in
                harness.settings.conflictReceipts = [harness.receipt(allowsPush: authorization)]
                try await harness.poll()
                #expect(harness.launches.isEmpty)
                harness.settings.automation.allowFollowUpPush.toggle()
                harness.monitor.automationConfigurationChanged()
                try await harness.waitUntilIdle()
                #expect(harness.launches.isEmpty)
                #expect(harness.monitor.conflictAutomationState(for: harness.request) == .requiresAttention)
            }
        }
    }

    @Test func changedSourceHeadPreventsAnAttemptAndPausedScopeDoesNotSchedule() async throws {
        try await withHarness { harness in
            try harness.write("source-head", String(repeating: "c", count: 40))
            try await harness.poll()
            #expect(harness.launches.isEmpty)
            #expect(harness.settings.conflictReceipts.isEmpty)
            harness.settings.automation.scope.mode = .selected
            try harness.write("source-head", Harness.source)
            try await harness.poll()
            #expect(harness.launches.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func cancellingPreparationRestoresTheLeaseUntilTheLauncherIsEntered(_ existingPlan: Bool) async throws {
        try await withHarness { harness in
            if existingPlan {
                harness.settings.automation.allowConflictPush = false
                try await harness.poll()
                harness.settings.automation.allowConflictPush = true
            }
            let previous = harness.settings.conflictReceipts.first
            let expectedEntries = harness.launcherEntries
            try harness.write("pause-stack", "yes")
            harness.monitor.refreshIfNeeded()
            try await harness.waitForFile("stack-started")
            #expect(harness.settings.conflictReceipts.first?.allowsPush == true)
            #expect(harness.launcherEntries == expectedEntries)

            harness.canAutomate = false
            harness.settings.automation.allowFollowUpPush.toggle()
            harness.monitor.automationConfigurationChanged()
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                let restored = previous.map { old in
                    harness.settings.conflictReceipts.first?.allowsPush == old.allowsPush
                        && harness.settings.conflictReceipts.first?.jobID == old.jobID
                } ?? harness.settings.conflictReceipts.isEmpty
                if restored && !harness.monitor.isLoading { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(harness.launcherEntries == expectedEntries)
            if let previous {
                #expect(harness.settings.conflictReceipts.first?.allowsPush == previous.allowsPush)
                #expect(harness.settings.conflictReceipts.first?.jobID == previous.jobID)
            } else { #expect(harness.settings.conflictReceipts.isEmpty) }
            #expect(harness.monitor.conflictAutomationState(for: harness.request) == .available)

            try? FileManager.default.removeItem(at: harness.directory.appending(path: "pause-stack"))
            try harness.write("release-stack", "yes")
            harness.canAutomate = true
            try await harness.poll()
            #expect(harness.launcherEntries == expectedEntries + 1)
            #expect(harness.settings.conflictReceipts.first?.allowsPush == true)
        }
    }

    @Test(arguments: ["draft", "closed"])
    func freshIneligibleObservationCancelsWaitingConflictPreparationWithoutChangingConfiguration(_ state: String) async throws {
        try await withHarness { harness in
            try harness.write("pause-stack", "yes")
            harness.monitor.refreshIfNeeded()
            try await harness.waitForFile("stack-started")
            let configuration = harness.settings.automation
            let original = try String(contentsOf: harness.directory.appending(path: "request.json"), encoding: .utf8)
            let changed = state == "draft" ? original.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
                : original.replacingOccurrences(of: "\"state\":\"opened\"", with: "\"state\":\"closed\"")
            try harness.write("request.json", changed)
            var projected = configuration.scope
            projected[.init(host: Harness.host, username: "me", projectID: 1, iid: 2)] = .paused
            harness.monitor.cancelRuntimePreparation(outsideScope: projected)
            try harness.write("release-stack", "yes")
            try await harness.waitUntilIdle()
            #expect(harness.settings.automation == configuration)
            #expect(harness.launcherEntries == 0 && harness.settings.assistantHandoffs.isEmpty)
            #expect(harness.settings.conflictReceipts.isEmpty)
        }
    }

    @Test func aLauncherErrorKeepsTheReceiptBecauseExternalWorkMayHaveStarted() async throws {
        try await withHarness { harness in
            harness.launchFails = true
            try await harness.poll()
            #expect(harness.launcherEntries == 1)
            #expect(harness.settings.conflictReceipts.first?.allowsPush == true)
            #expect(harness.settings.conflictReceipts.first?.jobID == nil)
            harness.settings.automation.allowFollowUpPush.toggle()
            harness.monitor.automationConfigurationChanged()
            try await harness.waitUntilIdle()
            #expect(harness.launcherEntries == 1)
            #expect(harness.monitor.conflictAutomationState(for: harness.request) == .requiresAttention)
        }
    }

    private func withHarness(isDraft: Bool = false, _ body: (Harness) async throws -> Void) async throws {
        let harness = try Harness(isDraft: isDraft)
        defer { harness.cleanUp() }
        try await body(harness)
    }

    @MainActor
    private final class Harness {
        static let host = "gitlab.example.test"
        static let source = String(repeating: "a", count: 40)
        static let target = String(repeating: "b", count: 40)
        let directory: URL
        let defaults: UserDefaults
        let suite = "ConflictAutomationLifecycleTests.\(UUID())"
        let settings: SettingsManager
        let glab: GlabService
        let request: GitLabMergeRequest
        var launches: [Bool] = []
        var canAutomate = true
        var launcherEntries = 0
        var launchFails = false
        private enum LaunchError: Error { case uncertain }
        lazy var monitor = AuthoredMergeRequestMonitor(settings: settings, glab: glab, notifications: NotificationService(),
            canAutomate: { [self] _ in canAutomate }, conflictLauncher: { [self] input, settings in
                launcherEntries += 1
                if launchFails { throw LaunchError.uncertain }
                #expect(input.head == Self.source)
                #expect(input.prompt.contains("at \(Self.target)"))
                let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: input.assistant, work: input.work,
                    username: input.username, workspace: "", access: input.access), title: input.title, prompt: input.prompt,
                    createdAt: Date(), allowsPush: input.allowsPush, execution: .init(state: .blocked),
                    taskPrompt: input.prompt, expectedHeadSHA: input.head, configurationSnapshot: settings.automation)
                settings.assistantHandoffs.append(job)
                settings.save()
                launches.append(input.allowsPush)
                return job
            })

        init(isDraft: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = true
            settings.automation.packageDecision = .enabled
            settings.automation.conflictTasksEnabled = true
            settings.automation.allowAssistantTools = true
            settings.automation.assistantToolProjects = "g/p"
            settings.automation.allowConflictPush = true
            settings.automation.conflictPushProjects = "g/p"
            let json = """
                {"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Conflict",
                 "web_url":"https://\(Self.host)/g/p/-/merge_requests/2","state":"opened","draft":\(isDraft),
                 "sha":"\(Self.source)","source_project_id":1,"source_branch":"feature","target_project_id":1,
                 "target_branch":"main","labels":[],"has_conflicts":true,"detailed_merge_status":"conflict"}
                """
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
            glab = GlabService()
            glab.currentUsername = "me"
            glab.resolvedHost = Self.host
            glab.authStatus = .authenticated
            glab.glabPath = directory.appending(path: "glab")
            try write("request.json", json)
            try write("source-head", Self.source)
            try write("glab", """
                #!/bin/sh
                set -eu
                cd "$(dirname "$0")"
                case "$*" in *--method*|*--raw-field*|*--field*) exit 200 ;; esac
                case "$2" in
                  /user) printf '%s' '{"id":3,"username":"me"}' ;;
                  /merge_requests\\?scope=created_by_me*) printf '['; cat request.json; printf ']' ;;
                  /projects/1/merge_requests/2) cat request.json ;;
                  */approval_state) printf '%s' '{"rules":[]}' ;;
                  */discussions*|*/draft_notes*) printf '%s' '[]' ;;
                  */repository/branches/feature) printf '{"commit":{"id":"'; cat source-head; printf '"}}' ;;
                  */repository/branches/main) printf '%s' '{"commit":{"id":"\(Self.target)"}}' ;;
                  /projects/1/merge_requests\\?*)
                    if [ -e pause-stack ]; then
                      touch stack-started
                      while [ ! -e release-stack ]; do sleep 0.02; done
                    fi
                    printf '%s' '[]' ;;
                  /projects/1) printf '%s' '{"default_branch":"main"}' ;;
                  */raw_diffs) printf '%s' 'diff --git a/A b/A' ;;
                  *) printf '%s' '{}' ;;
                esac
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appending(path: "glab").path)
        }

        func receipt(allowsPush: Bool?) -> MergeConflictReceipt {
            .init(host: Self.host, userID: 3, projectID: 1, iid: 2,
                sourceSHA: Self.source, targetSHA: Self.target, allowsPush: allowsPush)
        }

        func poll() async throws { monitor.refreshIfNeeded(); try await waitUntilIdle() }
        func waitForFile(_ name: String) async throws {
            let path = directory.appending(path: name).path
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(FileManager.default.fileExists(atPath: path))
        }
        func waitUntilIdle() async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if !monitor.isLoading, monitor.conflictAutomationState(for: request) != .processing { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Conflict scheduler did not finish preparing")
        }
        func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: directory.appending(path: name)) }
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
