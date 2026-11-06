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

    private var status: LocalizedStringResource {
        monitor.userAttention.hasAttention
            ? .MenuBar.menuBarAttention(monitor.userAttention.count)
            : .MenuBar.menuBarClear
    }

    var body: some View {
        Image(nsImage: MenuBarLogo.image(needsAttention: monitor.userAttention.hasAttention))
            .renderingMode(monitor.userAttention.hasAttention ? .original : .template)
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
        Button { Task { await monitor.refreshNow() } } label: { Text(.CommandCenter.commandCenterRefresh) }
            .disabled(monitor.isLoading)
        SettingsLink { Text(.CommandCenter.commandCenterSettings) }
        Divider()
        Button { NSApplication.shared.terminate(nil) } label: { Text(.MenuBar.menuBarQuit) }
    }
}
