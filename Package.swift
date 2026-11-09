// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ServiceLocator",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(
            name: "ServiceLocator",
            targets: ["ServiceLocator"]),
    ],
    targets: [
        .target(
            name: "ServiceLocator"),
        .testTarget(
            name: "ServiceLocatorTests",
            dependencies: ["ServiceLocator"]),
    ]
)
