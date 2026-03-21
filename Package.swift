// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "hypervisor",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "hypervisor",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Hypervisor"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
