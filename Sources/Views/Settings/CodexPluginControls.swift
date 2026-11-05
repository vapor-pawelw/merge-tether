import SwiftUI

struct CodexPluginControls: View {
    @State private var installation: CodexPluginInstaller.Installation?
    @State private var isChecking = true
    @State private var isInstalling = false
    @State private var hasListener = false
    @State private var failure: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.Settings.settingsCodexPluginTitle)
                .font(.subheadline.weight(.semibold))
            if isInstalling {
                ProgressView {
                    Text(.Settings.settingsCodexPluginInstalling)
                }
                .controlSize(.small)
            } else if isChecking {
                ProgressView {
                    Text(.Settings.settingsCodexPluginChecking)
                }
                .controlSize(.small)
            } else {
                Text(failure ?? message)
                    .font(.caption)
                    .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                HStack {
                    if installation == .missing {
                        Button {
                            Task { await install() }
                        } label: {
                            Text(.Settings.settingsCodexPluginInstall)
                        }
                    } else if installation != nil {
                        Button {
                            Task { await openCodex() }
                        } label: {
                            Text(hasListener ? .Settings.settingsCodexPluginOpenListener : .Menu.menuAssistantOpenCodex)
                        }
                    }
                    Button {
                        Task { await detect() }
                    } label: {
                        Text(.Settings.settingsCodexPluginRecheck)
                    }
                }
            }
        }
        .task { await detect() }
    }

    private var message: LocalizedStringResource {
        switch installation {
        case .missing: .Settings.settingsCodexPluginMissing
        case .disabled: .Settings.settingsCodexPluginDisabled
        case .enabled: .Settings.settingsCodexPluginEnabled
        case nil: .Settings.settingsCodexPluginDetectionFailed
        }
    }

    private func detect() async {
        guard !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }
        failure = nil
        hasListener = CodexPluginInstaller.listenerURL() != nil
        do {
            installation = try await CodexPluginInstaller.detect()
        } catch is CancellationError {
            return
        } catch {
            installation = nil
        }
    }

    private func install() async {
        guard !isInstalling, !isChecking else { return }
        isInstalling = true
        defer { isInstalling = false }
        failure = nil
        do {
            installation = try await CodexPluginInstaller.installIfMissing()
        } catch CodexPluginInstaller.InstallationError.missingPython {
            failure = .Settings.settingsCodexPluginPythonRequired
        } catch {
            failure = .Settings.settingsCodexPluginInstallFailed
        }
    }

    private func openCodex() async {
        do {
            try await AssistantAutomationRunner.openCodexListener()
        } catch {
            failure = .Settings.settingsCodexPluginOpenFailed
        }
    }
}
