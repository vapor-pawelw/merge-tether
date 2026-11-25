import AppKit
import SwiftUI

struct AssistantSetupView: View {
    @State private var setup: AssistantSetupSession
    @State private var operation: Task<Void, Never>?
    @State private var loginFailed = false
    @Environment(\.dismiss) private var dismiss
    let onReady: () -> Void

    init(assistant: AutomationAssistant, onReady: @escaping () -> Void) {
        _setup = State(initialValue: AssistantSetupSession(assistant: assistant))
        self.onReady = onReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Settings.settingsAssistantSetupTitle(String(localized: setup.assistant.displayName)))
                .font(.headline)
            Text(.Settings.settingsAssistantSetupBody).foregroundStyle(.secondary)
            if setup.isWorking {
                HStack { ProgressView().controlSize(.small); Text(.Settings.settingsAssistantSetupChecking) }
            } else if let status = setup.status {
                Text(status.message(for: setup.assistant)).foregroundStyle(status.isReady ? .green : .orange)
                switch status {
                case .missingCLI, .invalidCLI:
                    Text(.Settings.settingsAssistantSetupInstallHelp).font(.caption).foregroundStyle(.secondary)
                    Link(destination: AssistantCLI.installationGuide(for: setup.assistant)) {
                        Text(.Settings.settingsAssistantSetupInstall)
                    }
                case .loginRequired(let executable):
                    Button {
                        Task {
                            do { try await AssistantCLI.openLogin(setup.assistant, executable: executable) }
                            catch { loginFailed = true }
                        }
                    } label: { Text(.Settings.settingsAssistantSetupSignIn) }
                    Text(.Settings.settingsAssistantSetupSignInHelp).font(.caption).foregroundStyle(.secondary)
                case .ready: EmptyView()
                }
            }
            if loginFailed {
                Text(.Settings.settingsAssistantSetupFailed).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(role: .cancel) {
                    operation?.cancel()
                    setup.cancel()
                    dismiss()
                } label: { Text(.Settings.settingsAssistantSetupCancel) }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button { perform() } label: { Text(.Settings.settingsAssistantSetupRecheck) }
                    .disabled(setup.isWorking)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(setup.isWorking)
        .onAppear { perform() }
        .onDisappear { operation?.cancel(); setup.cancel() }
    }

    private func perform() {
        operation?.cancel()
        operation = Task {
            let ready = await setup.verify()
            guard ready, setup.canCommit, !Task.isCancelled else { return }
            onReady()
            dismiss()
        }
    }
}

extension AssistantDependencyStatus {
    func message(for assistant: AutomationAssistant) -> LocalizedStringResource {
        let name = String(localized: assistant.displayName)
        switch self {
        case .ready: return .Settings.settingsAssistantStatusReady(name)
        case .missingCLI: return .Settings.settingsAssistantStatusCli(name)
        case .invalidCLI: return .Settings.settingsAssistantStatusInvalid(name)
        case .loginRequired: return .Settings.settingsAssistantStatusLogin(name)
        }
    }
}
