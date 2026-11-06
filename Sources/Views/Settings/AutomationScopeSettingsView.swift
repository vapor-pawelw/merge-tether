import SwiftUI

struct AutomationScopeSettingsView: View {
    let monitor: TodoMonitorService

    var body: some View {
        VStack(spacing: 10) {
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
            .padding(.horizontal, 20).padding(.top, 12)
            ManagedMergeRequestsView(monitor: monitor)
            Text(.Settings.settingsAutomationScopeImmediate)
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
        }
        .onAppear {
            monitor.authoredMergeRequests.setVisible(true)
            Task { await monitor.refreshNow() }
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }
}
