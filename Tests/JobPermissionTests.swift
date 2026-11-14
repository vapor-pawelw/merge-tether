import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite("Job permissions")
struct JobPermissionTests {
    private let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)

    private func followUpJob(manual: Bool, allowsPush: Bool = false) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead),
              title: "Follow up", prompt: "", createdAt: Date(), allowsPush: allowsPush, followUpPushAllowed: true,
              execution: .init(state: .running), manual: manual)
    }

    @Test func jobsTheUserStartsKeepPermissionsInManualAndWithAutomationSwitchedOff() {
        // given
        var configured = AutomationSettings()
        configured.applyPreset(.full, for: .codex)
        var manualPreset = configured
        manualPreset.applyPreset(.manual, for: .codex)
        var suspended = configured
        suspended.isGloballySuspended = true

        for configuration in [manualPreset, suspended] {
            // then
            #expect(configuration.permitsFollowUpPush(manual: true))
            #expect(!configuration.permitsFollowUpPush(manual: false))
            #expect(configuration.permitsOwnThreadResolution(manual: true))
            #expect(!configuration.permitsOwnThreadResolution(manual: false))
            #expect(configuration.permitsConflictPush(project: "group/repo", manual: true))
            #expect(!configuration.permitsConflictPush(project: "group/repo"))
        }
        #expect(configured.permitsFollowUpPush(manual: false) && configured.permitsConflictPush(project: "group/repo"))
    }

    @Test func untouchedDefaultsGrantNoWritesBeforeAPresetIsChosen() {
        // given
        let undecided = AutomationSettings()

        // then
        #expect(undecided.allowFollowUpPush && undecided.autoResolveOwnReviewThreads)
        #expect(!undecided.permitsFollowUpPush(manual: true))
        #expect(!undecided.permitsOwnThreadResolution(manual: true))
        #expect(!undecided.permitsConflictPush(project: "group/repo", manual: true))
    }

    @Test func permissionsStillBindJobsTheUserStarts() {
        // given
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.applyPreset(.manual, for: .codex)

        // when
        configuration.allowFollowUpPush = false
        configuration.autoResolveOwnReviewThreads = false
        configuration.conflictPushProjects = "group/other"

        // then
        #expect(!configuration.permitsFollowUpPush(manual: true))
        #expect(!configuration.permitsOwnThreadResolution(manual: true))
        #expect(!configuration.permitsConflictPush(project: "group/repo", manual: true))
        configuration.allowAssistantTools = false
        #expect(!configuration.permitsConflictPush(project: "group/other", manual: true))
    }

    @Test func manualConflictPushDoesNotNeedAutomaticConflictTasks() {
        // given
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)

        // when
        configuration.conflictTasksEnabled = false

        // then
        #expect(configuration.permitsConflictPush(project: "group/repo", manual: true))
        #expect(!configuration.permitsConflictPush(project: "group/repo"))
    }

    @Test func switchingToManualKeepsPermissionsButAFirstManualChoiceStartsWithoutThem() {
        // given
        var existing = AutomationSettings()
        existing.applyPreset(.full, for: .codex)

        // when
        existing.applyPreset(.manual, for: .codex)
        var fresh = AutomationSettings()
        fresh.applyPreset(.manual, for: .codex)

        // then
        #expect(existing.matchingPreset == .manual && !existing.hasEnabledAutomation)
        #expect(existing.allowFollowUpPush && existing.allowConflictPush)
        #expect(existing.allowAssistantTools && existing.autoResolveOwnReviewThreads)
        #expect(!existing.autoMergeEnabled && !existing.autoApproveEnabled && !existing.autoResolveAcceptedFeedback)
        #expect(!fresh.allowFollowUpPush && !fresh.allowConflictPush)
        #expect(!fresh.allowAssistantTools && !fresh.autoResolveOwnReviewThreads)
    }

    @Test func executorAcceptsUserStartedDeliveryButRejectsAutomaticDeliveryWhileSwitchedOff() throws {
        // given
        var configuration = AutomationSettings()
        configuration.applyPreset(.full, for: .codex)
        configuration.isGloballySuspended = true

        // then
        try AssistantJobExecutor.validateConfiguration(followUpJob(manual: true), automation: configuration)
        #expect(throws: AssistantJobExecutor.ExecutionError.self) {
            try AssistantJobExecutor.validateConfiguration(followUpJob(manual: false), automation: configuration)
        }
    }

    @Test func privateAutomaticWorkDoesNotRevokePushForJobsTheUserStarts() {
        // given
        var configuration = AutomationSettings()
        configuration.assistant = .codex
        configuration.allowFollowUpPush = true

        // when
        configuration.allowAutomaticPublicActions = false

        // then
        #expect(FollowUpVerificationStore.canPush(followUpJob(manual: true), configuration: configuration))
        #expect(!FollowUpVerificationStore.canPush(followUpJob(manual: false), configuration: configuration))
    }
}
