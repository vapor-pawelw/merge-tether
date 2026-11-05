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
                    AssistantDeliveryHistoryView(monitor: monitor)
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

private struct AssistantDeliveryHistoryView: View {
    let monitor: TodoMonitorService
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(monitor.assistantGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: group.title).font(.subheadline.weight(.semibold))
                        if let url = group.chatURL, let handoff = group.chatHandoff {
                            Link(destination: url) {
                                Text(handoff.key.assistant == .codex ? .Menu.menuMrChatCodex : .Menu.menuMrChatClaude)
                            }
                        }
                        DisclosureGroup {
                            ForEach(group.handoffs) { handoff in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: handoff.title)
                                    Text(handoff.relayComplete == true ? .Menu.menuMrDelivered : .Menu.menuMrPendingEvents(1))
                                        .foregroundStyle(.secondary)
                                    Text(RelativeTime.string(from: handoff.createdAt)).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        } label: { Text(.Menu.menuMrHistory) }
                    }
                    .font(.caption).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding()
        }
    }
}
