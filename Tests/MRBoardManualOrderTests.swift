import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct MRBoardManualOrderTests {
    private typealias Item = MergeRequestAttentionMonitor.Item
    private let host = "gitlab.example.test"
    private let username = "me"

    @Test func aMoveStaysWithinTheSameLaneAutomationSectionAndPinGroup() throws {
        let normal = try items([1, 2, 3, 4, 5, 6], attention: [2, 5])
        let reviewer = try items([7], attention: [], authored: false)
        let original = board(own: normal, reviewed: reviewer, paused: [4, 5], pins: [1, 2])
        var order = MRBoardManualOrder()
        let baseline = manual(original, order, pins: [1, 2])

        #expect(baseline.own.map(\.id.iid) == [1, 2, 3, 6, 4, 5])
        let acrossPins = order.move(target(2), to: target(3), in: baseline.manualOrderEntries)
        #expect(!acrossPins)
        let acrossAutomation = order.move(target(3), to: target(4), in: baseline.manualOrderEntries)
        #expect(!acrossAutomation)
        let acrossLanes = order.move(target(3), to: target(7), in: baseline.manualOrderEntries)
        #expect(!acrossLanes)
        let acrossAccounts = order.move(target(3, username: "other"), to: target(6), in: baseline.manualOrderEntries)
        #expect(!acrossAccounts)
        let pinnedMoved = order.move(target(1), to: target(2), in: baseline.manualOrderEntries)
        #expect(pinnedMoved)
        let pausedMoved = order.move(target(5), to: target(4), in: baseline.manualOrderEntries)
        #expect(pausedMoved)

        #expect(manual(original, order, pins: [1, 2]).own.map(\.id.iid) == [2, 1, 3, 6, 5, 4])
        #expect(manual(original, order, pins: [1, 2]).reviewed.map(\.id.iid) == [7])
    }

    @Test func aNewAttentionStatusPromotesOnceAndRemainsInItsSectionAndPinGroup() throws {
        var order = MRBoardManualOrder()
        func frame(_ attention: Set<Int> = []) throws -> MergeRequestBoardSnapshot {
            try manual(board(own: items([1, 2, 3, 4, 5, 6], attention: attention), paused: [5, 6], pins: [1, 2]),
                order, pins: [1, 2])
        }

        try order.observe(frame().manualOrderEntries, promotesAttention: true)
        let changed = try frame([2, 4, 6])
        order.observe(changed.manualOrderEntries, promotesAttention: true)
        let promoted = try frame([2, 4, 6])
        #expect(promoted.own.map(\.id.iid) == [2, 1, 4, 3, 6, 5])

        let attentionMoved = order.move(target(4), to: target(3), in: promoted.manualOrderEntries)
        #expect(attentionMoved)
        try order.observe(frame([2, 4, 6]).manualOrderEntries, promotesAttention: true)
        #expect(try frame([2, 4, 6]).own.map(\.id.iid) == [2, 1, 3, 4, 6, 5])
        try order.observe(frame([2, 6]).manualOrderEntries, promotesAttention: true)
        #expect(try frame([2, 6]).own.map(\.id.iid) == [2, 1, 3, 4, 6, 5])
        try order.observe(frame([2, 4, 6]).manualOrderEntries, promotesAttention: true)
        #expect(try frame([2, 4, 6]).own.map(\.id.iid) == [2, 1, 4, 3, 6, 5])
    }

    @Test func disabledAttentionPromotionKeepsTheOrderThroughRefreshAndRestart() throws {
        let suite = "MRBoardManualOrderTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.boardOrderingMethod == .manual)
        #expect(settings.promoteBoardAttention)
        settings.promoteBoardAttention = false

        var order = settings.boardManualOrder
        let original = try manual(board(own: items([1, 2, 3], attention: [])), order)
        let moved = order.move(target(3), to: target(1), in: original.manualOrderEntries)
        #expect(moved)
        let updated = try board(own: items([2, 3, 4], attention: [2, 4]))
        order.observe(manual(updated, order).manualOrderEntries, promotesAttention: settings.promoteBoardAttention)
        settings.saveBoardManualOrder(order)
        settings.boardOrderingMethod = .automatic
        settings.save()

        let restored = SettingsManager(defaults: defaults)
        #expect(restored.boardOrderingMethod == .automatic)
        #expect(!restored.promoteBoardAttention)
        let allCards = try board(own: items([1, 2, 3, 4], attention: [2, 4]))
        var restoredOrder = restored.boardManualOrder
        restoredOrder.observe(manual(allCards, restoredOrder).manualOrderEntries, promotesAttention: true)
        #expect(manual(allCards, restoredOrder).own.map(\.id.iid) == [3, 1, 2, 4])
    }

    @Test func manualSectionsFollowConfiguredAutomationEvenWithTheManualProfileOrDraftsGrouping() throws {
        let own = try items([1, 2], attention: [], drafts: [2])
        let automatic = manual(board(own: own, grouping: .drafts), .init())
        #expect(automatic.manualOrderEntries.map(\.group.automationEnabled) == [true, false])

        let paused = manual(board(own: own, grouping: .drafts, automationEnabled: false), .init())
        #expect(paused.manualOrderEntries.map(\.group.automationEnabled) == [false, false])

        let headers = CommandCenterBoardView.laneEntries(automatic.own, automationOffExpanded: false,
            showsAutomationOn: true,
            activity: { $0.manualOrderEntry?.group.automationEnabled == true ? .regular : .inactive },
            hasHumanAction: { $0.needsAttention })
        #expect(headers.map(\.id) == [.automationOn, .card(own[0].id), .automationOff])
    }

    @Test func phoneAcceptsTheMacOrderAgainWhenAttentionOrDragChangesIt() throws {
        let phone = RemotePhoneState()
        let session = UUID()
        let account = "\(username)@\(host)"
        var order = MRBoardManualOrder()
        func send(_ mac: MergeRequestBoardSnapshot, expect iids: [Int]) throws {
            let snapshot = RemoteBoardAdapter.project(board: mac, other: [], session: session, account: account)
            let decoded = try JSONDecoder().decode(RemoteBoard.self, from: JSONEncoder().encode(snapshot))
            #expect(phone.receive(.init(type: .snapshot, challenge: phone.challenge(), board: decoded)))
            #expect(phone.board?.lanes.first?.cards.map(\.id) == iids.map { "mr:1:\($0)" })
        }

        let original = try board(own: items([1, 2, 3], attention: []))
        let baseline = manual(original, order)
        order.observe(baseline.manualOrderEntries, promotesAttention: true)
        try send(baseline, expect: [1, 2, 3])

        let moved = order.move(target(3), to: target(1), in: baseline.manualOrderEntries)
        #expect(moved)
        try send(manual(original, order), expect: [3, 1, 2])

        let attention = try board(own: items([1, 2, 3], attention: [2]))
        order.observe(manual(attention, order).manualOrderEntries, promotesAttention: true)
        try send(manual(attention, order), expect: [2, 3, 1])
    }

    private func target(_ iid: Int, username: String = "me") -> MRAutomationScope.Target {
        .init(host: host, username: username, projectID: 1, iid: iid)
    }

    private func pins(_ iids: [Int]) -> Set<BoardCardPin> {
        Set(iids.compactMap { .mergeRequest(host: host, username: username, projectID: 1, iid: $0) })
    }

    private func board(own: [Item], reviewed: [Item] = [], paused: [Int] = [], pins iids: [Int] = [],
                       grouping: MRBoardGrouping = .withoutAutomation, automationEnabled: Bool = true) -> MergeRequestBoardSnapshot {
        var automation = AutomationSettings()
        automation.applyPreset(automationEnabled ? .full : .manual, for: .codex)
        for iid in paused { automation.scope.setEnabled(false, for: target(iid)) }
        return .init(own: own, reviewed: reviewed, todos: [], attention: own + reviewed, handoffs: [], host: host,
            username: username, pinnedCards: pins(iids), automation: automation, grouping: grouping)
    }

    private func manual(_ board: MergeRequestBoardSnapshot, _ order: MRBoardManualOrder, pins iids: [Int] = []) -> MergeRequestBoardSnapshot {
        board.applyingManualOrder(order, host: host, username: username, pinnedCards: pins(iids))
    }

    private func items(_ iids: [Int], attention: Set<Int>, authored: Bool = true, drafts: Set<Int> = []) throws -> [Item] {
        try iids.map { iid in
            let author = authored ? username : "author"
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
            {"project_id":1,"iid":\(iid),"author":{"id":9,"username":"\(author)","name":"Author"},"title":"MR \(iid)",
             "web_url":"https://\(host)/g/p/-/merge_requests/\(iid)","state":"opened","draft":\(drafts.contains(iid)),
             "source_branch":"feature","target_branch":"main","labels":[]}
            """.utf8))
            return .init(id: .init(projectID: 1, iid: iid), title: request.title, url: request.webURL,
                needsDiscussion: attention.contains(iid), mergeRequest: request, isAuthored: authored)
        }
    }
}
