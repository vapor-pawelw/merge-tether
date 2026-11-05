import SwiftUI

/// Install status for MergeTether's Claude Code plugin, which gives Claude sessions the
/// relay tools: linking a session to its MR, reading the MR and recording review verdicts.
struct ClaudePluginControls: View {
    @State private var installation: ClaudePluginInstaller.Installation?
    @State private var isChecking = true
    @State private var isInstalling = false
    @State private var failure: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isInstalling {
                ProgressView { Text(.Settings.settingsClaudePluginInstalling) }.controlSize(.small)
            } else if isChecking {
                ProgressView { Text(.Settings.settingsCodexPluginChecking) }.controlSize(.small)
            } else {
                Label {
                    Text(failure ?? message)
                } icon: {
                    Image(systemName: installation == .enabled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .foregroundStyle(installation == .enabled ? Color.green : Color.secondary)
                }
                .font(.caption)
                .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                HStack {
                    if installation == .missing {
                        Button { Task { await install() } } label: { Text(.Settings.settingsClaudePluginInstall) }
                    }
                    Button { Task { await detect() } } label: { Text(.Settings.settingsCodexPluginRecheck) }
                }
            }
        }
        .task { await detect() }
    }

    private var message: LocalizedStringResource {
        switch installation {
        case .missing: .Settings.settingsClaudePluginMissing
        case .disabled: .Settings.settingsClaudePluginDisabled
        case .enabled: .Settings.settingsClaudePluginEnabled
        case nil: .Settings.settingsClaudePluginUnavailable
        }
    }

    private func detect() async {
        guard !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }
        failure = nil
        installation = try? await ClaudePluginInstaller.detect()
    }

    private func install() async {
        guard !isInstalling, !isChecking else { return }
        isInstalling = true
        defer { isInstalling = false }
        failure = nil
        do {
            installation = try await ClaudePluginInstaller.installIfMissing()
        } catch CodexPluginInstaller.InstallationError.missingPython {
            failure = .Settings.settingsCodexPluginPythonRequired
        } catch {
            failure = .Settings.settingsClaudePluginInstallFailed
        }
    }
}
