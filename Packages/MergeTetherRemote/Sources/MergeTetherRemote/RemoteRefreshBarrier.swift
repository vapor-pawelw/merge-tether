import Foundation

@MainActor public enum RemoteRefreshBarrier {
    public static func refresh(deadline: ContinuousClock.Instant,
        isRefreshing: @MainActor () -> Bool,
        refresh: @MainActor () async -> Void,
        validate: @MainActor () async -> Bool) async -> Bool {
        await self.refresh(deadline: deadline, isRefreshing: isRefreshing, refresh: refresh, validate: validate,
            now: { ContinuousClock.now }, pause: { try await Task.sleep(for: .milliseconds(20)) })
    }

    static func refresh(deadline: ContinuousClock.Instant,
        isRefreshing: @MainActor () -> Bool,
        refresh: @MainActor () async -> Void,
        validate: @MainActor () async -> Bool,
        now: @MainActor () -> ContinuousClock.Instant,
        pause: @MainActor () async throws -> Void) async -> Bool {
        func wait() async -> Bool {
            while isRefreshing() {
                guard now() < deadline else { return false }
                do { try await pause() } catch { return false }
            }
            return now() < deadline
        }
        guard await wait() else { return false }
        await refresh()
        guard await wait() else { return false }
        let valid = await validate()
        return valid && !isRefreshing() && now() < deadline
    }
}
