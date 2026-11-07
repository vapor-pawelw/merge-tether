import ProjectDescription

let project = Project(
    name: "GitLabTodos",
    options: .options(
        automaticSchemesOptions: .enabled(),
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
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
                "CFBundleURLTypes": .array([.dictionary([
                    "CFBundleURLName": .string("com.vaporpw.MergeTether.pair"),
                    "CFBundleURLSchemes": .array([.string("mergetether")]),
                ])]),
                "NSCameraUsageDescription": .string("Scan the pairing code shown by MergeTether on your Mac."),
                "UILaunchScreen": .dictionary([:]),
            ]),
            sources: ["iOS/**/*.swift"],
            resources: ["Resources/Remote.xcstrings", "Resources/MRHumanAction.xcstrings", "Resources/AuthorFeedback.xcstrings", "iOS/Resources/**"],
            dependencies: [.target(name: "MergeTetherRemote")],
            settings: .settings(base: ["TARGETED_DEVICE_FAMILY": "1,2", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"])
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
                "CFBundleName": .string("MergeTether"),
                "CFBundleShortVersionString": .string("0.1.0"),
                "CFBundleVersion": .string("1"),
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
            sources: ["Tests/**/*.swift"],
            resources: ["Tests/Fixtures/**"],
            dependencies: [
                .target(name: "GitLabTodos"),
                .target(name: "MergeTetherRemote"),
            ]
        ),
    ]
)
