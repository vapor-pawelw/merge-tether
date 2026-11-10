import Foundation
import Testing
import UserNotifications
@testable import GitLabTodos

@MainActor
@Suite struct HumanAttentionNotificationTests {
    private final class Delivery {
        var status: UNAuthorizationStatus = .denied
        var requests: [UNNotificationRequest] = []
        var cancel: (() -> Void)?
    }
    private func items(_ count: Int = 1) -> [UserAttentionSnapshot.Item] {
        UserAttentionSnapshot(candidates: (0..<count).map {
            .init(id: "item-\($0)", title: "Example \($0)", subtitle: "team/repo",
                  actions: [.init(reason: .drafts, token: "draft-\($0)")])
        }).items
    }

    @Test func deniedOrDisabledNotificationsPostNothing() async {
        let delivery = Delivery()
        let service = NotificationService(authorization: { delivery.status }, post: { delivery.requests.append($0) })
        await service.deliverHumanAttention(items())
        #expect(delivery.requests.isEmpty)
        delivery.status = .authorized
        await service.deliverHumanAttention(items(), enabled: false)
        #expect(delivery.requests.isEmpty)
    }

    @Test func authorizedAttentionUsesNativeSoundAndOpensTheMainApplication() async throws {
        let delivery = Delivery(); delivery.status = .authorized
        let service = NotificationService(authorization: { delivery.status }, post: { delivery.requests.append($0) })
        await service.deliverHumanAttention(items())
        let request = try #require(delivery.requests.first)
        #expect(request.content.sound != nil)
        #expect(request.content.userInfo["openMainWindow"] as? Bool == true)
        #expect(request.content.userInfo["url"] == nil)
        #expect(request.content.body == "Example 0")
    }

    @Test func multipleNewHumanItemsAreConsolidated() async {
        let delivery = Delivery(); delivery.status = .authorized
        let service = NotificationService(authorization: { delivery.status }, post: { delivery.requests.append($0) })
        await service.deliverHumanAttention(items(4))
        #expect(delivery.requests.count == 1)
    }
    @Test func failedSubmissionDoesNotAcknowledgePendingActions() async {
        enum Failure: Error { case unavailable }
        let service = NotificationService(authorization: { .authorized }, post: { _ in throw Failure.unavailable })
        let delivered = await service.deliverHumanAttention(items())
        #expect(delivered.isEmpty)
    }

    @Test func cancellationAfterOneSubmissionAcknowledgesOnlyThatSubmission() async {
        let delivery = Delivery()
        let service = NotificationService(authorization: { .authorized }, post: {
            delivery.requests.append($0)
            delivery.cancel?()
        })
        let task = Task { await service.deliverHumanAttention(items(2)) }
        delivery.cancel = { task.cancel() }
        let delivered = await task.value
        #expect(delivered.count == 1)
        #expect(delivery.requests.count == 1)
        delivery.cancel = nil
    }

}
