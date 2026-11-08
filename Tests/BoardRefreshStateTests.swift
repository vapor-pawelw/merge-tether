import Foundation
import Testing
@testable import GitLabTodos

struct BoardRefreshStateTests {
    @MainActor
    @Test func explicitMRProgressWaitsForCoalescedCatalogReadsWithoutAffectingOtherCards() async {
        let state = RefreshProgressState()
        let target = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 2)
        let other = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 3)
        var catalogLoading = true
        var refreshCalls = 0
        var waits = 0
        await state.perform(scope: .mergeRequest(target), accountRevision: 1, currentAccountRevision: { 1 },
            isRefreshing: { catalogLoading }, refresh: {
                refreshCalls += 1
                #expect(state.showsRefresh(for: target, accountRevision: 1))
                #expect(!state.showsRefresh(for: other, accountRevision: 1))
                #expect(!state.showsGlobal(accountRevision: 1))
            }, wait: {
                waits += 1
                #expect(state.showsRefresh(for: target, accountRevision: 1))
                catalogLoading = false
            })
        #expect(refreshCalls == 1 && waits == 1)
        #expect(!state.showsRefresh(for: target, accountRevision: 1))
    }

    @MainActor
    @Test func overlappingGlobalAndMRRequestsRetainOnlyTheirOwnVisualIntent() async {
        let state = RefreshProgressState()
        let target = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 2)
        let other = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 3)
        await state.perform(scope: .mergeRequest(target), accountRevision: 1, currentAccountRevision: { 1 },
            isRefreshing: { false }, refresh: {
                await state.perform(scope: .global, accountRevision: 1, currentAccountRevision: { 1 },
                    isRefreshing: { false }, refresh: {
                        #expect(state.showsGlobal(accountRevision: 1))
                        #expect(state.showsRefresh(for: target, accountRevision: 1))
                        #expect(state.showsRefresh(for: other, accountRevision: 1))
                    })
                #expect(!state.showsGlobal(accountRevision: 1))
                #expect(state.showsRefresh(for: target, accountRevision: 1))
                #expect(!state.showsRefresh(for: other, accountRevision: 1))
            })
        #expect(!state.showsRefresh(for: target, accountRevision: 1))
    }

    @MainActor
    @Test func accountSwitchEndsVisibleIntentWithoutWaitingOrRepeatingReads() async {
        let state = RefreshProgressState()
        var revision: UInt64 = 1
        var refreshCalls = 0
        var waits = 0
        await state.perform(scope: .global, accountRevision: revision, currentAccountRevision: { revision },
            isRefreshing: { true }, refresh: {
                refreshCalls += 1
                #expect(state.showsGlobal(accountRevision: 1))
                revision = 2
                #expect(!state.showsGlobal(accountRevision: revision))
            }, wait: { waits += 1 })
        #expect(refreshCalls == 1 && waits == 0)
        #expect(!state.showsGlobal(accountRevision: 1))
    }

    @Test func startupWaitsForAllCatalogSourcesEvenBeforeTheFirstRequestStarts() {
        #expect(BoardRefreshState(todosReady: false, catalogReady: false, authoredReady: false,
                                  isRefreshing: false, hasError: false) == .syncing)
    }

    @Test(arguments: [0, 1, 2])
    func partialInitialResultsRemainVisiblyUnverified(_ missingSource: Int) {
        #expect(BoardRefreshState(todosReady: missingSource != 0, catalogReady: missingSource != 1,
                                  authoredReady: missingSource != 2, isRefreshing: true, hasError: false) == .syncing)
    }

    @Test func failedInitialSyncStopsTheLoaderWithoutClaimingFreshness() {
        #expect(BoardRefreshState(todosReady: true, catalogReady: false, authoredReady: true,
                                  isRefreshing: false, hasError: true) == .unavailable)
    }

    @Test func retryShowsProgressWhileAFormerErrorIsStillVisible() {
        #expect(BoardRefreshState(todosReady: true, catalogReady: false, authoredReady: true,
                                  isRefreshing: true, hasError: true) == .syncing)
    }

    @Test func backgroundRefreshDoesNotDimAlreadySynchronizedCards() {
        #expect(BoardRefreshState(todosReady: true, catalogReady: true, authoredReady: true,
                                  isRefreshing: true, hasError: false) == .current)
    }

    @Test func backgroundFailureDoesNotReenterTheInitialLoadingState() {
        #expect(BoardRefreshState(todosReady: true, catalogReady: true, authoredReady: true,
                                  isRefreshing: false, hasError: true) == .current)
    }
}
