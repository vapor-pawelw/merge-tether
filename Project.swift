import ProjectDescription
import Foundation

let relayOrigin: String = {
    guard let path = ProcessInfo.processInfo.environment["TUIST_MERGETETHER_RELAY_CONFIG_FILE"], !path.isEmpty else { return "" }
    guard let data = FileManager.default.contents(atPath: path),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          Set(values.keys) == ["origin"], let raw = values["origin"] else {
        fatalError("Relay configuration must be a readable external JSON file containing only a string origin; never include credentials.")
    }
    let rawOrigin = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawOrigin.contains("%"), !rawOrigin.contains("\\"),
          !rawOrigin.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
          var parts = URLComponents(string: rawOrigin), parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII }),
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/", parts.url != nil,
          parts.port.map({ (1...65535).contains($0) }) ?? true else {
        fatalError("Relay configuration requires an HTTPS origin without credentials, path, query or fragment.")
    }
    parts.scheme = "https"; parts.host = host.lowercased(); parts.path = ""
    if parts.port == 443 { parts.port = nil }
    guard let normalized = parts.url else { fatalError("Relay origin is invalid.") }
    return normalized.absoluteString
}()


let project = Project(
    name: "GitLabTodos",
    options: .options(
        automaticSchemesOptions: .enabled(),
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MARKETING_VERSION": "1.2.0",
            "CURRENT_PROJECT_VERSION": "1",
            "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        ]
    ),
    targets: [
        .target(
            name: "MergeTetherRemote",
            destinations: [.mac, .iPhone, .iPad],
            product: .staticFramework,
            bundleId: "com.vaporpw.MergeTetherRemote",
            deploymentTargets: .multiplatform(iOS: "17.0", macOS: "14.0"),
            sources: ["Packages/MergeTetherRemote/Sources/MergeTetherRemote/**"]
        ),
        .target(
            name: "MergeTetheriOS",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.vaporpw.MergeTether.iOS",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("MergeTether"),
                "MergeTetherRelayOrigin": .string(relayOrigin),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "CFBundleURLTypes": .array([.dictionary([
                    "CFBundleURLName": .string("com.vaporpw.MergeTether.pair"),
                    "CFBundleURLSchemes": .array([.string("mergetether")]),
                ])]),
                "NSCameraUsageDescription": .string("Scan the pairing code shown by MergeTether on your Mac."),
                "UILaunchScreen": .dictionary([:]),
            ]),
            sources: ["iOS/**/*.swift", "Sources/Views/StatusFlowLayout.swift"],
            resources: ["Resources/MergeActions.xcstrings", "Resources/Remote.xcstrings", "Resources/Board.xcstrings", "Resources/MRHumanAction.xcstrings", "Resources/AuthorFeedback.xcstrings", "Resources/MRDependencies.xcstrings", "Resources/CommentReview.xcstrings", "iOS/Resources/**"],
            dependencies: [.target(name: "MergeTetherRemote")],
            settings: .settings(base: [
                "TARGETED_DEVICE_FAMILY": "1,2",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "PROVISIONING_PROFILE_SPECIFIER": "$(MERGETETHER_IOS_PROVISIONING_PROFILE)",
            ])
        ),
        .target(
            name: "GitLabTodos",
            destinations: [.mac],
            product: .app,
            bundleId: "com.vaporpw.GitLabTodos",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": .boolean(false),
                "CFBundleDisplayName": .string("MergeTether"),
                "MergeTetherRelayOrigin": .string(relayOrigin),
                "CFBundleName": .string("MergeTether"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "NSHumanReadableCopyright": .string("Copyright © 2026 vaporpw. MIT License."),
            ]),
            sources: ["Sources/**"],
            resources: [
                "Resources/**",
                "CHANGELOG.md",
                .folderReference(path: "Helpers/Automation"),
            ],
            dependencies: [.target(name: "MergeTetherRemote")]
        ),
        .target(
            name: "GitLabTodosTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "com.vaporpw.GitLabTodosTests",
            deploymentTargets: .macOS("14.0"),
            sources: ["Tests/**/*.swift", "iOS/RemotePhoneModel.swift"],
            resources: ["Tests/Fixtures/**"],
            dependencies: [
                .target(name: "GitLabTodos"),
                .target(name: "MergeTetherRemote"),
            ]
        ),
    ]
)
