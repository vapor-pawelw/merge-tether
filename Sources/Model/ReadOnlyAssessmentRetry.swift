import Foundation

/// Retries evidence gathering only; callers must keep executable MR actions outside this boundary.
@MainActor
enum ReadOnlyAssessmentRetry {
    typealias Wait = @MainActor (Duration) async throws -> Void
    typealias Clock = @MainActor () -> Date
    static let cooldown: TimeInterval = 15 * 60

    static func wait(_ delay: Duration) async throws { try await Task.sleep(for: delay) }

    static func run<Value>(isCurrent: @MainActor () -> Bool,
                           wait: Wait = ReadOnlyAssessmentRetry.wait,
                           onRetry: @MainActor () -> Void = {},
                           operation: @MainActor () async throws -> Value) async throws -> Value {
        let delays: [Duration] = [.seconds(2), .seconds(8)]
        var failures = 0
        while true {
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            do {
                let value = try await operation()
                guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
                return value
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), isCurrent(), failures < delays.count else { throw error }
                onRetry()
                try await wait(delays[failures])
                failures += 1
            }
        }
    }
}
