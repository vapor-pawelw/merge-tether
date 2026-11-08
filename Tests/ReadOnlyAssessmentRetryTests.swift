import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct ReadOnlyAssessmentRetryTests {
    private struct ReadFailure: Error {}

    @Test func retriesTwiceWithBackoffThenReturnsEvidence() async throws {
        var calls = 0
        var delays: [Duration] = []
        let result = try await ReadOnlyAssessmentRetry.run(isCurrent: { true }, wait: { delays.append($0) }) {
            calls += 1
            if calls < 3 { throw ReadFailure() }
            return "current evidence"
        }
        #expect(result == "current evidence")
        #expect(calls == 3 && delays == [.seconds(2), .seconds(8)])
    }

    @Test func changedContextDuringBackoffStopsBeforeAnotherRead() async throws {
        var calls = 0
        var current = true
        do {
            _ = try await ReadOnlyAssessmentRetry.run(isCurrent: { current }, wait: { _ in current = false }) {
                calls += 1
                throw ReadFailure()
            }
            Issue.record("A changed context must cancel the assessment")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(calls == 1)
    }

    @Test func cancellationNeverReceivesAnotherAttempt() async throws {
        var calls = 0
        var waits = 0
        do {
            _ = try await ReadOnlyAssessmentRetry.run(isCurrent: { true }, wait: { _ in waits += 1 }) {
                calls += 1
                throw CancellationError()
            }
            Issue.record("Cancellation must propagate")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(calls == 1 && waits == 0)
    }
}
