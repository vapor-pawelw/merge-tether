import SwiftUI

struct AutomationPackageStep: View {
    let monitor: TodoMonitorService
    @Binding var assistant: AutomationAssistant
    @Binding var selection: AutomationPackageChoice?

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
                    onRefresh: monitor.refreshAvailableAssistants, requireCLI: true,
                    statuses: monitor.assistantDependencies.statuses
                )
                AutomationPackagePicker(
                    selection: $selection, canUseRecommended: monitor.availableAssistants.contains(assistant)
                )

            } else {
                Text(.Onboarding.onboardingAutomationAlreadyConfigured)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
