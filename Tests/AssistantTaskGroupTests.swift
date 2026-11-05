import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct AssistantTaskGroupTests {
    private let host = "gitlab.example.org"
    private let codexChat = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let claudeChat = "local_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test func groupsEventsAcrossAssistantsButNotAccountsHostsOrMergeRequests() throws {
        let review = handoff(iid: 42, assistant: .codex, time: 1)
        let followUp = handoff(iid: 42, assistant: .claude, time: 3)
        let otherMR = handoff(iid: 43, assistant: .codex, time: 2)
        let otherAccount = handoff(iid: 42, assistant: .codex, username: "other", time: 4)
        let otherHost = handoff(iid: 42, assistant: .codex, host: "other.example.org", time: 5)

        let groups = AssistantTaskGroup.groups(from: [review, otherAccount, otherHost, followUp, otherMR], host: host, username: "me")

        #expect(groups.count == 2)
        let first = try #require(groups.first)
        #expect(first.id == review.key.work)
        #expect(first.handoffs.map(\.id) == [followUp.id, review.id])
        #expect(first.latest.id == followUp.id)
        #expect(first.updatedAt == followUp.createdAt)
        #expect(first.title == followUp.title)
        #expect(groups.last?.id == otherMR.key.work)
    }

    @Test func newerPendingEventKeepsTheEarlierConfirmedChatAccessible() throws {
        let delivered = handoff(iid: 42, assistant: .codex, time: 1, delivered: true, chatID: codexChat)
        let pending = handoff(iid: 42, assistant: .claude, time: 2)
        let openedDraft = handoff(iid: 42, assistant: .claude, time: 3, opened: true)

        let group = try #require(AssistantTaskGroup.groups(from: [pending, delivered, openedDraft], host: host, username: "me").first)

        #expect(group.latest.id == openedDraft.id)
        #expect(group.chatHandoff?.id == delivered.id)
        #expect(group.chatURL == AssistantAutomationRunner.codexChatURL(codexChat))
        #expect(group.deliveredCount == 1)
        #expect(group.pendingCount == 2)
    }

    @Test func usesMostRecentConfirmedValidChatWithoutTreatingDeliveryAsWorkCompletion() throws {
        let older = handoff(iid: 42, assistant: .codex, time: 1, delivered: true, chatID: codexChat)
        let newer = handoff(iid: 42, assistant: .claude, time: 2, delivered: true, chatID: claudeChat)
        let malformed = handoff(iid: 42, assistant: .codex, time: 3, delivered: true, chatID: "https://untrusted.example/other")

        let group = try #require(AssistantTaskGroup.groups(from: [older, newer, malformed], host: host, username: "me").first)

        #expect(group.chatHandoff?.id == newer.id)
        #expect(group.chatURL == AssistantAutomationRunner.claudeSessionURL(claudeChat))
        #expect(group.deliveredCount == 3)
        #expect(group.pendingCount == 0)
        #expect(group.latest.id == malformed.id)
    }

    @Test func doesNotInventLinksForDraftsOrInvalidSessions() throws {
        let draft = handoff(iid: 42, assistant: .codex, time: 1, chatID: codexChat, opened: true)
        let invalid = handoff(iid: 42, assistant: .claude, time: 2, delivered: true, chatID: codexChat)
        let group = try #require(AssistantTaskGroup.groups(from: [draft, invalid], host: host, username: "me").first)
        #expect(group.chatHandoff == nil)
        #expect(group.chatURL == nil)
        #expect(AssistantTaskGroup.groups(from: [], host: host, username: "me").isEmpty)
    }

    @Test func equalTimestampsHaveStableOrderingIndependentOfInputOrder() throws {
        let first = handoff(iid: 42, assistant: .codex, time: 1, id: "00000000-0000-4000-8000-000000000001")
        let second = handoff(iid: 42, assistant: .codex, time: 1, id: "00000000-0000-4000-8000-000000000002")
        let otherMR = handoff(iid: 43, assistant: .codex, time: 1)
        let a = AssistantTaskGroup.groups(from: [second, otherMR, first], host: host, username: "me")
        let b = AssistantTaskGroup.groups(from: [first, second, otherMR], host: host, username: "me")
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.first?.handoffs.map(\.id) == b.first?.handoffs.map(\.id))
        #expect(a.first?.latest.id == first.id)
    }

    private func handoff(
        iid: Int, assistant: AutomationAssistant, host: String = "gitlab.example.org", username: String = "me", time: TimeInterval,
        delivered: Bool = false, chatID: String? = nil, opened: Bool = false, id: String? = nil
    ) -> AssistantAutomationRunner.Handoff {
        .init(id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
              key: .init(assistant: assistant, work: .init(host: host, projectID: 7, iid: iid),
                         username: username, workspace: "", access: .gitLabRead),
              title: "[MT] repo !\(iid) \(time)", prompt: "Review the MR", createdAt: Date(timeIntervalSince1970: time),
              allowsPush: false, relayComplete: delivered, openedAt: opened ? Date() : nil, chatID: chatID)
    }
}
