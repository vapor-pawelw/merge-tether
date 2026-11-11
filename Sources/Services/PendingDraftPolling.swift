import Foundation

@MainActor
final class PendingDraftPolling {
    typealias Wait = @MainActor () async throws -> Void
    private let wait: Wait
    private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var task: Task<Void, Never>?
    private var refresh: (@MainActor () async -> Void)?
    var observerCount: Int { observers.count }

    init(wait: @escaping Wait = { try await Task.sleep(for: .seconds(5)) }) {
        self.wait = wait
    }

    func observe(refresh: @escaping @MainActor () async -> Void) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                observers[id] = continuation
                self.refresh = refresh
                startIfNeeded()
            }
        } onCancel: {
            Task { @MainActor in self.remove(id) }
        }
    }

    private func remove(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume()
        if observers.isEmpty {
            refresh = nil
            task?.cancel()
        }
    }

    private func startIfNeeded() {
        guard task == nil, !observers.isEmpty else { return }
        task = Task {
            defer {
                task = nil
                // A returning view waits for the cancelled read to drain first.
                startIfNeeded()
            }
            while !Task.isCancelled, let refresh {
                await refresh()
                guard !Task.isCancelled else { return }
                do { try await wait() } catch { return }
            }
        }
    }
}
