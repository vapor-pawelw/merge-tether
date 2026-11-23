import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsTab: View {
    let monitor: TodoMonitorService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { monitor.settings.notificationsEnabled },
                    set: { monitor.settings.notificationsEnabled = $0; monitor.settings.save() }
                )) {
                    Text(.Settings.settingsGeneralNotificationsToggle)
                }

                NotificationPermissionView(
                    notifications: monitor.notifications,
                    enabled: monitor.settings.notificationsEnabled
                )
            } header: {
                Text(.Settings.settingsGeneralNotificationsSection)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { monitor.settings.autoHandledEventBannersEnabled },
                    set: { monitor.settings.autoHandledEventBannersEnabled = $0; monitor.settings.save() }
                )) {
                    Text(.MRLifecycleBanners.mrLifecycleBannersEnabled)
                }
            } header: {
                Text(.MRLifecycleBanners.mrLifecycleBannersSection)
            } footer: {
                Text(.MRLifecycleBanners.mrLifecycleBannersHelp)
            }
        }
        .formStyle(.grouped)
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
