// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "vphone-cli",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
        .package(url: "https://github.com/mhdhejazi/Dynamic", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "vphone-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
            ],
        ),
    ],
)
