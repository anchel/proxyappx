// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyAppXCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProxyAppXCore", targets: ["ProxyAppXCore"]),
    ],
    targets: [
        .target(
            name: "ProxyAppXCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ProxyAppXCoreTests",
            dependencies: ["ProxyAppXCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
