import SwiftUI

struct AutomationPackageStep: View {
    let monitor: TodoMonitorService
    @Binding var assistant: AutomationAssistant?
    @Binding var selection: AutomationPackageChoice?

    private var presetSelection: Binding<AutomationPackageChoice?> {
        Binding(get: { assistant == nil ? .manual : selection }, set: { selection = $0 })
    }

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
                AutomationAssistantPicker(
                    assistant: $assistant, available: monitor.availableAssistants,
                    onRefresh: monitor.refreshAvailableAssistants,
                    statuses: monitor.assistantDependencies.statuses
                )
                VStack(alignment: .leading, spacing: 8) {
                    AutomationPackagePicker(
                        selection: presetSelection, canUseAutomatic: assistant.map(monitor.availableAssistants.contains) == true
                    )
                    if let preset = presetSelection.wrappedValue {
                        AutomationPresetDescription(preset: preset)
                    } else {
                        Text(.Settings.settingsAutomationPackageHelp).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(.Onboarding.onboardingAutomationAlreadyConfigured)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
