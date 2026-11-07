import Foundation
import Testing
@testable import MergeTetherRemote

@MainActor @Suite struct RefreshBarrierTests {
    @Test func aCommandWaitsForTheOldFetchAndForItsOwnBackgroundRefresh() async throws {
        var loading = true, requests = 0
        let old = Task { try? await Task.sleep(for: .milliseconds(20)); loading = false }
        let fresh = await RemoteRefreshBarrier.refresh(deadline: .now + .seconds(2), isRefreshing: { loading }, refresh: {
            #expect(!loading)
            requests += 1; loading = true
            Task { try? await Task.sleep(for: .milliseconds(20)); loading = false }
        }, validate: { !loading })
        await old.value
        #expect(fresh)
        #expect(requests == 1)
    }
    @Test func aStuckRefreshCannotAuthorizeACommand() async {
        let fresh = await RemoteRefreshBarrier.refresh(deadline: .now + .milliseconds(20), isRefreshing: { true }, refresh: {
            Issue.record("A second fetch started while the first was still busy")
        }, validate: { false })
        #expect(!fresh)
    }
}
