import SwiftUI

struct AutomationScopeSettingsView: View {
    let monitor: TodoMonitorService

    var body: some View {
        VStack(spacing: 10) {
            if monitor.settings.automation.hasEnabledAutomation {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(selection: Binding(
                        get: { monitor.settings.automation.scope.mode },
                        set: { monitor.settings.automation.scope.mode = $0; monitor.settings.save() }
                    )) {
                        Text(.Settings.settingsAutomationScopeAll).tag(MRAutomationScope.Mode.all)
                        Text(.Settings.settingsAutomationScopeSelected).tag(MRAutomationScope.Mode.selected)
                    } label: { Text(.Settings.settingsAutomationScopeTitle) }
                    Text(.Settings.settingsAutomationScopeHelp).font(.caption).foregroundStyle(.secondary)
                    Picker(selection: Binding(
                        get: { monitor.settings.boardGrouping },
                        set: { monitor.settings.boardGrouping = $0; monitor.settings.save() }
                    )) {
                        Text(.BoardActivity.withoutAutomationChoice).tag(MRBoardGrouping.withoutAutomation)
                        Text(.BoardActivity.draftsChoice).tag(MRBoardGrouping.drafts)
                    } label: { Text(.BoardActivity.groupingTitle) }
                    Text(.BoardActivity.groupingHelp).font(.caption).foregroundStyle(.secondary)
                    Toggle(isOn: Binding(
                        get: { monitor.settings.automation.scope.pauseDraftsByDefault },
                        set: { monitor.settings.automation.scope.pauseDraftsByDefault = $0; monitor.settings.save() }
                    )) { Text(.Menu.menuScopePauseDrafts) }
                    Text(.Menu.menuScopePauseDraftsHelp).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 12)
            }
            ManagedMergeRequestsView(monitor: monitor)
            if monitor.settings.automation.hasEnabledAutomation {
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
