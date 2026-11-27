import Foundation
import Testing
@testable import MergeTether

@MainActor
@Suite("LaunchAtLoginToggle")
struct LaunchAtLoginToggleTests {
    private struct Failure: Error {}

    @MainActor
    private final class FakeController: LaunchAtLoginControlling {
        var isEnabled: Bool
        var failing: Bool
        private(set) var calls: [Bool] = []

        init(isEnabled: Bool = false, failing: Bool = false) {
            self.isEnabled = isEnabled
            self.failing = failing
        }

        func setEnabled(_ enabled: Bool) throws {
            calls.append(enabled)
            if failing { throw Failure() }
            isEnabled = enabled
        }
    }

    private func makeSettings() throws -> (SettingsManager, () -> Void) {
        let suite = "LaunchAtLogin.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsManager(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test(arguments: [true, false])
    func successChangesStatusAndPersistsPreference(_ desired: Bool) throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.launchAtLoginPreference = !desired
        let controller = FakeController(isEnabled: !desired)
        let toggle = LaunchAtLoginToggle(controller: controller) {
            settings.launchAtLoginPreference = $0
            settings.save()
        }
        #expect(toggle.requestChange(desired) == desired)
        #expect(toggle.isEnabled == desired)
        #expect(toggle.lastFailure == nil)
        #expect(controller.calls == [desired])
        #expect(settings.launchAtLoginPreference == desired)
    }

    @Test(arguments: [true, false])
    func failureKeepsRealStatusCallsServiceOnceAndDoesNotPersist(_ desired: Bool) throws {
        let (settings, cleanup) = try makeSettings()
        defer { cleanup() }
        settings.launchAtLoginPreference = !desired
        let controller = FakeController(isEnabled: !desired, failing: true)
        let toggle = LaunchAtLoginToggle(controller: controller) { settings.launchAtLoginPreference = $0 }
        #expect(toggle.requestChange(desired) == !desired)
        #expect(toggle.isEnabled == !desired)
        #expect(toggle.lastFailure != nil)
        #expect(controller.calls == [desired])
        #expect(settings.launchAtLoginPreference == !desired)
    }

    @Test func repeatedFailingRequestsCallServiceOncePerRequest() {
        let controller = FakeController(isEnabled: false, failing: true)
        var persisted = 0
        let toggle = LaunchAtLoginToggle(controller: controller) { _ in persisted += 1 }
        toggle.requestChange(true)
        toggle.requestChange(false)
        #expect(controller.calls == [true, false])
        #expect(persisted == 0)
        #expect(!toggle.isEnabled)
    }

    @Test func successAfterFailureClearsFailure() {
        let controller = FakeController(failing: true)
        let toggle = LaunchAtLoginToggle(controller: controller) { _ in }
        toggle.requestChange(true)
        #expect(toggle.lastFailure != nil)
        controller.failing = false
        toggle.requestChange(true)
        #expect(toggle.lastFailure == nil)
        #expect(toggle.isEnabled)
    }

    @Test func resyncAdoptsExternalStatusWithoutCallingService() {
        let controller = FakeController(isEnabled: true)
        let toggle = LaunchAtLoginToggle(controller: controller) { _ in }
        #expect(toggle.isEnabled)
        controller.isEnabled = false
        toggle.resync()
        #expect(!toggle.isEnabled)
        #expect(controller.calls.isEmpty)
    }
}
