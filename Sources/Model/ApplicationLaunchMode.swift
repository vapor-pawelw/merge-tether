import Foundation

enum ApplicationLaunchMode: Equatable {
    case application
    case testHost

    static func resolve(environment: [String: String]) -> Self {
        let testSignals = ["XCTestBundlePath", "XCTestSessionIdentifier", "XCTestConfigurationFilePath"]
        return testSignals.contains { key in
            environment[key].map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        } ? .testHost : .application
    }
}
