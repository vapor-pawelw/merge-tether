import AppKit
import SwiftUI
import UserNotifications

struct GeneralSettingsTab: View {
    @Bindable var monitor: TodoMonitorService

    @State private var launchAtLogin: Bool = LaunchAtLoginService.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text(.Settings.settingsGeneralStartupLaunchAtLogin)
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try LaunchAtLoginService.setEnabled(newValue)
                        monitor.settings.launchAtLoginPreference = newValue
                        monitor.settings.save()
                    } catch {
                        Log.settings.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                        launchAtLogin = !newValue
                    }
                }
            } header: {
                Text(.Settings.settingsGeneralStartupSection)
            }

            Section {
                Picker(selection: refreshIntervalBinding) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayLabel)
                            .tag(interval)
                    }
                } label: {
                    Text(.Settings.settingsGeneralRefreshPicker)
                }
            } header: {
                Text(.Settings.settingsGeneralRefreshSection)
            }

            Section {
                Toggle(isOn: notificationsEnabledBinding) {
                    Text(.Settings.settingsGeneralNotificationsToggle)
                }

                NotificationPermissionView(
                    notifications: monitor.notifications,
                    enabled: monitor.settings.notificationsEnabled
                )
            } header: {
                Text(.Settings.settingsGeneralNotificationsSection)
            }
        }
        .formStyle(.grouped)
        .task {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }

    private var refreshIntervalBinding: Binding<RefreshInterval> {
        Binding(
            get: { monitor.settings.refreshInterval },
            set: { newValue in
                monitor.settings.refreshInterval = newValue
                monitor.settings.save()
                monitor.restartTimer()
            }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { monitor.settings.notificationsEnabled },
            set: { newValue in
                monitor.settings.notificationsEnabled = newValue
                monitor.settings.save()
                monitor.restartUnreadReminderTimer()
            }
        )
    }

}

/// The system prompt is shown only after an explicit user action.
struct NotificationPermissionView: View {
    let notifications: NotificationService
    let enabled: Bool
    var showAuthorizedStatus = false

    @State private var status: UNAuthorizationStatus?
    @State private var requesting = false

    var body: some View {
        Group {
            if enabled {
                switch status {
                case nil:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(.Settings.settingsGeneralNotificationsSection))
                case .notDetermined:
                    permissionPrompt
                case .denied:
                    deniedPrompt
                case .authorized, .provisional, .ephemeral:
                    if showAuthorizedStatus {
                        Label {
                            Text(.Settings.settingsGeneralNotificationsPermissionEnabled)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .task(id: enabled) {
            await refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private var permissionPrompt: some View {
        HStack(spacing: 12) {
            Label {
                Text(.Settings.settingsGeneralNotificationsPermissionPrompt)
                    .font(.callout)
            } icon: {
                Image(systemName: "bell.badge")
            }
            Spacer(minLength: 4)
            Button {
                requesting = true
                Task {
                    await notifications.requestPermission()
                    await refreshStatus()
                    requesting = false
                }
            } label: {
                Text(.Settings.settingsGeneralNotificationsPermissionEnable)
            }
            .disabled(requesting)
        }
    }

    private var deniedPrompt: some View {
        HStack(spacing: 12) {
            Text(.Settings.settingsGeneralNotificationsFooterDenied)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(.Settings.settingsGeneralNotificationsOpenSystemSettings)
            }
        }
    }

    private func refreshStatus() async {
        status = await notifications.currentAuthorizationStatus()
    }
}
