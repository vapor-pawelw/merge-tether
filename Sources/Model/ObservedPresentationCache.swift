import Observation
import os

/// Deliver after the current MainActor mutation so source and cache notifications cannot reenter each other.
typealias PresentationNotificationScheduler = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

enum PresentationNotificationDelivery {
    static func schedule(_ notification: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in notification() }
    }
}

@MainActor
final class ObservedPresentationCache<Value> {
    private struct Entry {
        let generation: PresentationCacheInvalidation.Generation
        let dependencies: [PresentationCacheDependency]
        let value: Value
    }

    private let invalidation: PresentationCacheInvalidation
    private var cached: Entry?

    init(scheduleNotification: @escaping PresentationNotificationScheduler = PresentationNotificationDelivery.schedule) {
        invalidation = PresentationCacheInvalidation(scheduleNotification: scheduleNotification)
    }

    func value(_ makeValue: () -> Value) -> Value {
        if let cached {
            if invalidation.isCurrent(cached.generation.revision), cached.dependencies.allSatisfy(\.isCurrent) {
                return observe(cached)
            }
            invalidation.invalidate(expected: cached.generation.revision)
        }
        let generation = invalidation.generation
        let invalidation = self.invalidation
        let revision = generation.revision
        let (value, dependencies) = PresentationCacheDependencyTracking.collect {
            withObservationTracking(makeValue) {
                invalidation.invalidate(expected: revision)
            }
        }
        let entry = Entry(generation: generation, dependencies: dependencies, value: value)
        cached = entry
        return observe(entry)
    }

    private func observe(_ entry: Entry) -> Value {
        PresentationCacheDependencyTracking.record(owner: invalidation, revision: entry.generation.revision,
            dependencies: entry.dependencies)
        entry.generation.signal.observe()
        return entry.value
    }

    func invalidate() {
        cached = nil
        invalidation.invalidateManually()
    }
}

private struct PresentationCacheDependency {
    let owner: PresentationCacheInvalidation
    let revision: UInt64
    var isCurrent: Bool { owner.isCurrent(revision) }
}

@MainActor
private enum PresentationCacheDependencyTracking {
    private final class Collector {
        var dependencies: [ObjectIdentifier: PresentationCacheDependency] = [:]

        func record(_ dependency: PresentationCacheDependency) {
            let id = ObjectIdentifier(dependency.owner)
            if dependencies[id] == nil { dependencies[id] = dependency }
        }
    }
    private static var current: Collector?

    static func collect<Value>(_ makeValue: () -> Value) -> (Value, [PresentationCacheDependency]) {
        let parent = current
        let collector = Collector()
        current = collector
        defer { current = parent }
        let value = makeValue()
        return (value, Array(collector.dependencies.values))
    }

    static func record(owner: PresentationCacheInvalidation, revision: UInt64,
                       dependencies: [PresentationCacheDependency]) {
        guard let current else { return }
        current.record(.init(owner: owner, revision: revision))
        for dependency in dependencies { current.record(dependency) }
    }
}

private final class PresentationCacheSignal: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let version = OSAllocatedUnfairLock(initialState: UInt64(0))

    private var revision: UInt64 {
        registrar.access(self, keyPath: \.revision)
        return version.withLock { $0 }
    }

    @MainActor func observe() { _ = revision }

    @MainActor func notify() {
        registrar.withMutation(of: self, keyPath: \.revision) { version.withLock { $0 &+= 1 } }
    }
}

private final class PresentationCacheInvalidation: @unchecked Sendable {
    struct Generation {
        let revision: UInt64
        let signal: PresentationCacheSignal
    }
    private struct State {
        var revision: UInt64 = 0
        var signal = PresentationCacheSignal()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let scheduleNotification: PresentationNotificationScheduler

    init(scheduleNotification: @escaping PresentationNotificationScheduler) {
        self.scheduleNotification = scheduleNotification
    }

    var generation: Generation {
        state.withLock { Generation(revision: $0.revision, signal: $0.signal) }
    }

    func isCurrent(_ revision: UInt64) -> Bool { state.withLock { $0.revision == revision } }

    // Invalidate before the next read, but notify after source willSet finishes. A signal
    // belongs to one generation so queued notifications cannot invalidate newer consumers.
    func invalidate(expected: UInt64) {
        guard let signal = advance(expected: expected) else { return }
        scheduleNotification { signal.notify() }
    }

    @MainActor func invalidateManually() {
        advance(expected: nil)?.notify()
    }

    private func advance(expected: UInt64?) -> PresentationCacheSignal? {
        state.withLock { state in
            guard expected == nil || state.revision == expected else { return nil }
            let previous = state.signal
            state.revision &+= 1
            state.signal = PresentationCacheSignal()
            return previous
        }
    }
}
