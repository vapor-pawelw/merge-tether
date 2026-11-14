import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CardTextTests {
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
