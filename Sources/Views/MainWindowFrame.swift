import AppKit
import SwiftUI

struct MainWindowFrame: Codable {
    struct Display {
        let id: String
        let frame: CGRect
        let visibleFrame: CGRect

        @MainActor static var connected: [Self] {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return nil }
                let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
                let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? number.stringValue
                return Self(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
            }
        }

        fileprivate func overlap(with windowFrame: CGRect) -> CGFloat {
            let intersection = frame.intersection(windowFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
    }

    private let frame: CGRect
    private let displayID: String
    private let displayFrame: CGRect

    init(frame: CGRect, display: Display) {
        self.frame = frame
        displayID = display.id
        displayFrame = display.frame
    }

    func restored(in displays: [Display]) -> CGRect? {
        let originalDisplay = displays.first { $0.id == displayID }
        guard let display = originalDisplay ?? displays.first else { return nil }
        let position = frame.offsetBy(dx: display.frame.minX - displayFrame.minX,
                                      dy: display.frame.maxY - displayFrame.maxY)
        if originalDisplay != nil && display.frame.size == displayFrame.size {
            return position
        }

        let bounds = display.visibleFrame
        let width = min(position.width, bounds.width)
        let height = min(position.height, bounds.height)
        let x = min(max(position.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(position.maxY - height, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct MainWindowFrameReader: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowFrameView { MainWindowFrameView() }
    func updateNSView(_ nsView: MainWindowFrameView, context: Context) {}
}

final class MainWindowFrameView: NSView {
    private let defaults: UserDefaults
    private let displays: @MainActor () -> [MainWindowFrame.Display]
    private let key = "mainWindowFrame"

    init(defaults: UserDefaults = .standard,
         displays: @escaping @MainActor () -> [MainWindowFrame.Display] = { MainWindowFrame.Display.connected }) {
        self.defaults = defaults
        self.displays = displays
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }

        // Let SwiftUI apply its initial frame before restoring and observing changes.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if let toolbar = window.toolbar {
                if #available(macOS 15, *) { toolbar.allowsDisplayModeCustomization = false }
                toolbar.displayMode = .iconOnly
            }
            restoreFrame(of: window)
            observeFrame(of: window)
        }
    }

    private func restoreFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(MainWindowFrame.self, from: data),
              let frame = saved.restored(in: displays()),
              frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }

    private func observeFrame(of window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(saveFrame(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(saveFrame(_:)),
                           name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func saveFrame(_ notification: Notification) {
        guard let window, !window.styleMask.contains(.fullScreen),
              window.isVisible || window.isMiniaturized || notification.name == NSWindow.willCloseNotification else { return }
        let frame = window.frame
        guard let display = displays().max(by: { $0.overlap(with: frame) < $1.overlap(with: frame) }),
              display.overlap(with: frame) > 0 else { return }
        let saved = MainWindowFrame(frame: frame, display: display)
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key)
        }
    }
}
