import Foundation

/// Serializes OS submissions so cancellation cannot make a delivered action appear new again.
@MainActor
final class AttentionNotificationScheduler {
    struct Input {
        let account: String?
        let snapshot: UserAttentionSnapshot
        let fresh: Bool
        let enabled: Bool
    }

    private let notifications: NotificationService
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var ledger = UserAttentionNotificationLedger()

    init(notifications: NotificationService, debounce: Duration = .milliseconds(800)) {
        self.notifications = notifications
        self.debounce = debounce
    }

    @discardableResult
    func schedule(input: @escaping @MainActor () -> Input?) -> Task<Void, Never> {
        let previous = task
        previous?.cancel()
        let current = UUID()
        generation = current
        let next = Task { [weak self] in
            // OS submission can finish after cancellation. Account for it before selecting the next batch.
            await previous?.value
            guard let self else { return }
            do { try await Task.sleep(for: debounce) } catch { return }
            guard !Task.isCancelled, let initial = input() else { return }
            let account = initial.account
            let status = await notifications.currentAuthorizationStatus()
            guard !Task.isCancelled, generation == current, let state = input(), state.account == account else { return }
            let items = ledger.update(state.snapshot, account: account, fresh: state.fresh,
                allowed: state.enabled && NotificationService.permitsDelivery(status))
            guard !Task.isCancelled, let latest = input(), latest.account == account, latest.fresh else { return }
            let delivered = await notifications.deliverHumanAttention(items, enabled: latest.enabled)
            ledger.acknowledge(delivered, account: account)
        }
        task = next
        return next
    }

    /// Legacy periodic raw-to-do reminders are retired; kept for settings callers.
    func restartUnreadReminderTimer() {}
    func stopUnreadReminderTimer() {}
}
