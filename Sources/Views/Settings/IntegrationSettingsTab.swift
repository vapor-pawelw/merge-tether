import SwiftUI

struct IntegrationSettingsTab: View {
    @Bindable var monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow

    @State private var isRechecking = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    glabPathValue
                } label: {
                    Text(.Settings.settingsIntegrationGlabPathRow)
                }

                LabeledContent {
                    hostValue
                } label: {
                    Text(.Settings.settingsIntegrationHostRow)
                }

                LabeledContent {
                    authValue
                } label: {
                    Text(.Settings.settingsIntegrationAuthRow)
                }

                HStack {
                    Button {
                        isRechecking = true
                        Task {
                            await monitor.recheckIntegration()
                            isRechecking = false
                        }
                    } label: {
                        Text(.Settings.settingsIntegrationRecheck)
                    }
                    .disabled(isRechecking)

                    Button {
                        openWindow(id: "onboarding")
                    } label: {
                        Text(.Settings.settingsIntegrationRunSetupAgain)
                    }
                }
            } header: {
                Text(.Settings.settingsIntegrationGlabSection)
            } footer: {
                Text(.Settings.settingsIntegrationFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var glabPathValue: some View {
        if let path = monitor.glab.glabPath?.path {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text(.Settings.settingsIntegrationGlabNotFound)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var hostValue: some View {
        if let host = monitor.glab.resolvedHost, !host.isEmpty {
            Text(host)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text(.Settings.settingsIntegrationHostUnresolved)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var authValue: some View {
        switch monitor.glab.authStatus {
        case .authenticated:
            Text(.Settings.settingsIntegrationAuthAuthenticated(monitor.glab.currentUsername ?? ""))
                .foregroundStyle(.secondary)
        case .wrongDefaultHost(let hosts):
            Text(.Settings.settingsIntegrationAuthWrongHost(hosts.map(\.host).joined(separator: ", ")))
                .foregroundStyle(.orange)
        case .notAuthenticated:
            Text(.Settings.settingsIntegrationAuthNotAuthenticated)
                .foregroundStyle(.red)
        case .unknown:
            Text(.Settings.settingsIntegrationAuthUnverified)
                .foregroundStyle(.secondary)
        }
    }
}
