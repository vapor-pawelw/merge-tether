import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct PendingDraftPollingTests {
    @Test func boardAndInboxShareOneLoopUntilTheLastViewLeaves() async throws {
        let gate = InMemoryGitLab()
        defer { gate.close() }
        var reads = 0
        var waits = 0
        let polling = PendingDraftPolling(wait: {
            waits += 1
            try await gate.waitFor("tick-\(waits)")
        })
        let refresh: @MainActor () async -> Void = { reads += 1 }
        let board = Task { await polling.observe(refresh: refresh) }
        defer { board.cancel() }
        try await eventually { waits == 1 }
        let inbox = Task { await polling.observe(refresh: refresh) }
        defer { inbox.cancel() }
        try await eventually { polling.observerCount == 2 }
        #expect(reads == 1)

        board.cancel()
        await board.value
        #expect(polling.observerCount == 1)
        gate.write("tick-1")
        try await eventually { waits == 2 }
        #expect(reads == 2)
        inbox.cancel()
        await inbox.value
        #expect(polling.observerCount == 0)
        gate.write("tick-2")
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 2)
    }

    @Test func returningWhileACancelledReadFinishesDoesNotCreateOverlappingLoops() async throws {
        let gate = InMemoryGitLab()
        defer { gate.close() }
        var reads = 0
        var active = 0
        var maximum = 0
        let polling = PendingDraftPolling(wait: { try await gate.waitFor("tick") })
        let refresh: @MainActor () async -> Void = {
            reads += 1
            active += 1
            maximum = max(maximum, active)
            if reads == 1 { try? await gate.waitFor("release-first") }
            active -= 1
        }
        let first = Task { await polling.observe(refresh: refresh) }
        try await eventually { reads == 1 }
        first.cancel()
        await first.value
        let returning = Task { await polling.observe(refresh: refresh) }
        defer { returning.cancel() }
        try await eventually { polling.observerCount == 1 }
        #expect(reads == 1)
        gate.write("release-first")
        try await eventually { reads == 2 }
        #expect(maximum == 1)
        returning.cancel()
        await returning.value
        gate.write("tick")
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
}
