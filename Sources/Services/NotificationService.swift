import AppKit
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let unreadReminderIdentifier = "todo-unread-reminder"

    enum DeliveryMode: Equatable {
        case individual
        case consolidated
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Pure helper — used at the call site and directly from tests.
    static func deliveryMode(newCount: Int) -> DeliveryMode {
        newCount > 3 ? .consolidated : .individual
    }

    func requestPermission() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.notifications.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func deliver(newTodos: [Todo], dashboardURL: URL?) {
        guard !newTodos.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        NSSound(named: "Submarine")?.play()

        switch Self.deliveryMode(newCount: newTodos.count) {
        case .individual:
            for todo in newTodos {
                let content = UNMutableNotificationContent()
                content.title = String(localized: .Notifications.notificationsSingleTitle)
                content.subtitle = todo.project.pathWithNamespace
                content.body = todo.displayTitle
                content.userInfo = ["url": todo.targetURL.absoluteString]
                content.sound = nil
                let request = UNNotificationRequest(
                    identifier: "todo-\(todo.id)",
                    content: content,
                    trigger: nil
                )
                center.add(request) { error in
                    if let error {
                        Log.notifications.error("Failed to post: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        case .consolidated:
            let content = UNMutableNotificationContent()
            content.title = String(localized: .Notifications.notificationsBatchTitle(newTodos.count))
            content.body = String(localized: .Notifications.notificationsBatchBody)
            if let dashboardURL {
                content.userInfo = ["url": dashboardURL.absoluteString]
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "todo-batch-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Log.notifications.error("Failed to post batch: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func deliverWorkflowEvent(_ event: MergeWorkflowEvent, requiresHandoff: Bool) {
        let request = event.mergeRequest
        let content = UNMutableNotificationContent()
        content.title = String(localized: .Notifications.notificationsWorkflowTitle)
        content.subtitle = "!\(request.iid) \(request.title)"
        content.body = requiresHandoff
            ? String(localized: .Notifications.notificationsWorkflowHandoff)
            : String(localized: .Notifications.notificationsWorkflowUpdate)
        content.userInfo = ["url": request.webURL.absoluteString]
        let notification = UNNotificationRequest(
            identifier: "workflow-\(event.kind.rawValue)-\(request.projectID)-\(request.iid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Log.notifications.error("Failed to post merge workflow update: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func deliverUnresolvedMergeRequest(_ request: GitLabMergeRequest) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: .Notifications.notificationsMergeRequestDiscussionsTitle)
        content.subtitle = "!\(request.iid) \(request.title)"
        content.body = String(localized: .Notifications.notificationsMergeRequestDiscussionsBody)
        content.userInfo = ["url": request.webURL.absoluteString]
        content.sound = .default
        let notification = UNNotificationRequest(
            identifier: "mr-discussions-\(request.projectID)-\(request.iid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Log.notifications.error("Failed to post unresolved discussions reminder: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func deliverAutoApproved(_ request: GitLabMergeRequest) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: .Notifications.notificationsAutoApprovedTitle)
        content.subtitle = "!\(request.iid) \(request.title)"
        content.body = String(localized: .Notifications.notificationsAutoApprovedBody)
        content.userInfo = ["url": request.webURL.absoluteString]
        let notification = UNNotificationRequest(
            identifier: "mr-approved-\(request.projectID)-\(request.iid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Log.notifications.error("Failed to post automatic approval: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func deliverUnreadReminder(todoCount: Int, dashboardURL: URL?, sound: ReminderSound) {
        guard todoCount > 0 else { return }
        let center = UNUserNotificationCenter.current()
        if let soundName = sound.soundName {
            NSSound(named: soundName)?.play()
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: .Notifications.notificationsReminderTitle(todoCount))
        content.body = String(localized: .Notifications.notificationsReminderBody)
        if let dashboardURL {
            content.userInfo = ["url": dashboardURL.absoluteString]
        }
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: Self.unreadReminderIdentifier,
            content: content,
            trigger: nil
        )

        center.removeDeliveredNotifications(withIdentifiers: [Self.unreadReminderIdentifier])
        center.add(request) { error in
            if let error {
                Log.notifications.error("Failed to post unread reminder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString)
        {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
