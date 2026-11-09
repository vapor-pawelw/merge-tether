import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CardPresentationTests {
    @Test func requiredApprovalProgressSurvivesTheWireWithoutAddingACommand() throws {
        let progress = try #require(RemoteApprovalProgress(completed: 1, required: 2))
        let card = RemoteCard(id: "mr:1:2", title: "Example", project: "group/repo", url: nil, approvals: progress)
        let decoded = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card))
        #expect(decoded.approvals?.completed == 1 && decoded.approvals?.required == 2)
        #expect(decoded.actions.isEmpty)
        #expect(RemoteApprovalProgress(completed: -1, required: 2) == nil)
        #expect(RemoteApprovalProgress(completed: 3, required: 2) == nil)
    }

    @Test func invalidRemoteApprovalProgressIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteApprovalProgress.self, from: Data(#"{"completed":3,"required":2}"#.utf8))
        }
    }
    @Test func attentionAndNavigationSurviveTheWireWithoutGrantingACommand() throws {
        let data = Data(#"{"id":"mr:1:2","title":"Example","project":"group/repo","detail":"Review needed","drafts":[],"actions":[],"needsAttention":true,"primaryCTA":{"title":"Review comments","destination":"drafts"},"mergeRequestIID":2}"#.utf8)
        let card = try JSONDecoder().decode(RemoteCard.self, from: data)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect(wire["needsAttention"] as? Bool == true)
        #expect((wire["primaryCTA"] as? [String: Any])?["destination"] as? String == "drafts")
        #expect(wire["mergeRequestIID"] as? Int == 2)
        #expect(card.actions.isEmpty)
    }

    @Test func oldMacPayloadStillDecodesWithoutClaimingAKnownAttentionState() throws {
        let data = Data(#"{"id":"mr:1:2","title":"Example","project":"group/repo","head":"abcdef","detail":"Old Mac","drafts":[],"actions":[]}"#.utf8)
        let card = try JSONDecoder().decode(RemoteCard.self, from: data)
        #expect(card.title == "Example")
        #expect(card.head == "abcdef")
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect(wire["needsAttention"] == nil)
        #expect(wire["primaryCTA"] == nil)
        #expect(card.approvals == nil)
    }
    @Test func anUnknownFutureNavigationDestinationFallsBackToTheOverview() throws {
        let data = Data(#"{"id":"mr:1:2","title":"Example","project":"group/repo","detail":"","drafts":[],"actions":[],"primaryCTA":{"title":"Inspect","destination":"futureSection"}}"#.utf8)
        let card = try JSONDecoder().decode(RemoteCard.self, from: data)
        #expect(card.primaryCTA?.destination == .overview)
        #expect(card.actions.isEmpty)
    }

}
