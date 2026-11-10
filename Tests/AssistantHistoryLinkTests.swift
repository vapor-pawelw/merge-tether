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

}
