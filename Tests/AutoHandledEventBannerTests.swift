import Foundation
import Testing
@testable import GitLabTodos

@MainActor
@Suite struct AutoHandledEventBannerTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)
    private let now = Date(timeIntervalSince1970: 100)

    private func intent(_ id: UUID = UUID()) throws -> MRTodoIntent {
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(#"{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Me"},"title":"Sensitive title excluded from banner","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"opened","sha":"abc","source_branch":"feature","target_branch":"main","labels":[]}"#.utf8))
        return .init(id: id, target: target, kind: .followUp, state: .pending, todoIDs: [10], noteIDs: [42], sourceEvents: [], request: request, headSHA: "abc", updatedAt: now)
    }

    @Test func acceptedActionShowsBriefEventOnceWithoutPersistentInboxItem() throws {
        let center = AutoHandledEventBannerCenter()
        let action = try intent()
        center.receive(action, enabled: true, now: now)
        let banner = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        #expect(banner.kind == .followUp)
        #expect(banner.projectPath == "team/repo")
        center.receive(action, enabled: true, now: now)
        #expect(center.events.count == 1)
        center.dismiss(banner.id)
        center.receive(action, enabled: true, now: now)
        #expect(center.events.isEmpty)
    }

    @Test func newSourceEventOnTheSamePendingActionGetsItsOwnBannerOnce() throws {
        let center = AutoHandledEventBannerCenter()
        var action = try intent()
        let event = Todo.FeedbackIdentity(id: 10, targetURL: action.request.webURL, actorID: 2,
            action: .reviewRequested, createdAt: now, updatedAt: nil)
        action.sourceEvents = [event]
        center.receive(action, enabled: true, now: now)
        let first = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        center.dismiss(first.id)
        action.sourceEvents.append(.init(id: 20, targetURL: action.request.webURL, actorID: 2,
            action: .reviewRequested, createdAt: now, updatedAt: nil))
        center.receive(action, enabled: true, now: now)
        let second = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        #expect(second.id != first.id)
        center.receive(action, enabled: true, now: now)
        #expect(center.events.count == 1)
        center.dismiss(second.id)
        center.receive(action, enabled: true, now: now)
        #expect(center.events.isEmpty)
    }

    @Test func presentationDedupRetainsOnlyABoundedRecentIntentWindow() throws {
        let center = AutoHandledEventBannerCenter(recentIntentLimit: 2)
        let oldest = try intent()
        center.receive(oldest, enabled: true, now: now)
        let original = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        center.dismiss(original.id)
        for _ in 0..<2 {
            center.receive(try intent(), enabled: true, now: now)
            let event = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
            center.dismiss(event.id)
        }
        // Long-term replay prevention belongs to the durable router receipts;
        // the presentation layer forgets intents outside its recent window.
        center.receive(oldest, enabled: true, now: now)
        let reconsidered = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        #expect(reconsidered.id != original.id)
        center.dismiss(reconsidered.id)
        center.receive(oldest, enabled: true, now: now)
        #expect(center.events.isEmpty)
    }

    @Test func largeSourceEventSetRemainsDeduplicatedWhenReorderedOrDuplicated() throws {
        let center = AutoHandledEventBannerCenter(recentIntentLimit: 2)
        var action = try intent()
        action.sourceEvents = (0..<1025).map { index in
            .init(id: index + 1, targetURL: action.request.webURL, actorID: 2,
                  action: .reviewRequested, createdAt: now, updatedAt: nil)
        }
        center.receive(action, enabled: true, now: now)
        let first = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        center.dismiss(first.id)
        action.sourceEvents.reverse()
        action.sourceEvents.append(action.sourceEvents[0])
        center.receive(action, enabled: true, now: now)
        #expect(center.events.isEmpty)
        action.sourceEvents.append(.init(id: 2000, targetURL: action.request.webURL, actorID: 2,
            action: .reviewRequested, createdAt: now, updatedAt: now))
        center.receive(action, enabled: true, now: now)
        let updated = try #require(center.current(host: target.host, username: target.username, enabled: true, now: now))
        #expect(updated.id != first.id)
        center.dismiss(updated.id)
        center.receive(action, enabled: true, now: now)
        #expect(center.events.isEmpty)
    }

    @Test func disabledBannersAndDifferentAccountsNeverExposeAnEvent() throws {
        let center = AutoHandledEventBannerCenter()
        center.receive(try intent(), enabled: false, now: now)
        #expect(center.events.isEmpty)
        center.receive(try intent(), enabled: true, now: now)
        #expect(center.current(host: "another.example.test", username: target.username, enabled: true, now: now) == nil)
        #expect(center.current(host: target.host, username: "other", enabled: true, now: now) == nil)
        #expect(center.current(host: target.host, username: target.username, enabled: false, now: now) == nil)
    }

    @Test func bannersExpireAndPollingCannotReviveThemOrBuildAnUnboundedBacklog() throws {
        let center = AutoHandledEventBannerCenter()
        let action = try intent()
        center.receive(action, enabled: true, now: now)
        #expect(center.current(host: target.host, username: target.username, enabled: true, now: now.addingTimeInterval(30)) == nil)
        center.receive(action, enabled: true, now: now.addingTimeInterval(30))
        #expect(center.current(host: target.host, username: target.username, enabled: true, now: now.addingTimeInterval(30)) == nil)
        for _ in 0..<12 { center.receive(try intent(), enabled: true, now: now) }
        #expect(center.events.count <= 3)
    }
}
