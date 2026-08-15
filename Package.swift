// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GHMenuBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GHCore", targets: ["GHCore"]),
        .executable(name: "GHMenuBar", targets: ["GHMenuBar"])
    ],
    targets: [
        .target(name: "GHCore"),
        .executableTarget(
            name: "GHMenuBar",
            dependencies: ["GHCore"]
        ),
        .testTarget(
            name: "GHCoreTests",
            dependencies: ["GHCore"]
        )
    ]
)

