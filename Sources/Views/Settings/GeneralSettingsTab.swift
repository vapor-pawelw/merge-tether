import SwiftUI

struct GeneralSettingsTab: View {
    let monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow
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

                LabeledContent {
                    Button(.Settings.settingsIntegrationRunSetupAgain) {
                        openWindow(id: "onboarding")
                    }
                } label: {
                    Text(.Onboarding.onboardingWindowTitle)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }
}
