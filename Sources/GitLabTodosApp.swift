import OSLog
import SwiftUI

@main
enum MergeTetherMain {
    @MainActor static func main() {
        if ApplicationLaunchMode.resolve(environment: ProcessInfo.processInfo.environment) == .testHost {
            let application = NSApplication.shared
            let delegate = MergeTetherTestHostDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.prohibited)
            // NSApplicationMain would load Tuist's default Main storyboard;
            // this host needs only launch notifications and the XCTest event loop.
            withExtendedLifetime(delegate) { application.run() }
            return
        }
        do {
            guard let lock = try SingleInstanceLock.acquire() else { return }
            withExtendedLifetime(lock) { GitLabTodosApp.main() }
        } catch {
            Log.monitor.error("Cannot acquire MergeTether instance lock: \(error.localizedDescription, privacy: .private)")
        }
    }
}

@MainActor
private final class MergeTetherTestHostDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
}

@MainActor
final class GitLabTodosAppDelegate: NSObject, NSApplicationDelegate {
    let monitor = TodoMonitorService()
    let avatarCache = AvatarCache()
    let updates = UpdateService()
    lazy var remote = RemoteHostController(monitor: monitor)
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = remote
        NSApplication.shared.setActivationPolicy(.regular)
        monitor.notifications.onOpenMainWindow = { MainWindowPresentation.show() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        monitor.prepareForTermination()
        Task { @MainActor in
            await AssistantAutomationRunner.waitForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

        Window(Text(.Remote.remoteMacPairPhone), id: "remote-access") {
            RemoteAccessView(remote: appDelegate.remote)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(monitor: appDelegate.monitor)
        }
        .windowResizability(.contentMinSize)

        Window(String(localized: .Onboarding.onboardingWindowTitle), id: "onboarding") {
            OnboardingView(monitor: appDelegate.monitor)
        }
        .windowResizability(.contentSize)

        Window(String(localized: .Menu.whatsNewTitle), id: "whats-new") {
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
