// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Netify",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "Netify",
            targets: ["Netify"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Netify",
            dependencies: []
        ),
        .testTarget(
            name: "NetifyTests",
            dependencies: ["Netify"]
        ),
        .executableTarget(
            name: "NetifyExamples",
            dependencies: ["Netify"],
            path: "Examples"
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
