import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CardPresentationTests {
    @Test func pinStateAndCommandsRequireThePhoneCapabilityWithoutChangingLegacyDetailRequests() throws {
        let payload = Data(#"{"id":"mr:1:2","title":"MR","project":"g/p","detail":"","drafts":[],"pinned":true,"actions":[{"id":"editCard","kind":"editCard","token":"pin"}]}"#.utf8)
        let card = try JSONDecoder().decode(RemoteCard.self, from: payload)
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        let modern = try #require(board.forClient(supportsCommentReview: true, supportsCardActions: true).cards.first)
        #expect(modern.pinned == true && modern.actions.map(\.kind) == [.editCard])
        let legacy = try #require(board.forClient(supportsCommentReview: true).cards.first)
        #expect(legacy.actions.isEmpty && legacy.pinned == nil)
        #expect(modern.detailContextDigest == legacy.detailContextDigest)
        let previousVersion = RemoteCard(id: card.id, title: card.title, project: card.project, url: nil)
        let request = try RemoteDetailRequest(card: previousVersion, board: board)
        #expect(request.matches(board.forClient(supportsCommentReview: true)))
    }

    @Test func issueTagsSurviveTheWireWithoutChangingDetailIdentity() throws {
        let wire = Data(##"{"id":"mr:1:2","title":"Fix retries","project":"g/p","head":"head","detail":"","drafts":[],"actions":[],"issues":[{"reference":"#123","title":"Retry payments","url":"https://gitlab.example.test/g/p/-/issues/123"},{"reference":"PAY-73"}]}"##.utf8)
        let upgraded = try JSONDecoder().decode(RemoteCard.self, from: wire)
        let legacy = RemoteCard(id: "mr:1:2", title: "Fix retries", project: "g/p", url: nil, head: "head")
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [upgraded])])

        let encoded = try JSONEncoder().encode(upgraded)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        let object = try #require(decoded as? [String: Any])
        let issues = object["issues"] as? [[String: String]]
        #expect(issues?.compactMap { $0["reference"] } == ["#123", "PAY-73"])
        #expect(issues?.last?["url"] == nil)
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
        #expect(upgraded.detailContextDigest == legacy.detailContextDigest)
    }

    @Test func issueNamesCanBeTrimmedToFitWithoutLosingTheirLinksOrBoardActions() throws {
        var card = RemoteCard(id: "mr:1:2", title: "Fix retries", project: "g/p", url: nil,
            detail: String(repeating: "x", count: 130_200), actions: [.init(id: "review", kind: .runReview, token: "current")])
        let url = try #require(URL(string: "https://gitlab.example.test/g/p/-/issues/123"))
        card.issues = [.init(reference: "#123", title: String(repeating: "y", count: 900), url: url)]
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        let message = RemoteMessage(type: .snapshot, board: board)

        let fitted = message.fittingIssueTags()

        #expect(try JSONEncoder().encode(message).count > RemoteCipher.maximumPayloadBytes)
        #expect(try JSONEncoder().encode(fitted).count <= RemoteCipher.maximumPayloadBytes)
        #expect(fitted.board?.cards.first?.issues == [.init(reference: "#123", url: url)])
        #expect(fitted.board?.cards.first?.actions == card.actions)
    }

    @Test func onlyPlainOverviewShortcutsDuplicateTheCardTap() {
        #expect(RemoteCardCTA(title: "Show details", destination: .overview).duplicatesCardTap)
        #expect(!RemoteCardCTA(title: "Run", destination: .overview, actionID: "run").duplicatesCardTap)
        #expect(!RemoteCardCTA(title: "Review drafts", destination: .drafts).duplicatesCardTap)
        #expect(!RemoteCardCTA(title: "View discussions", destination: .discussions).duplicatesCardTap)
    }

    @Test func approvalPeopleAreAdditiveDisplayMetadataAndOlderPhonesCanStillReadDetails() throws {
        let viewer = RemoteApprovalPerson(id: 7, name: "Reviewer", username: "me", status: .approved)
        let card = RemoteCard(id: "mr:1:2", title: "Feature", project: "g/p", url: nil,
            presentation: .init(repository: "p", approvalPeople: [viewer], viewerApprovalID: 7))
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .reviewed, cards: [card])])
        let wire = try JSONDecoder().decode(RemoteCard.self, from: JSONEncoder().encode(card))
        #expect(wire.presentation?.approvalPeople == [viewer])
        #expect(wire.presentation?.viewerApprovalID == 7)
        #expect(wire.actions.isEmpty)
        var legacy = card
        legacy.presentation?.approvalPeople = nil; legacy.presentation?.viewerApprovalID = nil
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
        #expect(try RemoteDetailRequest(card: legacy, board: board, presentationIndependent: true).matches(board))
    }

    @Test(arguments: [RemoteActionKind.personalApprove, .removeApproval])
    func personalApprovalActionsRequireThePhoneCapability(_ kind: RemoteActionKind) throws {
        let approval = RemoteAction(id: "approve", kind: .approve, token: "legacy")
        let personal = RemoteAction(id: kind.rawValue, kind: kind, token: "checked")
        var card = RemoteCard(id: "mr:1:2", title: "Feature", project: "g/p", url: nil, actions: [approval, personal],
            presentation: .init(repository: "p"))
        card.presentation?.automaticApprovalOff = true
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .reviewed, cards: [card])])
        let compatible = board.forClient(supportsCommentReview: true, supportsMRControls: true).cards[0]
        #expect(compatible.actions == [approval])
        #expect(compatible.presentation?.automaticApprovalOff == nil)
        #expect(board.forClient(supportsCommentReview: true, supportsPersonalApproval: true).cards[0] == card)
        #expect(personal.suppressibleConfirmationID == nil)
    }

    @Test func olderPhonesNeverReceiveMarkReadyOrItsExecutableCTA() throws {
        let action = try JSONDecoder().decode(RemoteAction.self,
            from: Data(#"{"id":"markReady","kind":"markReady","token":"checked"}"#.utf8))
        let cta = RemoteCardCTA(title: "Mark ready", destination: .actions, actionID: action.id)
        let card = RemoteCard(id: "mr:1:2", title: "Draft: Feature", project: "g/p", url: nil,
            actions: [action], primaryCTA: cta,
            presentation: .init(repository: "p", secondaryCTA: cta))
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        let legacy = board.forClient(supportsCommentReview: true, supportsMergeActions: true, supportsMRControls: true)
        #expect(legacy.cards[0].actions.isEmpty)
        #expect(legacy.cards[0].primaryCTA?.actionID == nil)
        #expect(legacy.cards[0].presentation?.secondaryCTA == nil)
        #expect(board.forClient(supportsCommentReview: true, supportsMarkReady: true).cards[0] == card)
    }

    @Test func olderPhonesCanReadDetailsAfterDroppingActionLinksAndAnUnknownDestination() throws {
        // given
        var card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil,
            primaryCTA: .init(title: "Discussions", destination: .discussions))
        card.presentation = .init(repository: "p", secondaryCTA: .init(title: "Retry", destination: .actions, actionID: "retry"))
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
        // when
        var legacy = card
        legacy.primaryCTA?.destination = .overview
        legacy.presentation?.secondaryCTA?.actionID = nil
        // then
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
    }

    @Test(arguments: [RemoteCardCTA.Destination.drafts, .feedback, .assistantRuns, .actions, .setup, .discussions])
    func cardSelectionKeepsTheTappedDestinationSeparateFromTheHeader(_ destination: RemoteCardCTA.Destination) {
        let card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil,
            primaryCTA: .init(title: "Primary", destination: .drafts))
        let selection = RemoteCardSelection(card: card, cta: .init(title: "Tapped", destination: destination))
        #expect(selection.destination == destination)
        #expect(selection.needsDetails == [.feedback, .assistantRuns, .discussions].contains(destination))
        #expect(RemoteCardSelection(card: card).destination == .overview)
        #expect(selection.action(in: card) == nil)
    }

    @Test(arguments: ["unchanged", "head", "token", "missing", "unrelated"])
    func actionSelectionUsesOnlyTheExactCommandFromTheTappedCard(_ change: String) {
        // given
        let action = RemoteAction(id: "retry", kind: .retryJob, token: "current")
        let cta = RemoteCardCTA(title: "Retry", destination: .actions, actionID: "retry")
        let card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil, head: "old",
            actions: [action, .init(id: "other", kind: .prepare, token: "other")], primaryCTA: cta)
        let selection = RemoteCardSelection(card: card, cta: cta)
        var current = card
        switch change {
        case "head": current.head = "new"
        case "token": current.actions[0].token = "new"
        case "missing": current.actions.removeFirst()
        case "unrelated": current.id = "mr:1:3"
        default: break
        }
        // when + then
        #expect(selection.action(in: current) == (change == "unchanged" ? action : nil))
    }

    @Test func actionCTAsKeepTheirExactCommandWhileOlderPhonesCanStillReadDetails() throws {
        // given
        let data = Data(#"{"title":"Retry run","destination":"actions","actionID":"job:retry"}"#.utf8)
        let cta = try JSONDecoder().decode(RemoteCardCTA.self, from: data)
        let card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil,
            actions: [.init(id: "job:retry", kind: .retryJob, token: "current")], primaryCTA: cta)
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])

        // when
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cta)) as? [String: Any])
        struct OlderCTA: Codable { let title: String; let destination: RemoteCardCTA.Destination }
        let older = try JSONDecoder().decode(OlderCTA.self, from: data)
        var legacy = card
        legacy.primaryCTA = try JSONDecoder().decode(RemoteCardCTA.self, from: JSONEncoder().encode(older))

        // then
        #expect(wire["actionID"] as? String == "job:retry")
        #expect(try RemoteDetailRequest(card: legacy, board: board).matches(board))
    }

    @Test func activeAgentMarkersSurviveTheWireWithoutBreakingOlderPeers() throws {
        let legacy = Data(#"{"repository":"repo","status":"Monitoring MR","working":false,"chips":[]}"#.utf8)
        #expect(try JSONDecoder().decode(RemoteCardText.self, from: legacy).statusSymbol == nil)
        let current = RemoteCardText(repository: "repo", status: "Checking replies · Claude CLI", working: true,
            pendingDrafts: "1 unpublished draft", statusSymbol: "sparkle.magnifyingglass")
        let data = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(RemoteCardText.self, from: data) == current)
        struct LegacyText: Decodable { let status: String; let working: Bool }
        let oldPhone = try JSONDecoder().decode(LegacyText.self, from: data)
        #expect(oldPhone.status == current.status && oldPhone.working)
    }

    @Test func draftWarningsAreAdditiveAndSurviveTheWire() throws {
        let legacy = try JSONDecoder().decode(RemoteDraft.self, from: Data(#"{"id":11,"body":"Reply"}"#.utf8))
        #expect(legacy.publicationWarnings == nil)
        let warned = RemoteDraft(id: 12, body: "/merge", context: "thread",
            publicationWarnings: ["Draft #12 contains potential GitLab quick actions.", "Thread thread"])
        #expect(try JSONDecoder().decode(RemoteDraft.self, from: JSONEncoder().encode(warned)) == warned)
        let board = RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .drafts,
            cards: [.init(id: "mr:1:2", title: "MR", project: "g/p", url: nil, drafts: [warned])])])
        #expect(board.forClient(supportsCommentReview: false).cards.first?.drafts == [warned])
    }

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
