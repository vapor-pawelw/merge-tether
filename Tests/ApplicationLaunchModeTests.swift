import AppKit
import Testing
@testable import GitLabTodos

@Suite("Application launch isolation")
struct ApplicationLaunchModeTests {
    @MainActor @Test func injectedHostHasNoInteractiveApplicationOrVisibleWindows() {
        let app = NSApplication.shared
        #expect(app.activationPolicy() == .prohibited)
        let visibleWindows = app.windows.filter { $0.isVisible }
        #expect(visibleWindows.isEmpty)
    }

    @Test func realInjectedTestHostWithEmptyConfigurationPathUsesHeadlessStartup() {
        let environment = [
            "XCTestBundlePath": "Contents/PlugIns/GitLabTodosTests.xctest",
            "XCTestSessionIdentifier": "00000000-0000-0000-0000-000000000001",
            "XCTestConfigurationFilePath": "",
            "XCInjectBundleInto": "unused",
            "HOME": "/tmp/synthetic-test-home",
            "CFFIXED_USER_HOME": "/tmp/synthetic-test-home"
        ]
        #expect(ApplicationLaunchMode.resolve(environment: environment) == .testHost)
    }

    @Test(arguments: ["XCTestBundlePath", "XCTestSessionIdentifier", "XCTestConfigurationFilePath"])
    func testInjectionSignalSelectsHeadlessHostBeforeProductionServices(_ key: String) {
        #expect(ApplicationLaunchMode.resolve(environment: [key: "synthetic-test-signal"]) == .testHost)
    }

    @Test func ordinaryLaunchAndIsolatedHomeAloneStillUseNormalSingleInstanceGate() {
        #expect(ApplicationLaunchMode.resolve(environment: [:]) == .application)
        #expect(ApplicationLaunchMode.resolve(environment: [
            "HOME": "/tmp/synthetic-home", "CFFIXED_USER_HOME": "/tmp/synthetic-home",
            "XCODE_RUNNING_FOR_PREVIEWS": "1"
        ]) == .application)
    }

    @Test func emptyInjectionVariablesDoNotDisableTheNormalApplication() {
        #expect(ApplicationLaunchMode.resolve(environment: [
            "XCTestBundlePath": "", "XCTestSessionIdentifier": "  ", "XCTestConfigurationFilePath": "\n"
        ]) == .application)
    }
}
