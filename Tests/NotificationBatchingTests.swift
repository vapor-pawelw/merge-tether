import Foundation
import Testing
@testable import MergeTether

@Suite("NotificationService batching")
struct NotificationBatchingTests {
    @Test("zero new → individual (no notification is ever posted)")
    func zero() {
        #expect(NotificationService.deliveryMode(newCount: 0) == .individual)
    }

    @Test("up to three new → individual notifications")
    func upToThree() {
        #expect(NotificationService.deliveryMode(newCount: 1) == .individual)
        #expect(NotificationService.deliveryMode(newCount: 2) == .individual)
        #expect(NotificationService.deliveryMode(newCount: 3) == .individual)
    }

    @Test("four or more → consolidated notification")
    func fourOrMore() {
        #expect(NotificationService.deliveryMode(newCount: 4) == .consolidated)
        #expect(NotificationService.deliveryMode(newCount: 10) == .consolidated)
        #expect(NotificationService.deliveryMode(newCount: 100) == .consolidated)
    }
}
