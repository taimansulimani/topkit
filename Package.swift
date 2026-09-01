// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Topkit",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TopkitCore",
            dependencies: [],
            path: "Topkit",
            exclude: [
                "main.swift",
                "Info.plist",
                "PrivacyInfo.xcprivacy",
                "Assets.xcassets",
                "AppIcon.icon",
                "Topkit.entitlements"
            ]
        ),
        .testTarget(
            name: "TopkitTests",
            dependencies: ["TopkitCore"],
            path: "Tests/TopkitTests"
        ),
        .executableTarget(
            name: "AnnotateCLI",
            dependencies: ["TopkitCore"],
            path: "Tools/AnnotateCLI"
        )
    ]
)


