import SwiftUI

struct LaunchAtLoginStep: View {
    let monitor: TodoMonitorService

    @State private var enabled: Bool = LaunchAtLoginService.isEnabled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Onboarding.onboardingLaunchAtLoginTitle)
                .font(.title3.weight(.semibold))

            Text(.Onboarding.onboardingLaunchAtLoginBody)
                .foregroundStyle(.secondary)

            Toggle(isOn: toggleBinding) {
                Text(.Onboarding.onboardingLaunchAtLoginToggle)
            }
            .toggleStyle(.switch)

            if let errorMessage {
                Text(.Onboarding.onboardingLaunchAtLoginFailed)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(Text(verbatim: errorMessage))
            }
        }
        .task {
            enabled = LaunchAtLoginService.isEnabled
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                do {
                    try LaunchAtLoginService.setEnabled(newValue)
                    enabled = newValue
                    errorMessage = nil
                    monitor.settings.launchAtLoginPreference = newValue
                    monitor.settings.save()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }
}
