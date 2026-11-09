// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ServiceLocator",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
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
