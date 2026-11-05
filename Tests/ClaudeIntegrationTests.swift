import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct ClaudeIntegrationTests {
    private let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 42)
    private let session = "local_" + UUID().uuidString.lowercased()

    private func handoff(chatID: String? = nil) -> AssistantAutomationRunner.Handoff {
        .init(id: UUID(), key: .init(assistant: .claude, work: work, username: "me", workspace: "", access: .gitLabRead),
              title: "[MT] repo !42", prompt: "Review this merge request.", createdAt: Date(), allowsPush: false,
              chatID: chatID)
    }

    @Test func sessionLinksAcceptOnlyClaudeDesktopSessionIDs() throws {
        let url = try #require(AssistantAutomationRunner.claudeSessionURL(session))
        #expect(url.absoluteString == "claude://claude.ai/epitaxy/\(session)")
        #expect(AssistantAutomationRunner.claudeSessionURL(UUID().uuidString) == nil)
        #expect(AssistantAutomationRunner.claudeSessionURL("local_../../etc") == nil)
        #expect(AssistantAutomationRunner.claudeSessionURL(session.uppercased()) == nil)
    }

    @Test func newSessionsAreAskedToLinkThemselvesToTheirJob() {
        let id = UUID()
        let text = AssistantAutomationRunner.claudeSessionLinkInstructions(jobID: id)
        #expect(text.contains("record_claude_session"))
        #expect(text.contains(id.uuidString.lowercased()))
    }

    @Test func linkedSessionIsReusedForTheMergeRequest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "ClaudeIntegrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = SettingsManager(defaults: defaults)
        let pending = handoff()
        settings.assistantHandoffs = [pending]

        CodexDesktopRelay.publishClaudeJob(pending, directory: directory)
        let job = directory.appending(path: "claude-jobs/\(pending.id.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: job.path))
        // The Codex listener's queue stays empty.
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "jobs").path))

        // No receipt yet: nothing changes.
        CodexDesktopRelay.synchronizeClaude(settings: settings, directory: directory)
        #expect(settings.assistantHandoffs.first?.chatID == nil)

        let receipts = directory.appending(path: "claude-receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "jobID": pending.id.uuidString.lowercased(), "threadID": session, "conversationKey": "x"
        ]).write(to: receipts.appending(path: "\(pending.id.uuidString.lowercased()).json"))
        CodexDesktopRelay.synchronizeClaude(settings: settings, directory: directory)

        let linked = try #require(settings.assistantHandoffs.first)
        #expect(linked.chatID == session && linked.relayComplete == true)
        #expect(linked.key.reusableChat(in: settings.assistantChats) == session)
        #expect(!FileManager.default.fileExists(atPath: job.path))
    }

    @Test func malformedReceiptsAreIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "ClaudeIntegrationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = SettingsManager(defaults: defaults)
        let pending = handoff()
        settings.assistantHandoffs = [pending]
        let receipts = directory.appending(path: "claude-receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "jobID": pending.id.uuidString.lowercased(), "threadID": UUID().uuidString
        ]).write(to: receipts.appending(path: "\(pending.id.uuidString.lowercased()).json"))
        CodexDesktopRelay.synchronizeClaude(settings: settings, directory: directory)
        #expect(settings.assistantHandoffs.first?.chatID == nil)
        #expect(settings.assistantChats.isEmpty)
    }

    @Test func pluginListingDetectsTheMergeTetherPlugin() throws {
        let enabled = #"[{"id":"merge-tether@merge-tether-desktop","version":"0.1.10","scope":"user","enabled":true}]"#
        let disabled = #"[{"id":"merge-tether@merge-tether-desktop","enabled":false},{"id":"other@x","enabled":true}]"#
        #expect(try ClaudePluginInstaller.installation(in: Data(enabled.utf8)) == .enabled)
        #expect(try ClaudePluginInstaller.installation(in: Data(disabled.utf8)) == .disabled)
        #expect(try ClaudePluginInstaller.installation(in: Data("[]".utf8)) == .missing)
    }
}
