import SwiftUI
import Observation

@MainActor @Observable
final class SettingsNavigation {
    enum Tab: Hashable { case general, integration, automation, usage }
    static let shared = SettingsNavigation()
    var selection: Tab = .general
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    @ObservationIgnored private var onCodingAgentConfigured: (() -> Void)?

    func showCodingAgent(openSettings: (() -> Void)? = nil, onConfigured: (() -> Void)? = nil) {
        selection = .general
        onCodingAgentConfigured = onConfigured
        (openSettings ?? openSettingsWindow)?()
    }

    func codingAgentConfigured() {
        let resume = onCodingAgentConfigured
        onCodingAgentConfigured = nil
        resume?()
    }

    func showIntegration(openSettings: () -> Void) {
        selection = .integration
        openSettings()
    }

    func perform(_ action: MREffectivePolicyPresentation.SettingsAction, openSettings: () -> Void) {
        switch action {
        case .chooseAutomationSettings: selection = .automation
        case .chooseCodingAgent: selection = .general
        }
        openSettings()
    }
}

struct SettingsView: View {
    @Bindable var monitor: TodoMonitorService
    @Bindable private var navigation = SettingsNavigation.shared

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
    }

    var body: some View {
        TabView(selection: $navigation.selection) {
            GeneralSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsGeneralTab)
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                .tag(SettingsNavigation.Tab.general)

            IntegrationSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsIntegrationTab)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                }
                .tag(SettingsNavigation.Tab.integration)

            AutomationSettingsTab(monitor: monitor)
                .tabItem {
                    Label {
                        Text(.Settings.settingsAutomationTab)
                    } icon: {
                        Image(systemName: "bolt.circle")
                    }
                }
                .tag(SettingsNavigation.Tab.automation)

            AssistantUsageSettingsTab()
                .tabItem {
                    Label {
                        Text(.AssistantUsage.assistantUsageTab)
                    } icon: {
                        Image(systemName: "chart.bar")
                    }
                }
                .tag(SettingsNavigation.Tab.usage)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 560, idealHeight: 680)
    }
}
