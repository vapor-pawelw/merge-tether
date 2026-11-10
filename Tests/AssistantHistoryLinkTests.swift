import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct AssistantHistoryLinkTests {
    private let session = "local_" + UUID().uuidString.lowercased()

    @Test func codexHistoryLinksRequireAThreadUUID() {
        let id = UUID()
        #expect(AssistantAutomationRunner.codexChatURL(id.uuidString)?.absoluteString
            == "codex://threads/\(id.uuidString.lowercased())")
        #expect(AssistantAutomationRunner.codexChatURL("arbitrary URL") == nil)
    }

    @Test func sessionLinksAcceptOnlyClaudeDesktopSessionIDs() throws {
        let url = try #require(AssistantAutomationRunner.claudeSessionURL(session))
        #expect(url.absoluteString == "claude://claude.ai/epitaxy/\(session)")
        #expect(AssistantAutomationRunner.claudeSessionURL(UUID().uuidString) == nil)
        #expect(AssistantAutomationRunner.claudeSessionURL("local_../../etc") == nil)
        #expect(AssistantAutomationRunner.claudeSessionURL(session.uppercased()) == nil)
    }

    @Test func savedDesktopHistorySurvivesSettingsRoundTripWithoutExecutableWork() throws {
        let suite = "AssistantHistoryLinkTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let key = AssistantAutomationRunner.ChatKey(assistant: .claude,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 42),
            username: "me", workspace: "", access: .gitLabRead)
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: key,
            title: "[MT] repo !42", prompt: "Review this MR.", createdAt: Date(), allowsPush: false,
            relayComplete: true, openedAt: Date(), chatID: session)
        settings.assistantChats[key] = session
        settings.assistantHandoffs = [job]
        settings.save()

        let restored = SettingsManager(defaults: defaults)
        #expect(key.reusableChat(in: restored.assistantChats) == session)
        let handoff = try #require(restored.assistantHandoffs.first)
        #expect(handoff.id == job.id && handoff.chatID == session)
        #expect(handoff.relayComplete == true && handoff.openedAt == job.openedAt)
        #expect(handoff.execution == nil)
        #expect(handoff.deliveredFeedbackTodos.isEmpty)
    }
}
