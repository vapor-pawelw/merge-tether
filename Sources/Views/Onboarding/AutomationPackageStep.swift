import SwiftUI

struct AutomationPackageStep: View {
    let monitor: TodoMonitorService
    @Binding var enabled: Bool
    @Binding var assistant: AutomationAssistant?
    @Binding var selection: AutomationPreset

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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $enabled) { Text(.AutomationProfiles.automationEnabled).font(.headline) }
                        .toggleStyle(.switch)
                    Text(.Onboarding.onboardingAutomationBody).foregroundStyle(.secondary)
                }
                if enabled {
                    AutomationAssistantPicker(
                        assistant: $assistant, available: monitor.availableAssistants,
                        onRefresh: monitor.refreshAvailableAssistants,
                        statuses: monitor.assistantDependencies.statuses
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        AutomationPackagePicker(selection: $selection)
                        AutomationPresetDescription(preset: selection)
                    }
                }
            } else {
                Text(.Onboarding.onboardingAutomationAlreadyConfigured)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
