import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor
struct DraftRegenerationSaveLeaseTests {
    @Test(arguments: [true, false])
    func onlyTheAcceptedBatchCanExtendTheSaveWait(matchesBatch: Bool) throws {
        let now = Date(timeIntervalSince1970: 3000)
        let batchID = UUID()
        let action = RemoteAction(id: RemoteDraftRegenerationControl.applyID, kind: .applyDraftRegeneration, token: "proposals")
        let card = RemoteCard(id: RemoteDraftRegenerationControl.cardID, title: "", project: "", url: nil, actions: [action])
        var board = RemoteBoard(hostSession: UUID(), account: "me@gitlab.example.org", lanes: [],
            draftRegeneration: .init(card: card, count: 1, batch: .init(id: batchID, scope: .all, total: 1, phase: .ready)))
        let phone = RemotePhoneState()
        #expect(phone.receive(.init(type: .snapshot, challenge: phone.challenge(now: now), board: board), now: now))
        let argument = RemoteDraftRegenerationOperation.apply(batchID: batchID, proposalIDs: ["1:2:3"]).argument
        let command = try #require(phone.command(card: card, action: action, argument: argument, now: now))
        #expect(phone.receive(.init(type: .accepted, result: .init(id: command.id, status: .running)), now: now))
        board.draftRegeneration?.batch = .init(id: matchesBatch ? batchID : UUID(), scope: .all, total: 1, phase: .saving)
        let progressAt = now.addingTimeInterval(100)
        #expect(phone.receive(.init(type: .snapshot, challenge: phone.challenge(now: progressAt), board: board), now: progressAt))

        phone.checkCommandTimeout(now: now.addingTimeInterval(121))
        if matchesBatch {
            #expect(phone.pending?.id == command.id)
            #expect(phone.result == nil)
        } else {
            #expect(phone.pending == nil)
            #expect(phone.result?.status == .uncertain)
        }

        phone.checkCommandTimeout(now: now.addingTimeInterval(221))
        #expect(phone.pending == nil)
        #expect(phone.result?.status == .uncertain)
    }
}
