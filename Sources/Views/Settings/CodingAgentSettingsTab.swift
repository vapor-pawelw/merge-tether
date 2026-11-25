import SwiftUI

struct CodingAgentSettingsTab: View {
    let monitor: TodoMonitorService

    var body: some View {
        Form {
            Section {
                AutomationAssistantPicker(
                    assistant: Binding(
                        get: { monitor.settings.automation.selectedAssistant },
                        set: { assistant in
                            monitor.settings.automation.selectedAssistant = assistant
                            let saved = monitor.applySettings()
                            if saved, let assistant {
                                if let hold = monitor.cliHealth.hold(for: assistant), hold.issue.kind == .loginRequired {
                                    _ = monitor.cliHealth.clear(assistant, expectedID: hold.id)
                                }
                                SettingsNavigation.shared.codingAgentConfigured()
                            }
                        }),
                    available: monitor.availableAssistants,
                    onRefresh: monitor.refreshAvailableAssistants,
                    statuses: monitor.assistantDependencies.statuses
                )
                PersistenceDegradedBanner(settings: monitor.settings)
            } footer: {
                Text(.Settings.settingsAssistantUseHelp)
            }

            Section {
                AssistantUsageSettingsContent()
            }
        }
        .formStyle(.grouped)
    }
}
