import SwiftUI

struct AutomationPackageStep: View {
    let monitor: TodoMonitorService
    @Binding var assistant: AutomationAssistant
    @Binding var selection: AutomationPackageChoice?
    @Binding var enableCodexRelay: Bool

    var body: some View {
        ScrollView {
            fields.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Onboarding.onboardingAutomationTitle)
                .font(.title3.weight(.semibold))

            if monitor.settings.automation.packageDecision == .undecided {
                Text(.Onboarding.onboardingAutomationBody)
                    .foregroundStyle(.secondary)
                Text(.Settings.settingsAutomationPackageHelp)
                    .foregroundStyle(.secondary)
                AutomationAssistantPicker(
                    assistant: $assistant, available: monitor.availableAssistants,
                    onRefresh: monitor.refreshAvailableAssistants
                )
                AutomationPackagePicker(
                    selection: $selection, canUseRecommended: monitor.availableAssistants.contains(assistant)
                )
                if selection == .recommended, assistant == .codex, monitor.availableAssistants.contains(.codex) {
                    CodexPluginControls()
                    Toggle(isOn: $enableCodexRelay) {
                        Text(.Settings.settingsAutomationCodexRelay)
                    }
                    .toggleStyle(.checkbox)
                }
            } else {
                Text(.Onboarding.onboardingAutomationAlreadyConfigured)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
