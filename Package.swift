// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ServiceLocator",
    platforms: [.iOS(.v16)],
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
