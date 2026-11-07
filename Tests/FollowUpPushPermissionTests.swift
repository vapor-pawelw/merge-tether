import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct FollowUpPushPermissionTests {
    private let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)

    private func job(_ state: AssistantJobExecution.State? = .running, manual: Bool = false,
                     assistant: AutomationAssistant = .codex) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: assistant, work: work, username: "me", workspace: "", access: .gitLabRead),
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

    private func proof(run: AssistantAutomationRunner.Handoff, draftID: Int) -> FollowUpVerification {
        .init(version: 1, sealed: true, verificationID: UUID(), runID: run.id, host: work.host,
              projectID: work.projectID, iid: work.iid, username: "me", userID: 3,
              headSHA: String(repeating: "a", count: 40), sourceProjectID: 4, sourceBranch: "feature",
              files: [.init(path: "Source.swift", sha256: String(repeating: "b", count: 64))],
              drafts: [.init(id: draftID, bodySHA256: AICommentAssessmentStore.digest("Verified reply"))],
              discussionFingerprint: AICommentAssessmentStore.digest(""))
    }

    private func write(_ proof: FollowUpVerification, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(proof).write(to: path)
    }

    @Test func publicationProofsRetainDistinctSucceededOriginsAfterNewerRun() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "FollowUpPushPermissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .codex
        settings.automation.allowFollowUpPush = true
        let earlier = job(.succeeded), newer = job(.succeeded)
        settings.assistantHandoffs = [earlier, newer]
        let oldProof = proof(run: earlier, draftID: 12), newProof = proof(run: newer, draftID: 13)
        let archive = folder.appending(path: "follow-up-verifications-archive/\(work.host)/1-2-me/\(oldProof.verificationID.uuidString.lowercased()).json")
        try write(oldProof, to: archive)
        try write(newProof, to: FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder))
        func candidates() -> [FollowUpVerification] {
            FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder)
        }
        #expect(Set(candidates().map(\.verificationID)) == [oldProof.verificationID, newProof.verificationID])
        for state in [AssistantJobExecution.State.queued, .running, .failed, .blocked, .cancelled, .interrupted] {
            settings.assistantHandoffs[1].execution?.state = state
            #expect(candidates().isEmpty)
        }
        settings.assistantHandoffs[1].execution = nil
        #expect(candidates().isEmpty)
        settings.assistantHandoffs[1].execution = .init(state: .succeeded)
        settings.assistantHandoffs[0].execution?.state = .failed
        #expect(candidates() == [newProof])
        settings.assistantHandoffs[0].execution?.state = .succeeded
        settings.assistantHandoffs[0].followUpPushAllowed = false
        #expect(candidates() == [newProof])
        settings.automation.allowFollowUpPush = false
        #expect(candidates().isEmpty)
        settings.automation.allowFollowUpPush = true
        settings.automation.assistant = .claude
        #expect(candidates().isEmpty)
        settings.automation.assistant = .codex
        settings.automation.scope.mode = .selected
        #expect(candidates().isEmpty)
    }

    @Test func disablingPublicationPermissionDoesNotDiscardValidDraftContext() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "FollowUpPushPermissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .codex
        let origin = job(.succeeded)
        settings.assistantHandoffs = [origin]
        let sealed = proof(run: origin, draftID: 12)
        try write(sealed, to: FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder))
        settings.automation.allowFollowUpPush = false
        #expect(FollowUpVerificationStore.contextReceipts(work: work, username: "me", settings: settings, in: folder) == [sealed])
        #expect(FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder).isEmpty)
        settings.automation.allowFollowUpPush = true
        settings.automation.scope.mode = .selected
        #expect(FollowUpVerificationStore.contextReceipts(work: work, username: "me", settings: settings, in: folder) == [sealed])
        #expect(FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder).isEmpty)
    }

    @Test(arguments: ["queued", "running", "failed", "blocked", "cancelled", "interrupted", "unknown", "succeeded"])
    func newerOtherProviderFollowUpKeepsAnUnsettledOwnershipBarrier(state: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "FollowUpPushPermissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .codex
        settings.automation.allowFollowUpPush = true
        let origin = job(.succeeded)
        let newer = job(AssistantJobExecution.State(rawValue: state), assistant: .claude)
        settings.assistantHandoffs = [origin, newer]
        let sealed = proof(run: origin, draftID: 12)
        try write(sealed, to: FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder))
        let candidates = FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder)
        #expect(candidates == (state == "succeeded" ? [sealed] : []))
    }

    @Test func legacyProofRecoveryRequiresExactKnownSucceededRunArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "Codex Desktop Relay")
        let suite = "FollowUpPushPermissionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.assistant = .codex
        settings.automation.allowFollowUpPush = true
        var earlier = job(.succeeded)
        let newer = job(.succeeded)
        let runFolder = root.appending(path: "Assistant Runs/\(earlier.id.uuidString)")
        earlier.execution?.workingDirectory = runFolder.path
        settings.assistantHandoffs = [earlier, newer]
        let oldProof = proof(run: earlier, draftID: 12), newProof = proof(run: newer, draftID: 13)
        let artifact = runFolder.appending(path: "seal-receipt.json")
        try write(oldProof, to: artifact)
        try write(newProof, to: FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder))
        func candidates() -> [FollowUpVerification] {
            FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder)
        }
        #expect(Set(candidates().map(\.verificationID)) == [oldProof.verificationID, newProof.verificationID])
        var invalid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldProof)) as? [String: Any])
        invalid["runID"] = newer.id.uuidString
        try JSONSerialization.data(withJSONObject: invalid).write(to: artifact)
        #expect(candidates() == [newProof])
        invalid["runID"] = earlier.id.uuidString
        invalid["sealed"] = false
        try JSONSerialization.data(withJSONObject: invalid).write(to: artifact)
        #expect(candidates() == [newProof])
        try write(oldProof, to: artifact)
        settings.assistantHandoffs[0].execution?.workingDirectory = root.path
        #expect(candidates() == [newProof])
        settings.assistantHandoffs = [newer]
        #expect(candidates() == [newProof])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "follow-up-verifications-archive").path))
    }

}
