import Foundation
import Observation

/// The initial catalog sync is distinct from later background refreshes.
enum BoardRefreshState: Equatable {
    case syncing, unavailable, current

    init(todosReady: Bool, catalogReady: Bool, authoredReady: Bool,
         isRefreshing: Bool, hasError: Bool) {
        if todosReady && catalogReady && authoredReady { self = .current }
        else { self = isRefreshing || !hasError ? .syncing : .unavailable }
    }
}

enum RefreshProgressScope: Hashable {
    case global
    case mergeRequest(MergeRequestAttentionMonitor.Item.ID)
}

/// Explicit user intent affects presentation only; fetch state remains owned by the monitors.
@MainActor @Observable
final class RefreshProgressState {
    private struct Intent { let scope: RefreshProgressScope; let accountRevision: UInt64 }
    private var intents: [UUID: Intent] = [:]

    func showsGlobal(accountRevision: UInt64) -> Bool {
        intents.values.contains { $0.accountRevision == accountRevision && $0.scope == .global }
    }
    func showsRefresh(for id: MergeRequestAttentionMonitor.Item.ID, accountRevision: UInt64) -> Bool {
        intents.values.contains {
            $0.accountRevision == accountRevision && ($0.scope == .global || $0.scope == .mergeRequest(id))
        }
    }

    func perform(scope: RefreshProgressScope, accountRevision: UInt64,
                 currentAccountRevision: @MainActor () -> UInt64,
                 isRefreshing: @MainActor () -> Bool,
                 refresh: @MainActor () async -> Void,
                 wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }) async {
        let token = UUID()
        intents[token] = .init(scope: scope, accountRevision: accountRevision)
        defer { intents.removeValue(forKey: token) }
        await refresh()
        while !Task.isCancelled, currentAccountRevision() == accountRevision, isRefreshing() {
            do { try await wait() } catch { return }
        }
    }
}
