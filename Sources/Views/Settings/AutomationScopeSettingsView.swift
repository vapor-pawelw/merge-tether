import SwiftUI

struct AutomationScopeSettingsView: View {
    let monitor: TodoMonitorService
    @State private var confirmingDraftAutomation = false

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(.Settings.settingsAutomationScopeImmediate)
                    .font(.caption).foregroundStyle(.secondary)
                Picker(selection: Binding(
                    get: { monitor.settings.automation.scope.mode },
                    set: { mode in
                        monitor.settings.automation.scope.mode = mode
                        monitor.settings.save()
                    }
                )) {
                    Text(.Settings.settingsAutomationScopeAll).tag(MRAutomationScope.Mode.all)
                    Text(.Settings.settingsAutomationScopeSelected).tag(MRAutomationScope.Mode.selected)
                } label: { Text(.Settings.settingsAutomationScopeTitle) }
                Text(.Settings.settingsAutomationScopeHelp).font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { monitor.settings.automation.scope.pauseDraftsByDefault },
                    set: { paused in
                        if paused {
                            monitor.settings.automation.scope.pauseDraftsByDefault = true
                            monitor.settings.save()
                        } else {
                            confirmingDraftAutomation = true
                            Task {
                                defer { confirmingDraftAutomation = false }
                                guard confirmDraftAutomation(message: .Menu.menuScopeDraftConfirmationGlobalMessage) else { return }
                                monitor.settings.automation.scope.pauseDraftsByDefault = false
                                monitor.settings.save()
                            }
                        }
                    }
                )) { Text(.Menu.menuScopePauseDrafts) }
                .toggleStyle(.checkbox)
                .disabled(confirmingDraftAutomation)
                Text(.Menu.menuScopePauseDraftsHelp).font(.caption).foregroundStyle(.secondary)
                if monitor.settings.configuredAutomation.hasEnabledAutomation,
                   monitor.settings.boardOrderingMethod == .automatic {
                    Divider()
                    Picker(selection: Binding(
                        get: { monitor.settings.boardGrouping },
                        set: { grouping in
                            monitor.settings.boardGrouping = grouping
                            monitor.settings.save()
                        }
                    )) {
                        Text(.BoardActivity.withoutAutomationChoice).tag(MRBoardGrouping.withoutAutomation)
                        Text(.BoardActivity.draftsChoice).tag(MRBoardGrouping.drafts)
                    } label: { Text(.BoardActivity.groupingTitle) }
                    Text(.BoardActivity.groupingHelp).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)
            Divider()
            ManagedMergeRequestsView(monitor: monitor)
        }
        .onAppear {
            monitor.authoredMergeRequests.setVisible(true)
            Task { await monitor.refreshNow() }
        }
        .onDisappear { monitor.authoredMergeRequests.setVisible(false) }
    }
}
