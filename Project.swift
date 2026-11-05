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
            name: "GitLabTodos",
            destinations: [.mac],
            product: .app,
            bundleId: "com.vaporpw.GitLabTodos",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": .boolean(true),
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
                .folderReference(path: "plugins/merge-tether"),
            ]
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
            ]
        ),
    ]
)
