import SwiftUI
import Observation

@MainActor @Observable
final class SettingsNavigation {
    enum Tab: CaseIterable, Hashable {
        case general, codingAgent, automation, integration, mergeRequests, notifications

        var title: LocalizedStringResource {
            switch self {
            case .general: .Settings.settingsGeneralTab
            case .integration: .Settings.settingsIntegrationTab
            case .mergeRequests: .Settings.settingsMergeRequestsTab
            case .notifications: .Settings.settingsNotificationsTab
            case .codingAgent: .Settings.settingsCodingAgentTab
            case .automation: .Settings.settingsAutomationTab
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .integration: "terminal"
            case .mergeRequests: "arrow.triangle.pull"
            case .notifications: "bell"
            case .codingAgent: "sparkles"
            case .automation: "bolt.circle"
            }
        }
    }
    static let shared = SettingsNavigation()
    var selection: Tab = .general
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    @ObservationIgnored private var onCodingAgentConfigured: (() -> Void)?

    func showCodingAgent(openSettings: (() -> Void)? = nil, onConfigured: (() -> Void)? = nil) {
        selection = .codingAgent
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
        case .chooseCodingAgent: selection = .codingAgent
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
            ForEach(SettingsNavigation.Tab.allCases, id: \.self) { tab in
                page(tab)
                    .tabItem { Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) } }
                    .tag(tab)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
    }

    @ViewBuilder
    private func page(_ tab: SettingsNavigation.Tab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(monitor: monitor)
        case .integration: IntegrationSettingsTab(monitor: monitor)
        case .mergeRequests: MergeRequestSettingsTab(monitor: monitor)
        case .notifications: NotificationsSettingsTab(monitor: monitor)
        case .codingAgent: CodingAgentSettingsTab(monitor: monitor)
        case .automation: AutomationSettingsTab(monitor: monitor)
        }
    }
}
