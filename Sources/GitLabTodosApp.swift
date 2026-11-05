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
    private var statusItemController: MenuBarStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = MenuBarStatusItemController(
            monitor: monitor,
            updates: updates,
            avatarCache: avatarCache
        )
    }
}

struct GitLabTodosApp: App {
    @NSApplicationDelegateAdaptor(GitLabTodosAppDelegate.self) private var appDelegate

    var body: some Scene {
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
