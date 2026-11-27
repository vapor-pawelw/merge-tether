import SwiftUI

struct GeneralSettingsTab: View {
    let monitor: TodoMonitorService
    let updates: UpdateService
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin: LaunchAtLoginToggle

    init(monitor: TodoMonitorService, updates: UpdateService, updater: AppUpdater) {
        self.monitor = monitor
        self.updates = updates
        self.updater = updater
        _launchAtLogin = State(initialValue: LaunchAtLoginToggle { enabled in
            monitor.settings.launchAtLoginPreference = enabled
            monitor.settings.save()
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.requestChange($0) }
                )) {
                    Text(.Settings.settingsGeneralStartupLaunchAtLogin)
                }
                if launchAtLogin.lastFailure != nil {
                    Text(.Onboarding.onboardingLaunchAtLoginFailed)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                LabeledContent {
                    Button(.Settings.settingsIntegrationRunSetupAgain) {
                        openWindow(id: "onboarding")
                    }
                } label: {
                    Text(.Onboarding.onboardingWindowTitle)
                }
            }

            Section {
                LabeledContent {
                    Text(verbatim: updates.currentVersion)
                } label: { Text(.AppUpdates.appUpdateCurrentVersion) }

                if updater.isEnabled {
                    Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) })) {
                        Text(.AppUpdates.appUpdateAutomaticallyCheck)
                    }
                    AppUpdateControls(updater: updater)
                } else {
                    Text(updater.isConfigured ? .AppUpdates.appUpdateFailed : .AppUpdates.appUpdateDevelopmentBuild)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.AppUpdates.appUpdateSectionTitle)
            }

            CrashReportingSettingsSection()
        }
        .formStyle(.grouped)
        .task { launchAtLogin.resync() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.resync()
        }
    }
}
