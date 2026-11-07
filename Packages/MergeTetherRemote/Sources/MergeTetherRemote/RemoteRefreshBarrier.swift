import Foundation

@MainActor public enum RemoteRefreshBarrier {
    public static func refresh(deadline: ContinuousClock.Instant,
        isRefreshing: @MainActor () -> Bool,
        refresh: @MainActor () async -> Void,
        validate: @MainActor () async -> Bool) async -> Bool {
        func wait() async -> Bool {
            while isRefreshing() {
                guard ContinuousClock.now < deadline else { return false }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
            }
            return ContinuousClock.now < deadline
        }
        guard await wait() else { return false }
        await refresh()
        guard await wait() else { return false }
        let valid = await validate()
        return valid && !isRefreshing() && ContinuousClock.now < deadline
    }
}
