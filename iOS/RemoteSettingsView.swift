import SwiftUI

enum RemoteSettingsRoute: Hashable, Identifiable {
    case general, crashReporting

    var id: Self { self }
}

enum RemoteSettingsAction {
    case pair, regenerateDrafts
}

struct RemoteSettingsView: View {
    let model: RemotePhoneModel
    let route: RemoteSettingsRoute
    let onAction: (RemoteSettingsAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var now = Date.now

    var body: some View {
        NavigationStack {
            Form {
                if route == .general {
                    connectionSection
                    relaySection
                    draftRegenerationSection
                }
                CrashReportingSettingsSection()
            }
            .navigationTitle(Text(.CrashReporting.crashReportingSettings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.Remote.remoteClose) { dismiss() }
                }
            }
        }
        .presentationDetents(route == .crashReporting && !dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .task {
            guard route == .general else { return }
            while !Task.isCancelled {
                now = .now
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var connectionSection: some View {
        let status = model.connectionStatus(now: now)
        return Section {
            Label(status.title, systemImage: status.symbol)
                .foregroundStyle(status == .connected ? Color.green : Color.secondary)
                .accessibilityIdentifier("remote.settings.status")

            if model.paired {
                Button { model.reconnect() } label: {
                    Label(.Remote.remoteReconnect, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(status == .connecting)
                .accessibilityIdentifier("remote.reconnect")
            }
            if model.relayConfiguration.origin != nil {
                Button { perform(.pair) } label: {
                    Label(model.paired ? .Remote.remoteReplace : .Remote.remotePair, systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("remote.settings.pair")
            }
        } header: {
            Text(.Remote.remoteConnectionMenu)
        }
    }

    private var relaySection: some View {
        Section {
            if let origin = model.relayConfiguration.origin {
                Text(verbatim: origin.absoluteString)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("remote.settings.relay")
            } else {
                Text(model.relayConfiguration.status == .missing ? .Remote.remoteRelayMissing : .Remote.remoteRelayInvalid)
                    .foregroundStyle(Color.secondary)
            }
        } header: {
            Text(.Remote.remoteRelayAddress)
        } footer: {
            if model.relayConfiguration.origin != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(.Remote.remoteRelayConfigured)
                    Text(.Remote.remoteRelayOwnership)
                }
            }
        }
    }

    @ViewBuilder private var draftRegenerationSection: some View {
        if model.supportsDraftRegeneration, model.draftRegenerationBatch == nil,
           model.draftRegenerationCount(for: .all) > 0 {
            Section {
                Button { perform(.regenerateDrafts) } label: {
                    Label { Text(.DraftRegeneration.draftRegenerationAllAction) } icon: { CodingProviderIcon() }
                }
                .disabled(!model.draftRegenerationIsAvailable || !model.state.canAct(now: now))
                .accessibilityIdentifier("draft-regeneration.all")
            }
        }
    }

    private func perform(_ action: RemoteSettingsAction) {
        onAction(action)
        dismiss()
    }
}
