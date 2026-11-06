import SwiftUI

struct AutomationScopeSettingsView: View {
    let monitor: TodoMonitorService
    @State private var history = false

    var body: some View {
        VStack(spacing: 10) {
            Picker(selection: $history) {
                Text(.Menu.menuScopeManaged).tag(false)
                Text(.Menu.menuWorkflowActivityTabShort).tag(true)
            } label: { Text(.Settings.settingsAutomationScopeTitle) }
            .labelsHidden().pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 12)

            if history {
                TabView {
                    MergeWorkflowActivityView(entries: monitor.authoredMergeRequests.workflow.entries)
                        .tabItem { Text(.Menu.menuWorkflowActivityTabShort) }
                    AssistantJobHistoryView(monitor: monitor)
                        .tabItem { Text(.Menu.menuMrHistory) }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(selection: Binding(
                        get: { monitor.settings.automation.scope.mode },
                        set: { monitor.settings.automation.scope.mode = $0; monitor.settings.save() }
                    )) {
                        Text(.Settings.settingsAutomationScopeAll).tag(MRAutomationScope.Mode.all)
                        Text(.Settings.settingsAutomationScopeSelected).tag(MRAutomationScope.Mode.selected)
                    } label: { Text(.Settings.settingsAutomationScopeTitle) }
                    Text(.Settings.settingsAutomationScopeHelp).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                ManagedMergeRequestsView(monitor: monitor)
                Text(.Settings.settingsAutomationScopeImmediate)
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .onAppear {
            monitor.authoredMergeRequests.setVisible(true)
            Task { await monitor.refreshNow() }
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }
}
