import AppKit
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum DeliveryMode: Equatable { case individual, consolidated }
    private let authorization: @MainActor @Sendable () async -> UNAuthorizationStatus
    private let post: @MainActor @Sendable (UNNotificationRequest) async throws -> Void
    @MainActor var onOpenMainWindow: (@MainActor @Sendable () -> Void)?

    override convenience init() {
        self.init(authorization: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
                  post: { try await UNUserNotificationCenter.current().add($0) }, registerDelegate: true)
    }

    init(authorization: @escaping @MainActor @Sendable () async -> UNAuthorizationStatus,
         post: @escaping @MainActor @Sendable (UNNotificationRequest) async throws -> Void,
         registerDelegate: Bool = false) {
        self.authorization = authorization
        self.post = post
        super.init()
        if registerDelegate { UNUserNotificationCenter.current().delegate = self }
    }

    static func deliveryMode(newCount: Int) -> DeliveryMode { newCount > 3 ? .consolidated : .individual }
    static func permitsDelivery(_ status: UNAuthorizationStatus) -> Bool { status == .authorized || status == .provisional }

    func requestPermission() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { Log.notifications.error("Authorization request failed: \(error.localizedDescription, privacy: .public)") }
    }
    func currentAuthorizationStatus() async -> UNAuthorizationStatus { await authorization() }

    /// Native delivery is the only sound path. Denied/disabled delivery never plays fallback audio.
    @MainActor @discardableResult
    func deliverHumanAttention(_ items: [UserAttentionSnapshot.Item], enabled: Bool = true) async -> [UserAttentionSnapshot.Item] {
        guard enabled, !items.isEmpty, Self.permitsDelivery(await authorization()), !Task.isCancelled else { return [] }
        var delivered: [UserAttentionSnapshot.Item] = []
        let groups = Self.deliveryMode(newCount: items.count) == .consolidated ? [items] : items.map { [$0] }
        for group in groups {
            guard !Task.isCancelled else { return delivered }
            let content = UNMutableNotificationContent()
            if group.count == 1, let item = group.first {
                content.title = String(localized: .Notifications.notificationsAttentionTitle)
                content.subtitle = item.subtitle
                content.body = item.title
            } else {
                content.title = String(localized: .Notifications.notificationsAttentionBatchTitle(group.count))
                content.body = String(localized: .Notifications.notificationsAttentionBody)
            }
            content.userInfo = ["openMainWindow": true]
            content.sound = .default
            let identity = group.map(\.signature).sorted().joined(separator: ":")
            let request = UNNotificationRequest(identifier: "attention-" + UserAttentionSnapshot.digest(identity), content: content, trigger: nil)
            do { try await post(request); delivered.append(contentsOf: group) }
            catch { Log.notifications.error("Failed to post attention notification: \(error.localizedDescription, privacy: .private)") }
        }
        return delivered
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.onOpenMainWindow?()
        }
        completionHandler()
    }
}
