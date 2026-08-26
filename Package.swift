// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SignalCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SignalCore",
            targets: ["SignalCore"]
        )
    ],
    targets: [
        .target(
            name: "SignalCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SignalCoreTests",
            dependencies: ["SignalCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
