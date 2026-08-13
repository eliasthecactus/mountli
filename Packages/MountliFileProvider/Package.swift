// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MountliFileProvider",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MountliFileProvider", targets: ["MountliFileProvider"])
    ],
    dependencies: [
        .package(path: "../MountliCore")
    ],
    targets: [
        .target(
            name: "MountliFileProvider",
            dependencies: [.product(name: "MountliCore", package: "MountliCore")],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(name: "MountliFileProviderTests", dependencies: ["MountliFileProvider"]),
    ]
)
