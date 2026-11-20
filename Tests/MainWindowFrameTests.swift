import AppKit
import Testing
@testable import MergeTether

@MainActor
struct MainWindowFrameTests {
    private let primary = MainWindowFrame.Display(
        id: "primary", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 836)
    )
    private let external = MainWindowFrame.Display(
        id: "external", frame: CGRect(x: -1920, y: 360, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 360, width: 1920, height: 1056)
    )

    @Test func returnsToTheSamePositionAndSizeOnAnExternalDisplay() {
        let frame = CGRect(x: -1040, y: 520, width: 1160, height: 760)
        let saved = MainWindowFrame(frame: frame, display: external)

        #expect(saved.restored(in: [primary, external]) == frame)
    }

    @Test func followsTheSameDisplayAfterRearrangingDisplays() {
        let frame = CGRect(x: -1860, y: 520, width: 1100, height: 760)
        let saved = MainWindowFrame(frame: frame, display: external)
        let rearranged = MainWindowFrame.Display(
            id: external.id, frame: external.frame.offsetBy(dx: 3360, dy: -600),
            visibleFrame: external.visibleFrame.offsetBy(dx: 3360, dy: -600)
        )

        #expect(saved.restored(in: [primary, rearranged]) == frame.offsetBy(dx: 3360, dy: -600))
    }

    @Test func fitsAnOversizedWindowOnTheRemainingDisplay() {
        let frame = CGRect(x: -1800, y: 450, width: 1600, height: 900)
        let saved = MainWindowFrame(frame: frame, display: external)

        #expect(saved.restored(in: [primary]) == primary.visibleFrame)
    }

    @Test func restoresTheFinalFrameWhenANewWindowIsCreated() async throws {
        let suite = "MainWindowFrameTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = CGRect(x: 100, y: 100, width: 700, height: 700)
        let movedAndResized = CGRect(x: 160, y: 80, width: 1000, height: 780)
        let firstWindow = makeWindow(frame: initial)
        firstWindow.contentView = MainWindowFrameView(defaults: defaults) { [primary] }
        await finishAttachingWindow()
        #expect(firstWindow.frame == initial)
        firstWindow.setFrame(movedAndResized, display: false)
        firstWindow.close()

        let secondWindow = makeWindow(frame: initial)
        defer { secondWindow.close() }
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        secondWindow.contentView = MainWindowFrameView(defaults: reopenedDefaults) { [primary] }
        await finishAttachingWindow()

        #expect(secondWindow.frame == movedAndResized)
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func finishAttachingWindow() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
