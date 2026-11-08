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

struct MenuBarStatusLabel: View {
    let monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let attention = monitor.userAttention
        let status: LocalizedStringResource = attention.hasAttention
            ? .MenuBar.menuBarAttention(attention.count)
            : .MenuBar.menuBarClear
        Image(nsImage: MenuBarLogo.image(needsAttention: attention.hasAttention))
            .renderingMode(attention.hasAttention ? .original : .template)
            .accessibilityLabel(Text(.MenuBar.menuBarTitle))
            .accessibilityValue(Text(status))
            .help(Text(status))
            .onAppear { MainWindowPresentation.openWindow = { openWindow(id: "main") } }
    }
}

struct MenuBarStatusMenu: View {
    let monitor: TodoMonitorService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: { Text(.MenuBar.menuBarOpen) }
        Divider()
        if monitor.userAttention.hasAttention {
            Text(.MenuBar.menuBarAttention(monitor.userAttention.count))
        } else {
            Text(.MenuBar.menuBarClear)
        }
        Button { Task { await monitor.refreshManually() } } label: { Text(.CommandCenter.commandCenterRefresh) }
            .disabled(monitor.showsGlobalRefreshProgress)
        SettingsLink { Text(.CommandCenter.commandCenterSettings) }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Text(.MenuBar.menuBarQuit) }
    }
}
