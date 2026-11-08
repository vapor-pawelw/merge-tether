import SwiftUI

struct SettingsView: View {
    @Bindable var monitor: TodoMonitorService

    var body: some View {
        TabView {
            GeneralSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsGeneralTab)
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }

            IntegrationSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsIntegrationTab)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                }

            AutomationSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsAutomationTab)
                    } icon: {
                        Image(systemName: "bolt.circle")
                    }
                }

            AssistantUsageSettingsTab()
                .tabItem {
                    Label {
                        Text(.AssistantUsage.assistantUsageTab)
                    } icon: {
                        Image(systemName: "chart.bar")
                    }
                }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 560, idealHeight: 680)
    }
}
