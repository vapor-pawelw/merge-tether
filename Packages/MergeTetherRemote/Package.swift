// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MergeTetherRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MergeTetherRemote", targets: ["MergeTetherRemote"])],
    targets: [
        .target(name: "MergeTetherRemote"),
        .testTarget(name: "MergeTetherRemoteTests", dependencies: ["MergeTetherRemote"]),
    ]
)
