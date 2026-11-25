import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CardTextTests {
    @Test func draftStyleUsesExplicitStateAndReadsLegacyBadges() throws {
        let polish = try JSONDecoder().decode(RemoteCardText.self, from: Data(
            #"{"repository":"p","draftBadge":"SZKIC","working":false,"chips":[]}"#.utf8))
        #expect(polish.isDraft == nil)
        #expect(polish.showsDraftStyle)
        #expect(RemoteCardText(repository: "p", draftBadge: "DRAFT").showsDraftStyle)
        #expect(!RemoteCardText(repository: "p", draftBadge: "MERGED").showsDraftStyle)

        let explicit = RemoteCardText(repository: "p", draftBadge: "Other translation", isDraft: true)
        let decoded = try JSONDecoder().decode(RemoteCardText.self, from: JSONEncoder().encode(explicit))
        #expect(decoded.showsDraftStyle)
        #expect(!RemoteCardText(repository: "p", draftBadge: "SZKIC", isDraft: false).showsDraftStyle)
    }

    private func card(detail: String, status: String?, next: String?) -> RemoteCard {
        var card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil, detail: detail)
        card.presentation = .init(repository: "p", status: status, nextStep: next)
        return card
    }

    @Test func aStatusRepeatingTheExplanationIsShownOnce() {
        let repeated = card(detail: "Awaiting required approvals", status: "Awaiting required approvals.", next: nil)
        #expect(repeated.visibleStatus == nil)
        let distinct = card(detail: "Reply to @alice", status: "Awaiting required approvals", next: nil)
        #expect(distinct.visibleStatus == "Awaiting required approvals")
        #expect(card(detail: "", status: "Monitoring", next: nil).visibleStatus == "Monitoring")
    }

    @Test func aNextStepRepeatingTheStatusOrAParagraphIsShownOnce() {
        #expect(card(detail: "", status: "Waiting", next: "waiting").visibleNextStep == nil)
        #expect(card(detail: "Blocked\n\nPublish the replies", status: nil, next: "Publish the replies").visibleNextStep == nil)
        #expect(card(detail: "Blocked", status: "Waiting", next: "Publish the replies").visibleNextStep == "Publish the replies")
    }

    @Test func policyLinesAlreadyOnTheCardOrRepeatedAreDropped() {
        let shown = card(detail: "Merge is manual", status: "Waiting", next: nil)
            .visiblePolicy(["Merge is manual", "Approval is manual", "Approval is manual", "Publication is manual"])
        #expect(shown == ["Approval is manual", "Publication is manual"])
    }
}

@Suite struct MRControlCompatibilityTests {
    private var board: RemoteBoard {
        var card = RemoteCard(id: "mr:1:2", title: "MR", project: "g/p", url: nil)
        card.actions = [.init(id: "approve", kind: .approve, token: "a"),
            .init(id: "publishDraft:4", kind: .publishDraft, token: "b"),
            .init(id: "stopJob:x", kind: .stopJob, token: "c"),
            .init(id: "ignoreSuggestion:9", kind: .ignoreSuggestion, token: "d", label: "Ignore: Rename")]
        return RemoteBoard(hostSession: UUID(), account: "me@host", lanes: [.init(id: .own, cards: [card])])
    }

    @Test func phonesWithoutTheCapabilityNeverReceiveKindsTheyCannotDecode() throws {
        let legacy = board.forClient(supportsCommentReview: true, supportsMergeActions: true)
        #expect(legacy.cards.first?.actions.map(\.kind) == [.approve])
        let current = board.forClient(supportsCommentReview: true, supportsMergeActions: true, supportsMRControls: true)
        #expect(current.cards.first?.actions.count == 4)
        // An older decoder knows only the original kinds; the filtered wire must still decode.
        let wire = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: wire, as: UTF8.self).contains("publishDraft"))
    }

    @Test func actionLabelsAreAdditiveOnTheWire() throws {
        let legacy = try JSONDecoder().decode(RemoteAction.self, from: Data(#"{"id":"approve","kind":"approve","token":"t"}"#.utf8))
        #expect(legacy.label == nil)
        let labeled = RemoteAction(id: "restoreSuggestion:1", kind: .restoreSuggestion, token: "t", label: "Restore: Rename")
        #expect(try JSONDecoder().decode(RemoteAction.self, from: JSONEncoder().encode(labeled)) == labeled)
    }
}
