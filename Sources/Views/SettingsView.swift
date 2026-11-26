import AppKit
import Observation
import SwiftUI

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
            case .automation: "play.fill"
            }
        }
    }
    static let shared = SettingsNavigation()
    var selection: Tab = .general
    var agentPage: CodingAgentSettingsTab.Page = .settings
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    @ObservationIgnored private var onCodingAgentConfigured: (() -> Void)?

    func showCodingAgent(openSettings: (() -> Void)? = nil, onConfigured: (() -> Void)? = nil) {
        selection = .codingAgent
        agentPage = .settings
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
        case .chooseCodingAgent:
            selection = .codingAgent
            agentPage = .settings
        }
        openSettings()
    }
}

struct SettingsView: View {
    @Bindable var monitor: TodoMonitorService
    let updates: UpdateService
    let updater: AppUpdater
    @State private var editor: SettingsPolicyEditor
    @Bindable private var navigation = SettingsNavigation.shared

    init(monitor: TodoMonitorService, updates: UpdateService, updater: AppUpdater) {
        self.monitor = monitor
        self.updates = updates
        self.updater = updater
        _editor = State(initialValue: SettingsPolicyEditor(settings: monitor.settings))
    }

    var body: some View {
        TabView(selection: $navigation.selection) {
            ForEach(SettingsNavigation.Tab.allCases, id: \.self) { tab in
                page(tab)
                    .tabItem { Label { Text(tab.title) } icon: { tabIcon(tab) } }
                    .tag(tab)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .onChange(of: monitor.settings.automation.scope) { editor.updateScope(from: monitor.settings) }
        .onChange(of: monitor.settings.acceptedAutomation.selectedAssistant, initial: true) { editor.updateAssistant(from: monitor.settings) }
    }

    private func tabIcon(_ tab: SettingsNavigation.Tab) -> Image {
        guard tab == .codingAgent, let provider = monitor.settings.automation.selectedAssistant?.glyph,
              let glyph = NSImage(named: .init(provider.assetName)) else {
            return Image(systemName: tab.symbol)
        }
        // The native toolbar scales custom images to its icon slot.
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
            glyph.draw(in: bounds.insetBy(dx: 6, dy: 6))
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image)
    }

    @ViewBuilder
    private func page(_ tab: SettingsNavigation.Tab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(monitor: monitor, updates: updates, updater: updater)
        case .integration: IntegrationSettingsTab(monitor: monitor)
        case .mergeRequests: MergeRequestSettingsTab(monitor: monitor)
        case .notifications: NotificationsSettingsTab(monitor: monitor)
        case .codingAgent: CodingAgentSettingsTab(monitor: monitor, editor: editor, page: $navigation.agentPage)
        case .automation: AutomationSettingsTab(monitor: monitor, editor: editor)
        }
    }
}
