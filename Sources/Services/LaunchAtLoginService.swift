import Foundation
import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
protocol LaunchAtLoginControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginController: LaunchAtLoginControlling {
    var isEnabled: Bool { LaunchAtLoginService.isEnabled }

    func setEnabled(_ enabled: Bool) throws {
        try LaunchAtLoginService.setEnabled(enabled)
    }
}

/// Drives a launch-at-login toggle. Each user request calls the service exactly once and
/// then adopts the real system status, so a failure can never re-trigger the service.
@MainActor
@Observable
final class LaunchAtLoginToggle {
    private(set) var isEnabled: Bool
    private(set) var lastFailure: String?

    @ObservationIgnored private let controller: any LaunchAtLoginControlling
    @ObservationIgnored private let persist: (Bool) -> Void

    init(controller: any LaunchAtLoginControlling = SystemLaunchAtLoginController(),
         persist: @escaping (Bool) -> Void) {
        self.controller = controller
        self.persist = persist
        self.isEnabled = controller.isEnabled
    }

    /// Returns the resulting (real) state.
    @discardableResult
    func requestChange(_ desired: Bool) -> Bool {
        do {
            try controller.setEnabled(desired)
            lastFailure = nil
            persist(desired)
        } catch {
            Log.settings.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
            lastFailure = error.localizedDescription
        }
        isEnabled = controller.isEnabled
        return isEnabled
    }

    /// Re-reads the real status, e.g. after a change in System Settings.
    func resync() {
        let actual = controller.isEnabled
        if actual != isEnabled { isEnabled = actual }
    }
}
