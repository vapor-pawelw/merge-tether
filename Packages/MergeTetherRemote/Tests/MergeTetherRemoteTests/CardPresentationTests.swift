import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CardPresentationTests {
    @Test(arguments: [false, true])
    func anAdditiveAutomationPauseSurvivesTheWireAndLegacyClientFiltering(_ paused: Bool) throws {
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [])
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(board)) as? [String: Any])
        payload["automationPaused"] = paused
        let decoded = try JSONDecoder().decode(RemoteBoard.self, from: JSONSerialization.data(withJSONObject: payload))
        let compatible = decoded.forClient(supportsCommentReview: false, supportsMergeActions: false)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(compatible)) as? [String: Any])
        #expect(wire["automationPaused"] as? Bool == paused)
        struct LegacyBoard: Decodable { let account: String; let partial: Bool }
        let legacy = try JSONDecoder().decode(LegacyBoard.self, from: JSONEncoder().encode(compatible))
        #expect(legacy.account == board.account && legacy.partial == false)
    }

    @Test func anOlderHostWithoutThePauseFlagRemainsDecodableWithoutInventingAState() throws {
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [])
        let decoded = try JSONDecoder().decode(RemoteBoard.self, from: JSONEncoder().encode(board))
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(wire["automationPaused"] == nil)
    }

    @Test func olderPhonesReceiveOnlyActionsTheirDecoderUnderstands() {
        let actions: [RemoteAction] = [.init(id: "approve", kind: .approve, token: "a"),
            .init(id: "deleteDraft:11", kind: .deleteDraft, token: "b"),
            .init(id: "finishCommentReview", kind: .finishCommentReview, token: "c")]
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [
            .init(id: .own, cards: [.init(id: "mr:1:2", title: "Example", project: "g/p", url: nil, actions: actions,
                primaryCTA: .init(title: "Finish comment review", destination: .drafts))])])
        #expect(board.forClient(supportsCommentReview: false).cards.first?.actions.map(\.kind) == [.approve])
        #expect(board.forClient(supportsCommentReview: false).cards.first?.primaryCTA == nil)
        #expect(board.forClient(supportsCommentReview: true).cards.first?.actions == actions)
    }

    @Test func optionalApprovalsSurviveTheWireWithTheirActualCount() throws {
        let progress = try #require(RemoteApprovalProgress(completed: 0, required: 0, received: 3))
        let decoded = try JSONDecoder().decode(RemoteApprovalProgress.self, from: JSONEncoder().encode(progress))
        #expect(decoded.completed == 0 && decoded.required == 0 && decoded.received == 3)
    }
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

@Test func oldPhonesNeverReceiveMergeActionEnumCases() throws {
    let actions = [RemoteAction(id: "merge", kind: .merge, token: "checked"),
                   RemoteAction(id: "enqueue", kind: .enqueueMerge, token: "checked"),
                   RemoteAction(id: "resolve", kind: .resolveThreads, token: "checked"),
                   RemoteAction(id: "check", kind: .checkThreads, token: "checked")]
    let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [
        .init(id: .own, cards: [.init(id: "mr", title: "Feature", project: "g/p", url: nil, actions: actions)])])
    #expect(board.forClient(supportsCommentReview: true).cards[0].actions.isEmpty)
    #expect(board.forClient(supportsCommentReview: true, supportsMergeActions: true).cards[0].actions == actions)
    let oldCompatible = try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.forClient(supportsCommentReview: true)))
    #expect(!String(describing: oldCompatible).contains("enqueueMerge"))
}
