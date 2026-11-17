import Foundation
import Observation
import os
import Testing
@testable import GitLabTodos

@MainActor
struct ObservedPresentationCacheTests {
    @Observable final class Source {
        var account = "first"
        var title = "Before"
        var unrelated = 0
    }

    @Test func repeatedPresentationReadsReuseTheDerivedValue() {
        let source = Source()
        let cache = ObservedPresentationCache<String>()
        var derivations = 0
        func read() -> String {
            cache.value { derivations += 1; return source.title }
        }
        #expect(read() == "Before")
        #expect(read() == "Before")
        #expect(derivations == 1)
        source.unrelated += 1
        #expect(read() == "Before")
        #expect(derivations == 1)
    }

    @Test func aSourceChangeIsVisibleBeforeAnyActorSuspension() {
        let source = Source()
        let cache = ObservedPresentationCache<String>()
        var derivations = 0
        func read() -> String {
            cache.value { derivations += 1; return source.account + "/" + source.title }
        }
        #expect(read() == "first/Before")
        source.title = "After"
        #expect(read() == "first/After")
        source.account = "second"
        #expect(read() == "second/After")
        source.title = "Newest"
        #expect(read() == "second/Newest")
        #expect(derivations == 4)
    }

    @Test func cacheHitsStillSubscribeConsumersToSourceChanges() {
        let source = Source()
        let cache = ObservedPresentationCache<String>()
        _ = cache.value { source.title }
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = cache.value { source.title }
        } onChange: { changed.withLock { $0 = true } }
        source.title = "After"
        #expect(changed.withLock { $0 })
        #expect(cache.value { source.title } == "After")
    }

    @Test func rebuildingTheCacheDoesNotNotifyItsConsumersAgain() {
        let source = Source()
        let cache = ObservedPresentationCache<String>()
        _ = cache.value { source.title }
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        func observe() {
            withObservationTracking { _ = cache.value { source.title } } onChange: {
                notifications.withLock { $0 += 1 }
            }
        }
        observe()
        source.title = "After"
        #expect(notifications.withLock { $0 } == 1)
        observe()
        #expect(cache.value { source.title } == "After")
        #expect(notifications.withLock { $0 } == 1)
        source.title = "Latest"
        #expect(notifications.withLock { $0 } == 2)
    }

    @Test func nestedCachedProjectionsInvalidateSynchronously() {
        let source = Source()
        let inner = ObservedPresentationCache<String>()
        let outer = ObservedPresentationCache<String>()
        var derivations = 0
        func readInner() -> String { inner.value { source.title } }
        func readOuter() -> String { outer.value { derivations += 1; return readInner() + "!" } }
        _ = readInner()
        #expect(readOuter() == "Before!")
        #expect(readOuter() == "Before!")
        source.title = "After"
        #expect(readOuter() == "After!")
        #expect(derivations == 2)
    }

    @Test func changingTheObservedBranchDropsItsPreviousDependencies() {
        let source = Source()
        let cache = ObservedPresentationCache<String>()
        var derivations = 0
        func read() -> String {
            cache.value {
                derivations += 1
                return source.account == "first" ? source.title : "Other account"
            }
        }
        #expect(read() == "Before")
        source.account = "second"
        #expect(read() == "Other account")
        source.title = "After"
        #expect(read() == "Other account")
        #expect(derivations == 2)
    }

    @Test func explicitInvalidationRefreshesInputsOutsideObservation() {
        let cache = ObservedPresentationCache<String>()
        #expect(cache.value { "Before" } == "Before")
        cache.invalidate()
        #expect(cache.value { "After" } == "After")
    }

    @Test func explicitInvalidationRetiresThePreviousSources() {
        let first = Source()
        let second = Source()
        second.title = "Second"
        let cache = ObservedPresentationCache<String>()
        _ = cache.value { first.title }
        cache.invalidate()
        var derivations = 0
        func read() -> String { cache.value { derivations += 1; return second.title } }
        #expect(read() == "Second")
        first.title = "Obsolete"
        #expect(read() == "Second")
        #expect(derivations == 1)
        second.title = "Latest"
        #expect(read() == "Latest")
        #expect(derivations == 2)
    }

    @Test func nilValuesAreCached() {
        let cache = ObservedPresentationCache<String?>()
        var derivations = 0
        let first = cache.value { derivations += 1; return nil }
        let second = cache.value { derivations += 1; return nil }
        #expect(first == nil && second == nil && derivations == 1)
    }
}
