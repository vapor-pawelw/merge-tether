import SwiftUI

struct MergeRequestSettingsTab: View {
    let monitor: TodoMonitorService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { monitor.settings.treatAssignedMergeRequestsAsOwn },
                    set: { monitor.setTreatAssignedMergeRequestsAsOwn($0) }
                )) { Text(.Settings.settingsAssignedOwnershipToggle) }
            } footer: {
                Text(.Settings.settingsAssignedOwnershipHelp)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { monitor.settings.addNewReviewsToReviewed },
                    set: { enabled in
                        monitor.settings.addNewReviewsToReviewed = enabled
                        monitor.settings.save()
                    })) {
                    Text(.Settings.settingsGeneralNewReviewsToggle)
                }
            } header: {
                Text(.Settings.settingsGeneralNewReviewsSection)
            } footer: {
                Text(.Settings.settingsGeneralNewReviewsHelp)
            }

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
                Toggle(isOn: Binding(
                    get: { monitor.settings.findMergeRequestIssues },
                    set: { monitor.setMergeRequestIssueDiscovery($0) }
                )) { Text(.MRIssues.mrIssuesDiscoveryToggle) }
            } footer: {
                Text(.MRIssues.mrIssuesDiscoveryHelp)
            }

            IncomingReviewFilterSettingsSection(monitor: monitor)
        }
        .formStyle(.grouped)
    }
}
