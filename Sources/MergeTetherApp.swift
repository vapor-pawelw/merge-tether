import OSLog
import SwiftUI

@main
enum MergeTetherMain {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--review-mcp"] {
            ReviewToolClient.serve()
            return
        }
        if arguments.first == "--review-cli" {
            let reply = ReviewToolClient.call(Array(arguments.dropFirst()))
            let stream = reply.failed ? FileHandle.standardError : .standardOutput
            stream.write(Data((reply.text + "\n").utf8))
            exit(reply.failed ? 1 : 0)
        }
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
            withExtendedLifetime(lock) {
                CrashReporting.shared.startIfAllowed()
                do { try InstallationStorage.current.moveAutomationEvidence() }
                catch {
                    Log.monitor.error("Cannot move automation evidence: \(error.localizedDescription, privacy: .private)")
                    let alert = NSAlert(error: error)
                    alert.messageText = String(localized: .AutomationRuntime.runtimeEvidenceMigrationFailed)
                    NSApplication.shared.activate()
                    alert.runModal()
                    return
                }
                MergeTetherApp.main()
            }
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
final class MergeTetherAppDelegate: NSObject, NSApplicationDelegate {
    let monitor = TodoMonitorService()
    let avatarCache = AvatarCache()
    let updates = UpdateService()
    let updater = AppUpdater()
    lazy var remote = RemoteHostController(monitor: monitor)
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = remote
        NSApplication.shared.setActivationPolicy(.regular)
        monitor.notifications.onOpenMainWindow = { MainWindowPresentation.show() }
        updater.start { [weak self] in self?.monitor.hasActiveWorkForUpdate ?? false }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        if updater.presentation.phase == .restarting, monitor.hasActiveWorkForUpdate {
            Task { @MainActor in
                // Sparkle requests termination asynchronously. Let work admitted in the meantime finish as well.
                while monitor.hasActiveWorkForUpdate { try? await Task.sleep(for: .seconds(1)) }
                finishTermination(sender)
            }
        } else {
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        let draftRegeneration = monitor.draftRegeneration.prepareForTermination()
        monitor.prepareForTermination()
        Task { @MainActor in
            await AssistantAutomationRunner.waitForTermination()
            await draftRegeneration?.value
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresentation.show()
        return false
    }
}

struct MergeTetherApp: App {
    @NSApplicationDelegateAdaptor(MergeTetherAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(String(localized: .CommandCenter.commandCenterTitle), id: "main") {
            CommandCenterView(monitor: appDelegate.monitor, updates: appDelegate.updates, updater: appDelegate.updater)
                .environment(\.avatarCache, appDelegate.avatarCache)
                .environment(\.codingProviderGlyph, appDelegate.monitor.settings.automation.selectedAssistant?.glyph)
                .background(MainWindowFrameReader())
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if appDelegate.updater.isEnabled {
                    CheckForAppUpdatesButton(updater: appDelegate.updater)
                }
                WhatsNewButton(updates: appDelegate.updates)
            }
            CommandGroup(replacing: .newItem) {
                OpenMainWindowButton()
            }
        }

        MenuBarExtra {
            MenuBarStatusMenu(monitor: appDelegate.monitor, updater: appDelegate.updater)
                .environment(\.codingProviderGlyph, appDelegate.monitor.settings.automation.selectedAssistant?.glyph)
        } label: {
            MenuBarStatusLabel(monitor: appDelegate.monitor)
        }
        .menuBarExtraStyle(.menu)

        Window(Text(.Remote.remoteMacPairPhone), id: "remote-access") {
            RemoteAccessView(remote: appDelegate.remote)
        }
        .windowResizability(.contentSize)

        Window(String(localized: .CommandCenter.commandCenterAutomationActivity), id: "automation-activity") {
            let monitor = appDelegate.monitor
            let workflow = monitor.authoredMergeRequests.workflow
            VSplitView {
                AssistantJobHistoryView(monitor: monitor).frame(minHeight: 250)
                MergeWorkflowActivityView(entries: workflow.entries, onHandoff: { id in
                    guard requireCodingAssistant(monitor) else { return }
                    workflow.confirmPipelineHandoff(id)
                })
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 540)
        }
        .defaultSize(width: 780, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(monitor: appDelegate.monitor, updates: appDelegate.updates, updater: appDelegate.updater)
                .environment(CrashReporting.shared)
                .environment(\.codingProviderGlyph, appDelegate.monitor.settings.automation.selectedAssistant?.glyph)
        }
        .windowResizability(.contentMinSize)

        Window(String(localized: .Onboarding.onboardingWindowTitle), id: "onboarding") {
            OnboardingView(monitor: appDelegate.monitor, crashReporting: .shared)
        }
        .windowResizability(.contentSize)

        Window(String(localized: .Menu.whatsNewTitle), id: "whats-new") {
            WhatsNewView(updates: appDelegate.updates)
        }
        .windowResizability(.contentSize)
    }
}

private struct WhatsNewButton: View {
    let updates: UpdateService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            updates.loadWhatsNew()
            openWindow(id: "whats-new")
        } label: { Text(.Menu.whatsNewTitle) }
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "main") } label: { Text(.CommandCenter.commandCenterTitle) }
            .keyboardShortcut("0", modifiers: .command)
    }
}
