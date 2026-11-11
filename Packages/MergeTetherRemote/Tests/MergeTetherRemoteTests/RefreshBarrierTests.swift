import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct RefreshBarrierTests {
    @Test func aCommandWaitsForTheOldFetchAndForItsOwnBackgroundRefresh() async {
        var loading = true, requests = 0
        var instant = ContinuousClock.now
        var events: [String] = []
        let fresh = await RemoteRefreshBarrier.refresh(deadline: instant + .seconds(2), isRefreshing: { loading }, refresh: {
            #expect(!loading)
            events.append("refresh started")
            requests += 1; loading = true
        }, validate: {
            events.append("validated")
            return !loading
        }, now: { instant }, pause: {
            events.append(requests == 0 ? "old fetch finished" : "fresh fetch finished")
            loading = false
            instant = instant.advanced(by: .milliseconds(20))
        })
        #expect(fresh)
        #expect(requests == 1)
        #expect(events == ["old fetch finished", "refresh started", "fresh fetch finished", "validated"])
    }

    @Test func aStuckRefreshCannotAuthorizeACommand() async {
        var instant = ContinuousClock.now
        var pauses = 0
        let fresh = await RemoteRefreshBarrier.refresh(deadline: instant + .milliseconds(20), isRefreshing: { true }, refresh: {
            Issue.record("A second fetch started while the first was still busy")
        }, validate: {
            Issue.record("A stuck fetch reached validation")
            return true
        }, now: { instant }, pause: {
            pauses += 1
            instant = instant.advanced(by: .milliseconds(20))
        })
        #expect(!fresh)
        #expect(pauses == 1)
    }

    @Test func anExpiredPublicDeadlineCannotStartARefresh() async {
        let fresh = await RemoteRefreshBarrier.refresh(deadline: .now, isRefreshing: { false }, refresh: {
            Issue.record("An expired request started a refresh")
        }, validate: {
            Issue.record("An expired request reached validation")
            return true
        })
        #expect(!fresh)
    }

    @Test func cancellationWhileWaitingCannotStartARefresh() async {
        let instant = ContinuousClock.now
        let fresh = await RemoteRefreshBarrier.refresh(deadline: instant + .seconds(2), isRefreshing: { true }, refresh: {
            Issue.record("A canceled wait started a refresh")
        }, validate: {
            Issue.record("A canceled wait reached validation")
            return true
        }, now: { instant }, pause: { throw CancellationError() })
        #expect(!fresh)
    }

    @Test func validationCannotAuthorizeAfterTheDeadline() async {
        var instant = ContinuousClock.now
        let deadline = instant + .seconds(2)
        var requests = 0, validations = 0
        let fresh = await RemoteRefreshBarrier.refresh(deadline: deadline, isRefreshing: { false }, refresh: {
            requests += 1
        }, validate: {
            validations += 1
            instant = deadline
            return true
        }, now: { instant }, pause: { Issue.record("An idle fetch should not wait") })
        #expect(!fresh)
        #expect(requests == 1)
        #expect(validations == 1)
    }
}
