import AppKit
import SwiftUI

@MainActor
enum MainWindowPresentation {
    static var openWindow: (@MainActor @Sendable () -> Void)?

    static func show() {
        openWindow?()
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private extension GitLabMenuBarStatus {
    func title(attention: UserAttentionSnapshot) -> LocalizedStringResource {
        switch self {
        case .setup: .MenuBar.menuBarSetupRequired
        case .signedOut: .GitLabConnection.signInTitle
        case .hostConfiguration: .GitLabConnection.hostTitle
        case .syncing: .MenuBar.menuBarSyncing
        case .failed: .MenuBar.menuBarSyncFailed
        case .current: attention.hasAttention ? .MenuBar.menuBarAttention(attention.count) : .MenuBar.menuBarClear
        }
    }
}

struct MenuBarStatusLabel: View {
    let monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let attention = monitor.userAttention
        let health = monitor.menuBarGitLabStatus
        let status = health.title(attention: attention)
        Group {
            if health.hasWarning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(nsImage: MenuBarLogo.image(needsAttention: attention.hasAttention))
                    .renderingMode(attention.hasAttention ? .original : .template)
            }
        }
        .accessibilityLabel(Text(.MenuBar.menuBarTitle))
        .accessibilityValue(Text(status))
        .help(Text(status))
        .onAppear { MainWindowPresentation.openWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarStatusMenu: View {
    let monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let attention = monitor.userAttention
        let health = monitor.menuBarGitLabStatus
        Button {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: { Text(.MenuBar.menuBarOpen) }
        Divider()
        Text(health.title(attention: attention))
        if health != .current && attention.hasAttention {
            Text(.MenuBar.menuBarAttention(attention.count))
        }
        switch health {
        case .setup, .signedOut:
            Button {
                openWindow(id: "onboarding")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Text(health == .setup ? .GitLabConnection.setup : .GitLabConnection.signIn)
            }
        case .hostConfiguration:
            Button { SettingsNavigation.shared.showIntegration { openSettings() } } label: {
                Text(.GitLabConnection.integrationSettings)
            }
        case .syncing, .failed, .current:
            Button { Task { await monitor.refreshManually() } } label: {
                Text(.CommandCenter.commandCenterRefresh)
            }
            .disabled(monitor.showsGlobalRefreshProgress)
        }
        SettingsLink { Text(.CommandCenter.commandCenterSettings) }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Text(.MenuBar.menuBarQuit) }
    }
}
