import SwiftUI

struct NotificationsStep: View {
    let monitor: TodoMonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Onboarding.onboardingNotificationsTitle)
                .font(.title3.weight(.semibold))

            Text(.Onboarding.onboardingNotificationsBody)
                .foregroundStyle(.secondary)

            Toggle(isOn: notificationsEnabledBinding) {
                Text(.Settings.settingsGeneralNotificationsToggle)
            }

            NotificationPermissionView(
                notifications: monitor.notifications,
                enabled: monitor.settings.notificationsEnabled,
                showAuthorizedStatus: true
            )
        }
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { monitor.settings.notificationsEnabled },
            set: { enabled in
                monitor.settings.notificationsEnabled = enabled
                monitor.settings.save()
            }
        )
    }
}
