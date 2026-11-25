import SwiftUI

struct MergeRequestSettingsTab: View {
    let monitor: TodoMonitorService

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { monitor.settings.boardOrderingMethod },
                    set: { monitor.settings.boardOrderingMethod = $0; monitor.settings.save() }
                )) {
                    Text(.BoardActivity.manualOrdering).tag(MRBoardOrderingMethod.manual)
                    Text(.BoardActivity.automaticOrdering).tag(MRBoardOrderingMethod.automatic)
                } label: { Text(.BoardActivity.orderingMethod) }

                if monitor.settings.boardOrderingMethod == .manual {
                    Toggle(isOn: Binding(
                        get: { monitor.settings.promoteBoardAttention },
                        set: { monitor.settings.promoteBoardAttention = $0; monitor.settings.save() }
                    )) { Text(.BoardActivity.promoteAttention) }
                }
            } header: {
                Text(.Board.boardTitle)
            } footer: {
                Text(.MRLifecycle.completionSettingsHelp).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: Binding(
                    get: { monitor.settings.conversationDestination },
                    set: { monitor.settings.conversationDestination = $0; monitor.settings.save() }
                )) {
                    ForEach(AssistantContextLauncher.Destination.allCases) { destination in
                        Text(destination.label).tag(destination)
                    }
                } label: { Text(.AssistantContext.assistantContextDefault) }
            } header: {
                Text(.AssistantContext.assistantContextSettingsTitle)
            } footer: {
                Text(.AssistantContext.assistantContextSettingsHelp)
            }

            IncomingReviewFilterSettingsSection(monitor: monitor)

            Section {
                hiddenReviews
            }
        }
        .formStyle(.grouped)
    }

    private var hiddenReviews: some View {
        let requests = monitor.hiddenReviewAssignments
        return DisclosureGroup {
            if requests.isEmpty {
                Text(.Settings.settingsHiddenReviewsEmpty).foregroundStyle(.secondary)
            }
            ForEach(requests) { request in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.title)
                        Text(verbatim: "\(request.url.gitLabProjectPath) !\(request.target.iid ?? 0)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(.Board.boardReviewAssignmentRestore) {
                        monitor.restoreReviewedMergeRequests([request])
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        } label: {
            HStack {
                Text(.Settings.settingsHiddenReviewsTitle)
                if !requests.isEmpty {
                    Text(requests.count, format: .number).foregroundStyle(.secondary)
                }
            }
        }
    }
}
