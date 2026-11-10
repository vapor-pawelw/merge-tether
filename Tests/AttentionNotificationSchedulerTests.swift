import Foundation
import Testing
import UserNotifications
@testable import GitLabTodos

@MainActor
struct AttentionNotificationSchedulerTests {
    @MainActor private final class Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
    @MainActor private final class State {
        var account: String? = "host/me"
        var fresh = true
        var enabled = true
        var holdAuthorization = false
        var failSubmission = false
        var token = "baseline"
        var requests: [UNNotificationRequest] = []
        var input: AttentionNotificationScheduler.Input {
            .init(account: account, snapshot: .init(candidates: [
                .init(id: "mr", title: "Example", actions: [.init(reason: .drafts, token: token)])
            ]), fresh: fresh, enabled: enabled)
        }
    }

    @Test func refreshesCoalesceAndUnfreshOrDisabledAttentionStaysSilent() async {
        let state = State()
        let notifications = NotificationService(authorization: { .authorized }, post: { state.requests.append($0) })
        let scheduler = AttentionNotificationScheduler(notifications: notifications, debounce: .zero)
        await scheduler.schedule { state.input }.value
        state.token = "new"
        state.fresh = false
        await scheduler.schedule { state.input }.value
        #expect(state.requests.isEmpty)
        state.fresh = true
        await scheduler.schedule { state.input }.value
        await scheduler.schedule { state.input }.value
        #expect(state.requests.count == 1)
        state.enabled = false
        state.token = "disabled"
        await scheduler.schedule { state.input }.value
        state.enabled = true
        await scheduler.schedule { state.input }.value
        #expect(state.requests.count == 1)
    }

    @Test func aCancelledOSSubmissionIsRecordedBeforeTheNextSelection() async {
        let state = State()
        let entered = Gate(), release = Gate()
        let notifications = NotificationService(authorization: { .authorized }, post: {
            state.requests.append($0)
            entered.open()
            await release.wait()
        })
        let scheduler = AttentionNotificationScheduler(notifications: notifications, debounce: .zero)
        await scheduler.schedule { state.input }.value
        state.token = "new"
        let first = scheduler.schedule { state.input }
        await entered.wait()
        let next = scheduler.schedule { state.input }
        release.open()
        await first.value
        await next.value
        #expect(state.requests.count == 1)
    }

    @Test func accountChangesDuringAuthorizationCannotDeliverTheOldSnapshot() async {
        let state = State()
        let entered = Gate(), release = Gate()
        let notifications = NotificationService(authorization: {
            if state.holdAuthorization { entered.open(); await release.wait() }
            return .authorized
        }, post: { state.requests.append($0) })
        let scheduler = AttentionNotificationScheduler(notifications: notifications, debounce: .zero)
        await scheduler.schedule { state.input }.value
        state.token = "new"
        state.holdAuthorization = true
        let pending = scheduler.schedule { state.input }
        await entered.wait()
        state.account = "host/other"
        release.open()
        await pending.value
        #expect(state.requests.isEmpty)
        await scheduler.schedule { state.input }.value
        #expect(state.requests.isEmpty)
    }

    @Test func signingOutClearsTheBaselineBeforeTheSameAccountReturns() async {
        let state = State()
        let notifications = NotificationService(authorization: { .authorized }, post: { state.requests.append($0) })
        let scheduler = AttentionNotificationScheduler(notifications: notifications, debounce: .zero)
        await scheduler.schedule { state.input }.value
        state.account = nil
        state.fresh = false
        await scheduler.schedule { state.input }.value
        state.account = "host/me"
        state.fresh = true
        state.token = "changed-while-away"
        await scheduler.schedule { state.input }.value
        #expect(state.requests.isEmpty)
        state.token = "new-after-return"
        await scheduler.schedule { state.input }.value
        #expect(state.requests.count == 1)
    }


    @Test func aFailedOSSubmissionRemainsPendingUntilTheNextSuccessfulDelivery() async {
        let state = State()
        let notifications = NotificationService(authorization: { .authorized }, post: {
            if state.failSubmission { throw CocoaError(.fileWriteUnknown) }
            state.requests.append($0)
        })
        let scheduler = AttentionNotificationScheduler(notifications: notifications, debounce: .zero)
        await scheduler.schedule { state.input }.value
        state.token = "new"
        state.failSubmission = true
        await scheduler.schedule { state.input }.value
        #expect(state.requests.isEmpty)
        state.failSubmission = false
        await scheduler.schedule { state.input }.value
        await scheduler.schedule { state.input }.value
        #expect(state.requests.count == 1)
    }

}
