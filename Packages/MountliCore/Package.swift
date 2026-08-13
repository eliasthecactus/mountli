// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MountliCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MountliCore", targets: ["MountliCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .binaryTarget(name: "RcloneCore", path: "Vendor/RcloneCore.xcframework"),
        .target(
            name: "MountliCore",
            dependencies: ["CSQLite", "RcloneCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedLibrary("resolv")
            ]
        ),
        .testTarget(name: "MountliCoreTests", dependencies: ["MountliCore"]),
    ]
)
