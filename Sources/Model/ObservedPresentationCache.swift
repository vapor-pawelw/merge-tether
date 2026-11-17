import Observation
import os

@MainActor
final class ObservedPresentationCache<Value> {
    private let invalidation = PresentationCacheInvalidation()
    private var cached: (revision: UInt64, value: Value)?

    func value(_ makeValue: () -> Value) -> Value {
        let revision = invalidation.revision
        if let cached, cached.revision == revision { return cached.value }
        let invalidation = self.invalidation
        let value = withObservationTracking(makeValue) {
            invalidation.invalidate(expected: revision)
        }
        cached = (revision, value)
        return value
    }

    func invalidate() {
        invalidation.invalidate()
        cached = nil
    }
}

// Observation calls onChange from willSet, outside actor isolation. Notify synchronously
// so nested display caches cannot reuse an older account before the next actor turn.
private final class PresentationCacheInvalidation: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    var revision: UInt64 {
        registrar.access(self, keyPath: \.revision)
        return generation.withLock { $0 }
    }

    func invalidate(expected: UInt64? = nil) {
        guard expected.map({ expected in generation.withLock { $0 == expected } }) ?? true else { return }
        registrar.withMutation(of: self, keyPath: \.revision) {
            generation.withLock { value in
                if expected == nil || value == expected { value &+= 1 }
            }
        }
    }
}
