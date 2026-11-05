import AppKit
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let monitor: TodoMonitorService
    private let updates: UpdateService
    private let avatarCache: AvatarCache
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var updateTimer: Timer?
    private var blinkReminderTimer: Timer?
    private var blinkStepTimer: Timer?
    private var blinkReminderInterval: TimeInterval?
    private var remainingBlinkSteps = 0
    private var isBlinkAlertVisible = false
    private lazy var redDotImage = Self.makeRedDotImage()
    private var activationObserver: NSObjectProtocol?
    private var windowsToKeepBehind: [NSWindow] = []

    init(monitor: TodoMonitorService, updates: UpdateService, avatarCache: AvatarCache) {
        self.monitor = monitor
        self.updates = updates
        self.avatarCache = avatarCache
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureStatusButton()
        updateStatusButton()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusButton()
                self?.synchronizeBlinkReminderTimer()
            }
        }
    }

    private func configurePopover() {
        let content = TodoListView(monitor: monitor, updates: updates)
            .environment(\.avatarCache, avatarCache)

        popover.contentSize = NSSize(width: 420, height: 560)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.title = " 0"
        button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        monitor.checkCodexListener()

        if isBlinkAlertVisible {
            button.image = redDotImage
            button.image?.isTemplate = false
        } else if monitor.lastError != nil || monitor.unavailableAssistant != nil
                    || monitor.codexListenerWarning != nil || monitor.desktopHandoffError {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            button.image?.isTemplate = true
        } else if monitor.settings.onboardingCompleted {
            button.image = monitor.badgeCount == 0
                ? GitLabTodosAsset.todoDoneClear.image
                : GitLabTodosAsset.todoDone.image
            button.image?.isTemplate = monitor.badgeCount > 0
        } else {
            button.image = GitLabTodosAsset.todoDone.image
            button.image?.isTemplate = true
        }

        if button.image == nil {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        }
        button.title = " \(monitor.badgeCount)"
        let appName = String(localized: .Menu.menuHeaderTitle)
        button.toolTip = appName
        button.setAccessibilityLabel("\(appName) \(monitor.badgeCount)")
    }

    private func synchronizeBlinkReminderTimer() {
        guard monitor.lastError == nil,
              monitor.settings.notificationsEnabled,
              monitor.hasUnseenTodos,
              let interval = monitor.settings.unreadReminderInterval.seconds
        else {
            stopBlinkReminderTimer()
            stopBlinkSequence()
            return
        }

        guard blinkReminderTimer == nil || blinkReminderInterval != interval else {
            return
        }

        stopBlinkReminderTimer()
        blinkReminderInterval = interval
        blinkReminderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.startBlinkSequence()
            }
        }
    }

    private func stopBlinkReminderTimer() {
        blinkReminderTimer?.invalidate()
        blinkReminderTimer = nil
        blinkReminderInterval = nil
    }

    private func startBlinkSequence() {
        guard monitor.lastError == nil,
              monitor.settings.notificationsEnabled,
              monitor.hasUnseenTodos
        else {
            stopBlinkSequence()
            return
        }

        remainingBlinkSteps = 6
        isBlinkAlertVisible = true
        updateStatusButton()

        blinkStepTimer?.invalidate()
        blinkStepTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.monitor.lastError == nil,
                      self.monitor.hasUnseenTodos,
                      self.remainingBlinkSteps > 0
                else {
                    self?.stopBlinkSequence()
                    return
                }

                self.isBlinkAlertVisible.toggle()
                self.remainingBlinkSteps -= 1
                self.updateStatusButton()

                if self.remainingBlinkSteps == 0 {
                    self.stopBlinkSequence()
                }
            }
        }
    }

    private func stopBlinkSequence() {
        blinkStepTimer?.invalidate()
        blinkStepTimer = nil
        remainingBlinkSteps = 0
        if isBlinkAlertVisible {
            isBlinkAlertVisible = false
            updateStatusButton()
        }
    }

    private static func makeRedDotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            monitor.markMenuOpened()
            if !NSApp.isActive {
                keepWindowsBehindOnActivation(NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) })
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // The popover needs the app to be active to receive keyboard focus.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Activating the app raises its other windows (Settings, Setup, What's New).
    /// If one was left open behind other apps, it would appear on top of the
    /// popover, so push those windows back once activation has finished.
    private func keepWindowsBehindOnActivation(_ windows: [NSWindow]) {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        windowsToKeepBehind = windows
        guard !windows.isEmpty else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendWindowsBehind() }
        }
    }

    private func sendWindowsBehind() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        for window in windowsToKeepBehind where window.isVisible {
            window.orderBack(nil)
        }
        windowsToKeepBehind = []
    }
}
