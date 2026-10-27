// swift-tools-version: 6.0
// SandKit: everything the iOS and visionOS apps share. The core (core/, Rust)
// comes in as SandCore.xcframework, built by tools/build-apple.sh.
import PackageDescription

let package = Package(
    name: "SandKit",
    platforms: [.iOS(.v18), .visionOS(.v2), .macOS(.v15)],
    products: [.library(name: "SandKit", targets: ["SandKit"])],
    targets: [
        .binaryTarget(name: "SandCore", path: "SandCore.xcframework"),
        .target(
            name: "SandKit",
            dependencies: ["SandCore"],
            // Symlinks to core/palettes.json and core/params.json.
            resources: [.copy("Resources/palettes.json"), .copy("Resources/params.json")]
        ),
        .testTarget(name: "SandKitTests", dependencies: ["SandKit"]),
    ],
    swiftLanguageModes: [.v5]
)
