import ProjectDescription
import Foundation

let relayOrigin: String = {
    let environment = ProcessInfo.processInfo.environment
    let raw: String
    if let path = environment["TUIST_MERGETETHER_RELAY_CONFIG_FILE"] {
        guard !path.isEmpty else { return "" }
        guard let data = FileManager.default.contents(atPath: path),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(values.keys) == ["origin"], let configuredOrigin = values["origin"] else {
            fatalError("Relay configuration must be a readable external JSON file containing only a string origin; never include credentials.")
        }
        raw = configuredOrigin
    } else {
        guard let configuredOrigin = environment["TUIST_MERGETETHER_RELAY_ORIGIN"],
              !configuredOrigin.isEmpty else { return "" }
        raw = configuredOrigin
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

let updateFeed: String = ProcessInfo.processInfo.environment["TUIST_MERGETETHER_UPDATE_FEED"] ?? ""
let updatePublicKey: String = ProcessInfo.processInfo.environment["TUIST_MERGETETHER_UPDATE_PUBLIC_KEY"] ?? ""
if !updateFeed.isEmpty || !updatePublicKey.isEmpty {
    guard let url = URLComponents(string: updateFeed), url.scheme == "https", url.host?.isEmpty == false,
          url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
          Data(base64Encoded: updatePublicKey)?.count == 32 else {
        fatalError("Configure an HTTPS Sparkle update feed and its base64-encoded public EdDSA key together.")
    }
}

func crashReportingDSN(_ setting: String) -> String {
    let value = ProcessInfo.processInfo.environment[setting] ?? ""
    let publicSentryDSN = #"\Ahttps://[a-fA-F0-9]{32}@o[0-9]+\.ingest(\.(us|de))?\.sentry\.io/[1-9][0-9]{0,19}\z"#
    guard value.isEmpty || value.range(of: publicSentryDSN, options: .regularExpression) != nil else {
        fatalError("\(setting) must be a public Sentry Cloud DSN. Never supply a token or a private service URL.")
    }
    return value
}

let project = Project(
    name: "MergeTether",
    options: .options(
        automaticSchemesOptions: .enabled(),
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MARKETING_VERSION": "2.0.0",
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
                "MergeTetherCrashDSN": .string(crashReportingDSN("TUIST_MERGETETHER_IOS_CRASH_DSN")),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "CFBundleURLTypes": .array([.dictionary([
                    "CFBundleURLName": .string("com.vaporpw.MergeTether.pair"),
                    "CFBundleURLSchemes": .array([.string("mergetether")]),
                ])]),
                "NSCameraUsageDescription": .string("Scan the pairing code shown by MergeTether on your Mac."),
                "UILaunchScreen": .dictionary([:]),
                "UTExportedTypeDeclarations": .array([.dictionary([
                    "UTTypeIdentifier": .string("com.vaporpw.mergetether.remote-board-card"),
                    "UTTypeConformsTo": .array([.string("public.data")]),
                    "UTTypeDescription": .string("MergeTether board card"),
                ])]),
            ]),
            sources: ["iOS/**/*.swift", "Sources/Model/AssistantLaunchContext.swift",
                      "Sources/Views/StatusFlowLayout.swift", "Sources/Views/PersonLabel.swift",
                      "Sources/Views/CodingProviderIcon.swift",
                      "Sources/Views/ExtraContextMarkdown.swift", "Sources/Views/DraftRegenerationSheet.swift",
                      "Sources/Views/MergeRequestDescription.swift", "Sources/Views/MRDetailSection.swift",
                      "Sources/Views/MergeRequestAttentionCallout.swift",
                      "Sources/Views/ApprovalBadgeColor.swift", "Sources/Views/InboxUpdateTimestamp.swift",
                      "Sources/Views/BoardInsertionDrag.swift", "Sources/Views/MRDependencyBadge.swift",
                      "Sources/Views/MRCardMetadataLayout.swift", "Sources/Views/ReviewerEditingControls.swift",
                      "Sources/Views/MRIssueTag.swift", "Sources/Services/CrashConsent.swift",
                      "Sources/Services/CrashReport.swift", "Sources/Services/CrashReporting.swift",
                      "Sources/Services/CrashUpload.swift",
                      "Sources/Views/Settings/CrashReportingSettingsSection.swift"],
            resources: ["Resources/MergeActions.xcstrings", "Resources/Remote.xcstrings", "Resources/Board.xcstrings",
                        "Resources/MRHumanAction.xcstrings", "Resources/AuthorFeedback.xcstrings", "Resources/MRDependencies.xcstrings",
                        "Resources/CommentReview.xcstrings", "Resources/FeedbackSuggestions.xcstrings", "Resources/DraftRegeneration.xcstrings",
                        "Resources/ActionEffects.xcstrings", "Resources/CommandCenter.xcstrings",
                        "Resources/AgentExplanation.xcstrings",
                        "Resources/AssistantContext.xcstrings", "Resources/MRFreshness.xcstrings",
                        "Resources/MRIssues.xcstrings", "Resources/ProviderGlyphs.xcassets",
                        "Resources/CrashReporting.xcstrings", "Resources/PrivacyInfo.xcprivacy",
                        "iOS/Resources/**"],
            dependencies: [.target(name: "MergeTetherRemote")],
            settings: .settings(base: [
                "TARGETED_DEVICE_FAMILY": "1,2",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "PROVISIONING_PROFILE_SPECIFIER": "$(MERGETETHER_IOS_PROVISIONING_PROFILE)",
            ])
        ),
        .target(
            name: "MergeTether",
            destinations: [.mac],
            product: .app,
            bundleId: "com.vaporpw.MergeTether",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": .boolean(false),
                "CFBundleDisplayName": .string("MergeTether"),
                "MergeTetherRelayOrigin": .string(relayOrigin),
                "MergeTetherCrashDSN": .string(crashReportingDSN("TUIST_MERGETETHER_MACOS_CRASH_DSN")),
                "CFBundleName": .string("MergeTether"),
                "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
                "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
                "SUFeedURL": .string(updateFeed),
                "SUPublicEDKey": .string(updatePublicKey),
                "SUEnableAutomaticChecks": .boolean(true),
                "SUAllowsAutomaticUpdates": .boolean(false),
                "SUShowReleaseNotes": .boolean(false),
                "SURequireSignedFeed": .boolean(true),
                "SUVerifyUpdateBeforeExtraction": .boolean(true),
                "NSHumanReadableCopyright": .string("Copyright © 2026 vaporpw. MIT License."),
                "UTExportedTypeDeclarations": .array([.dictionary([
                    "UTTypeIdentifier": .string("com.vaporpw.mergetether.board-card"),
                    "UTTypeConformsTo": .array([.string("public.data")]),
                    "UTTypeDescription": .string("MergeTether board card"),
                ])]),
            ]),
            sources: ["Sources/**"],
            resources: [
                "Resources/**",
                "CHANGELOG.md",
                "Vendor/Sparkle/Sparkle-LICENSE.txt",
                .folderReference(path: "Helpers/Automation"),
            ],
            scripts: [.post(path: "scripts/sign-sparkle.sh", name: "Sign Sparkle helpers", basedOnDependencyAnalysis: false)],
            dependencies: [.target(name: "MergeTetherRemote"), .xcframework(path: "Vendor/Sparkle/Sparkle.xcframework")]
        ),
        .target(
            name: "MergeTetherTests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "com.vaporpw.MergeTetherTests",
            deploymentTargets: .macOS("14.0"),
            sources: ["Tests/**/*.swift", "iOS/RemotePhoneModel.swift"],
            resources: ["Tests/Fixtures/**"],
            dependencies: [
                .target(name: "MergeTether"),
                .target(name: "MergeTetherRemote"),
            ]
        ),
    ]
)
