import Foundation
import Observation
import os
import Testing
@testable import MergeTether

@MainActor
struct BoardPresentationCacheTests {
    private let host = "gitlab.example.test"
    private let username = "me"

    @Test func aWarmBoardAndFrameImmediatelyReflectCatalogChanges() throws {
        try fixture { monitor, settings, delivery in
            let original = try request(1, title: "Before")
            let target = self.target(1)
            settings.mrLifecycleLedger.record(original, for: target)
            #expect(monitor.boardSnapshot.own.first?.displayTitle == "Before")
            _ = monitor.commandCenterDisplayFrame
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = monitor.commandCenterDisplayFrame } onChange: {
                changed.withLock { $0 = true }
            }
            settings.mrLifecycleLedger.record(try request(1, title: "After"), for: target)
            #expect(monitor.boardSnapshot.own.first?.displayTitle == "After")
            #expect(monitor.commandCenterDisplayFrame.board.own.first?.displayTitle == "After")
            delivery.flush()
            #expect(changed.withLock { $0 })
        }
    }

    @Test(arguments: ["username", "host", "signout"])
    func aWarmBoardCannotCrossAnAccountChange(_ change: String) throws {
        try fixture { monitor, settings, _ in
            settings.mrLifecycleLedger.record(try request(1), for: target(1))
            #expect(monitor.commandCenterDisplayFrame.board.own.count == 1)
            if change == "username" { monitor.glab.currentUsername = "other" }
            else if change == "host" { monitor.glab.resolvedHost = "other.example.test" }
            else { monitor.glab.currentUsername = nil }
            #expect(monitor.boardSnapshot.own.isEmpty)
            #expect(monitor.commandCenterDisplayFrame.board.own.isEmpty)
            #expect(monitor.commandCenterDisplayFrame.inbox.items.isEmpty)
            monitor.glab.resolvedHost = host
            monitor.glab.currentUsername = username
            #expect(monitor.commandCenterDisplayFrame.board.own.count == 1)
        }
    }

    @Test func aWarmBoardImmediatelyReflectsPinsAndIgnoredTargets() throws {
        try fixture { monitor, settings, _ in
            for iid in [1, 2] { settings.mrLifecycleLedger.record(try request(iid), for: target(iid)) }
            #expect(monitor.boardSnapshot.own.map(\.id.iid) == [1, 2])
            settings.boardPins = [try #require(BoardCardPin.mergeRequest(host: host, username: username, projectID: 1, iid: 2))]
            #expect(monitor.commandCenterDisplayFrame.board.own.map(\.id.iid) == [2, 1])
            settings.ignoredMergeRequests.insert(target(2))
            #expect(monitor.boardSnapshot.own.map(\.id.iid) == [1])
        }
    }

    @Test func aDropUpdatesTheWarmFrameAndSwitchingMethodsRestoresEachOrder() throws {
        try fixture { monitor, settings, _ in
            for iid in [1, 2, 3] { settings.mrLifecycleLedger.record(try request(iid, title: "MR \(iid)"), for: target(iid)) }
            let revision = monitor.glab.accountRevision
            #expect(monitor.commandCenterDisplayFrame.board.own.map(\.id.iid) == [1, 2, 3])
            #expect(!monitor.moveBoardCard(target(3), to: target(1), accountRevision: revision &+ 1))
            #expect(monitor.moveBoardCard(target(3), to: target(1), accountRevision: revision))
            #expect(monitor.commandCenterDisplayFrame.board.own.map(\.id.iid) == [3, 1, 2])

            settings.boardOrderingMethod = .automatic
            settings.save()
            #expect(!monitor.moveBoardCard(target(2), to: target(1), accountRevision: revision))
            #expect(monitor.commandCenterDisplayFrame.board.own.map(\.id.iid) == [1, 2, 3])

            settings.boardOrderingMethod = .manual
            settings.save()
            #expect(monitor.commandCenterDisplayFrame.board.own.map(\.id.iid) == [3, 1, 2])
        }
    }

    private func fixture(_ body: (TodoMonitorService, SettingsManager, DeferredPresentationNotifications) throws -> Void) throws {
        let suite = "BoardPresentationCacheTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.manual, for: .codex)
        settings.resolvedHost = host
        settings.glabPath = URL(fileURLWithPath: "/usr/bin/false")
        let glab = GlabService(commandRunner: { _, _, _, _, _ in throw CancellationError() })
        glab.resolvedHost = host
        glab.currentUsername = username
        let delivery = DeferredPresentationNotifications()
        let monitor = TodoMonitorService(settings: settings, glab: glab, schedulePresentationNotification: delivery.schedule)
        defer { monitor.stopTimer() }
        try body(monitor, settings, delivery)
        delivery.flush()
    }

    private func target(_ iid: Int) -> MRAutomationScope.Target {
        .init(host: host, username: username, projectID: 1, iid: iid)
    }

    private func request(_ iid: Int, title: String = "Example") throws -> GitLabMergeRequest {
        try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: [
            "project_id": 1, "iid": iid, "author": ["id": 7, "username": username, "name": "Me"],
            "title": title, "web_url": "https://\(host)/group/repo/-/merge_requests/\(iid)",
            "state": "opened", "draft": false, "sha": "head", "source_branch": "feature", "target_branch": "main", "labels": []
        ]))
    }
}
