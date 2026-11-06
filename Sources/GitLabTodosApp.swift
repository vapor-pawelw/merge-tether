import OSLog
import SwiftUI

@main
enum MergeTetherMain {
    @MainActor static func main() {
        do {
            guard let lock = try SingleInstanceLock.acquire() else { return }
            withExtendedLifetime(lock) { GitLabTodosApp.main() }
        } catch {
            Log.monitor.error("Cannot acquire MergeTether instance lock: \(error.localizedDescription, privacy: .private)")
        }
    }
}

@MainActor
final class GitLabTodosAppDelegate: NSObject, NSApplicationDelegate {
    let monitor = TodoMonitorService()
    let avatarCache = AvatarCache()
    let updates = UpdateService()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        monitor.notifications.onOpenMainWindow = { MainWindowPresentation.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.prepareForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresentation.show()
        return false
    }
}

struct GitLabTodosApp: App {
    @NSApplicationDelegateAdaptor(GitLabTodosAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(String(localized: .CommandCenter.commandCenterTitle), id: "main") {
            CommandCenterView(monitor: appDelegate.monitor, updates: appDelegate.updates)
                .environment(\.avatarCache, appDelegate.avatarCache)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenMainWindowButton()
            }
        }

        MenuBarExtra {
            MenuBarStatusMenu(monitor: appDelegate.monitor)
        } label: {
            MenuBarStatusLabel(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(monitor: appDelegate.monitor)
        }
        .windowResizability(.contentMinSize)

        Window("Setup", id: "onboarding") {
            OnboardingView(monitor: appDelegate.monitor)
        }
        .windowResizability(.contentSize)

        Window("What's New", id: "whats-new") {
            WhatsNewView(updates: appDelegate.updates)
        }
        .windowResizability(.contentSize)
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "main") } label: { Text(.CommandCenter.commandCenterTitle) }
            .keyboardShortcut("0", modifiers: .command)
    }
}
