import Foundation
import Observation
import os
import Testing
@testable import GitLabTodos

final class DeferredPresentationNotifications: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@MainActor @Sendable () -> Void]())

    func schedule(_ notification: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0.append(notification) }
    }

    @MainActor func flush() {
        while true {
            let batch = pending.withLock { operations in
                let batch = operations
                operations.removeAll()
                return batch
            }
            guard !batch.isEmpty else { return }
            for notification in batch { notification() }
        }
    }
}

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
        let delivery = DeferredPresentationNotifications()
        let cache = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
        _ = cache.value { source.title }
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = cache.value { source.title }
        } onChange: { changed.withLock { $0 = true } }
        source.title = "After"
        delivery.flush()
        #expect(changed.withLock { $0 })
        #expect(cache.value { source.title } == "After")
    }

    @Test func rebuildingTheCacheDoesNotNotifyItsConsumersAgain() {
        for _ in 0..<128 {
            let source = Source()
            let delivery = DeferredPresentationNotifications()
            let cache = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
            _ = cache.value { source.title }
            let notifications = OSAllocatedUnfairLock(initialState: 0)
            func observe() {
                withObservationTracking { _ = cache.value { source.title } } onChange: {
                    notifications.withLock { $0 += 1 }
                }
            }
            observe()
            source.title = "After"
            delivery.flush()
            #expect(notifications.withLock { $0 } == 1)
            observe()
            #expect(cache.value { source.title } == "After")
            #expect(notifications.withLock { $0 } == 1)
            source.title = "Latest"
            delivery.flush()
            #expect(notifications.withLock { $0 } == 2)
        }
    }

    @Test func coldConsumersRemainObservableWhenExplicitlyInvalidated() {
        let cache = ObservedPresentationCache<String>()
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = cache.value { "Constant projection" } } onChange: {
            notifications.withLock { $0 += 1 }
        }
        cache.invalidate()
        #expect(notifications.withLock { $0 } == 1)
        #expect(cache.value { "Updated projection" } == "Updated projection")
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

    @Test func aHotCacheAndItsRawSourceNotifyOneConsumerOnlyOnce() {
        for _ in 0..<128 {
            let source = Source()
            let delivery = DeferredPresentationNotifications()
            let cache = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
            _ = cache.value { source.title }
            let notifications = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = cache.value { source.title }
                _ = source.title
            } onChange: { notifications.withLock { $0 += 1 } }
            source.title = "After"
            #expect(notifications.withLock { $0 } == 1)
            delivery.flush()
            #expect(notifications.withLock { $0 } == 1)
        }
    }

    @Test func transitiveCachedDependenciesAreFreshBeforeNotificationsRun() {
        let source = Source()
        let delivery = DeferredPresentationNotifications()
        let inner = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
        let middle = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
        let outer = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
        func readInner() -> String { inner.value { source.title } }
        func readMiddle() -> String { middle.value { readInner() + "?" } }
        func readOuter() -> String { outer.value { readMiddle() + "!" } }
        _ = readInner()
        _ = readMiddle()
        #expect(readOuter() == "Before?!")
        source.title = "After"
        #expect(readOuter() == "After?!")
        source.title = "Latest"
        #expect(readOuter() == "Latest?!")
        delivery.flush()
        #expect(readOuter() == "Latest?!")
    }

    @Test func delayedEventsNotifyOldConsumersWithoutInvalidatingRecomputedConsumers() {
        let source = Source()
        let delivery = DeferredPresentationNotifications()
        let cache = ObservedPresentationCache<String>(scheduleNotification: delivery.schedule)
        _ = cache.value { source.title }
        let oldNotifications = OSAllocatedUnfairLock(initialState: 0)
        let newNotifications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = cache.value { source.title } } onChange: {
            oldNotifications.withLock { $0 += 1 }
        }
        source.title = "After"
        #expect(oldNotifications.withLock { $0 } == 0)
        withObservationTracking { _ = cache.value { source.title } } onChange: {
            newNotifications.withLock { $0 += 1 }
        }
        delivery.flush()
        #expect(oldNotifications.withLock { $0 } == 1)
        #expect(newNotifications.withLock { $0 } == 0)
        source.title = "Latest"
        delivery.flush()
        #expect(newNotifications.withLock { $0 } == 1)
        #expect(cache.value { source.title } == "Latest")
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
