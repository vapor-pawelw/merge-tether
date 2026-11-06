import Testing
@testable import GitLabTodos

struct BoardRefreshStateTests {
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
