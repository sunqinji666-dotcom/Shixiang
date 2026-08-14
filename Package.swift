// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Shixiang",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shixiang", targets: ["Shixiang"])
    ],
    targets: [
        .executableTarget(
            name: "Shixiang",
            path: "Sources/Shixiang",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("CoreServices"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "ShixiangTests",
            dependencies: ["Shixiang"],
            path: "Tests/ShixiangTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
