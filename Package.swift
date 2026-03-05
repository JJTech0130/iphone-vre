// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "VPhone",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.1"),
        .package(url: "https://github.com/mhdhejazi/Dynamic", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "FakeUSBKeyboardLib",
            path: "Sources/FakeUSBKeyboardLib",
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("IOKit"),
            ],
        ),
        .executableTarget(
            name: "vphone",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Dynamic", package: "Dynamic"),
                "FakeUSBKeyboardLib",
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ],
        ),
        .executableTarget(
            name: "fake-usb-keyboard",
            dependencies: ["FakeUSBKeyboardLib"],
            path: "Sources/FakeUSBKeyboard",
        ),
    ],
)
