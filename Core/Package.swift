// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusGuardCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FocusGuardCore", targets: ["FocusGuardCore"])],
    targets: [
        .target(name: "FocusGuardCore"),
        .testTarget(name: "FocusGuardCoreTests", dependencies: ["FocusGuardCore"]),
    ]
)
